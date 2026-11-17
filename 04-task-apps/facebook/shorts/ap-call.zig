// One Graph/rupload call: guard the URL, pin the IP, send with the token in the Authorization header (never in the URL), classify the answer.
const std = @import("std");
const Ctx = @import("co-ctx.zig").Ctx;
const guard = @import("co-guard.zig");
const net = @import("co-net.zig");
const err = @import("ap-error.zig");
const log = @import("co-log.zig");
const js = @import("ap-json.zig");
const caps = @import("rw-caps.zig");

// worst usage seen on any reply since the last reset (percent) and Meta's own regain estimate (minutes)
pub var usage_pct: u32 = 0;
pub var usage_regain: u32 = 0;
pub fn resetUsage() void {
    usage_pct = 0;
    usage_regain = 0;
}

pub const Reply = struct { status: u16, body: []const u8, headers: []const u8 };
pub const Fail = struct { info: err.Info, http: u16 = 0, net: ?net.Err = null, sent: bool = false, body: []const u8 = "" };
pub const Result = union(enum) { ok: Reply, fail: Fail };
pub fn Out(comptime T: type) type {
    return union(enum) { ok: T, fail: Fail };
}

pub const Spec = struct {
    method: []const u8 = "GET",
    url: []const u8,
    token: []const u8,
    json: ?[]const u8 = null,
    body_file: ?net.BodyFile = null,
    headers: []const std.http.Header = &.{},
    timeout_s: u32 = 0, // 0 = net.timeout_s
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

pub fn graphUrl(cx: *const Ctx, a: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "{s}/{s}/{s}", .{ std.mem.trimEnd(u8, cx.cfg.graph.base, "/"), cx.cfg.graph.version, path });
}

pub fn call(cx: *const Ctx, a: std.mem.Allocator, sp: Spec) Result {
    const t = guard.parseUrl(a, sp.url, .{ .allow_hosts = cx.cfg.net.allow_hosts, .mock = cx.mock }) catch |e| return .{ .fail = .{ .info = .{ .class = .failed, .msg = @errorName(e) } } };
    const ip = guard.pin(cx.io, cx.resolver, t) catch |e| return .{ .fail = .{ .info = .{ .class = .retry, .msg = @errorName(e) } } };
    var hs: std.ArrayList(std.http.Header) = .empty;
    const auth = std.fmt.allocPrint(a, "OAuth {s}", .{sp.token}) catch return oom();
    hs.append(a, .{ .name = "Authorization", .value = auth }) catch return oom();
    if (sp.json != null) hs.append(a, .{ .name = "Content-Type", .value = "application/json" }) catch return oom();
    hs.appendSlice(a, sp.headers) catch return oom();
    var flushed = false;
    const tmo = if (sp.timeout_s == 0) cx.cfg.net.timeout_s else sp.timeout_s;
    const r = net.call(cx.io, a, t, ip, .{
        .ua = cx.cfg.net.user_agent,
        .timeout_s = tmo,
        .cap_bytes = @as(usize, cx.cfg.net.body_cap_kb) * 1024,
        .headers = hs.items,
        .method = sp.method,
        .body = sp.json,
        .body_file = sp.body_file,
        .flushed = &flushed,
    }) catch |e| {
        const red = guard.redactUrl(a, sp.url) catch "?";
        log.log(cx, "warn", "net {s} {s} {s}", .{ sp.method, red, @errorName(e) });
        return .{ .fail = .{ .info = netInfo(e), .net = e, .sent = flushed } };
    };
    const rep = Reply{ .status = r.status, .body = r.body, .headers = r.headers };
    const us = caps.usage(a, r.headers);
    usage_pct = @max(usage_pct, us.pct);
    usage_regain = @max(usage_regain, us.regain_min);
    const has_err = r.status < 300 and topError(a, r.body);
    if (r.status >= 200 and r.status < 300 and !has_err) {
        if (std.mem.indexOf(u8, r.body, "ProcessingFailedError") == null) return .{ .ok = rep };
    }
    const info = err.classify(a, r.status, r.body);
    const red = guard.redactUrl(a, sp.url) catch "?";
    log.log(cx, "warn", "http {d} {s} {s} class={s} code={d}", .{ r.status, sp.method, red, @tagName(info.class), info.code });
    return .{ .fail = .{ .info = info, .http = r.status, .sent = flushed, .body = r.body } };
}

// a 200 can still carry {"error":{...}} at the top level; nested "error" fields (status phases) are normal data
fn topError(a: std.mem.Allocator, body: []const u8) bool {
    if (std.mem.indexOf(u8, body, "\"error\"") == null) return false;
    const v = js.parse(a, body) orelse return false;
    const e = js.obj(v, "error") orelse return false;
    return e == .object;
}

fn oom() Result {
    return .{ .fail = .{ .info = .{ .class = .failed, .msg = "out of memory" } } };
}

test "ids are digits only" {
    try std.testing.expect(idOk("123456"));
    try std.testing.expect(!idOk(""));
    try std.testing.expect(!idOk("12/../x"));
    try std.testing.expect(!idOk("12 34"));
}
