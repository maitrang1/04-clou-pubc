// One Threads call: guard the URL, pin the IP, send the token the documented way (POST form field / GET query, or a Bearer header when net.auth_style says so), classify the answer.
// The log never carries a URL query or a body: only method + path + status. Redirects are never followed (co-net returns them; they count as a failure).
const std = @import("std");
const Ctx = @import("co-ctx.zig").Ctx;
const guard = @import("co-guard.zig");
const net = @import("co-net.zig");
const err = @import("ap-error.zig");
const log = @import("co-log.zig");
const js = @import("ap-json.zig");
const util = @import("co-util.zig");

pub const Reply = struct { status: u16, body: []const u8, headers: []const u8 };
pub const Fail = struct { info: err.Info, http: u16 = 0, net: ?net.Err = null, sent: bool = false, body: []const u8 = "" };
pub const Result = union(enum) { ok: Reply, fail: Fail };
pub fn Out(comptime T: type) type {
    return union(enum) { ok: T, fail: Fail };
}

pub const Spec = struct {
    method: []const u8 = "GET",
    url: []const u8, // no token in it
    token: []const u8,
    form: ?[]const u8 = null, // urlencoded fields without the token (POST)
    timeout_s: u32 = 0, // 0 = net.timeout_s
    allow_hosts: ?[]const []const u8 = null, // null = net.allow_hosts
    enable_race: bool = false, // switch on the "on": false rows of the error table
};

fn netInfo(e: net.Err) err.Info {
    return .{ .class = .retry, .msg = @errorName(e) };
}

// ids that go into URL paths must be plain digits
pub fn idOk(s: []const u8) bool {
    if (s.len == 0 or s.len > 40) return false;
    for (s) |c| if (c < '0' or c > '9') return false;
    return true;
}

// {base}/{version}/{path}
pub fn graphUrl(cx: *const Ctx, a: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "{s}/{s}/{s}", .{ std.mem.trimEnd(u8, cx.cfg.graph.base, "/"), cx.cfg.graph.version, path });
}
// {base}/{path} (OAuth and token calls carry no version segment in Meta's docs)
pub fn rootUrl(cx: *const Ctx, a: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "{s}/{s}", .{ std.mem.trimEnd(u8, cx.cfg.graph.base, "/"), path });
}

fn oom() Result {
    return .{ .fail = .{ .info = .{ .class = .failed, .msg = "out of memory" } } };
}

pub fn call(cx: *const Ctx, a: std.mem.Allocator, sp: Spec) Result {
    const hosts = sp.allow_hosts orelse cx.cfg.net.allow_hosts;
    const bearer = std.mem.eql(u8, cx.cfg.net.auth_style, "bearer");
    const tenc = util.pct(a, sp.token) catch return oom();
    var url = sp.url;
    var body: ?[]const u8 = null;
    var hs: std.ArrayList(std.http.Header) = .empty;
    if (bearer) {
        const auth = std.fmt.allocPrint(a, "Bearer {s}", .{sp.token}) catch return oom();
        hs.append(a, .{ .name = "Authorization", .value = auth }) catch return oom();
        body = sp.form;
    } else if (std.mem.eql(u8, sp.method, "POST")) {
        body = if (sp.form) |f| (if (f.len > 0) std.fmt.allocPrint(a, "{s}&access_token={s}", .{ f, tenc }) catch return oom() else std.fmt.allocPrint(a, "access_token={s}", .{tenc}) catch return oom()) else std.fmt.allocPrint(a, "access_token={s}", .{tenc}) catch return oom();
    } else {
        url = std.fmt.allocPrint(a, "{s}{s}access_token={s}", .{ sp.url, if (std.mem.indexOfScalar(u8, sp.url, '?') != null) "&" else "?", tenc }) catch return oom();
    }
    if (body != null) hs.append(a, .{ .name = "Content-Type", .value = "application/x-www-form-urlencoded" }) catch return oom();
    const t = guard.parseUrl(a, url, .{ .allow_hosts = hosts, .mock = cx.mock }) catch |e| return .{ .fail = .{ .info = .{ .class = .failed, .msg = @errorName(e) } } };
    const ip = guard.pin(cx.io, cx.resolver, t) catch |e| return .{ .fail = .{ .info = .{ .class = .retry, .msg = @errorName(e) } } };
    var flushed = false;
    const tmo = if (sp.timeout_s == 0) cx.cfg.net.timeout_s else sp.timeout_s;
    const red = guard.redactUrl(a, url) catch "?";
    const r = net.call(cx.io, a, t, ip, .{
        .ua = cx.cfg.net.user_agent,
        .timeout_s = tmo,
        .cap_bytes = @as(usize, cx.cfg.net.body_cap_kb) * 1024,
        .headers = hs.items,
        .method = sp.method,
        .body = body,
        .flushed = &flushed,
    }) catch |e| {
        log.log(cx, "warn", "net {s} {s} {s}", .{ sp.method, red, @errorName(e) });
        return .{ .fail = .{ .info = netInfo(e), .net = e, .sent = flushed } };
    };
    const rep = Reply{ .status = r.status, .body = r.body, .headers = r.headers };
    if (r.status >= 200 and r.status < 300 and !topError(a, r.body)) return .{ .ok = rep };
    // a redirect is never followed: the host (or Meta) must answer directly
    const info = err.classifyWith(a, r.status, r.body, sp.enable_race);
    log.log(cx, "warn", "http {d} {s} {s} class={s} code={d}", .{ r.status, sp.method, red, @tagName(info.class), info.code });
    return .{ .fail = .{ .info = info, .http = r.status, .sent = flushed, .body = r.body } };
}

// a 200 can still carry {"error":{...}} at the top level
fn topError(a: std.mem.Allocator, body: []const u8) bool {
    if (std.mem.indexOf(u8, body, "\"error\"") == null) return false;
    const v = js.parse(a, body) orelse return false;
    const e = js.obj(v, "error") orelse return false;
    return e == .object;
}

test "ids are digits only" {
    try std.testing.expect(idOk("123456"));
    try std.testing.expect(!idOk(""));
    try std.testing.expect(!idOk("12/../x"));
    try std.testing.expect(!idOk("12 34"));
}
