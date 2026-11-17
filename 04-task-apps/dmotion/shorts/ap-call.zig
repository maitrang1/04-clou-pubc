// One Dailymotion call: guard the URL, pin the IP, send (Bearer header only when a token is given, never in a URL, never to the upload host), classify the answer.
const std = @import("std");
const Ctx = @import("co-ctx.zig").Ctx;
const guard = @import("co-guard.zig");
const net = @import("co-net.zig");
const err = @import("ap-error.zig");
const log = @import("co-log.zig");

pub const Reply = struct { status: u16, body: []const u8, headers: []const u8, location: []const u8 = "" };
pub const Fail = struct { info: err.Info, http: u16 = 0, net: ?net.Err = null, sent: bool = false, body: []const u8 = "", retry_after_s: u32 = 0 };
pub const Result = union(enum) { ok: Reply, fail: Fail };
pub fn Out(comptime T: type) type {
    return union(enum) { ok: T, fail: Fail };
}

pub const Spec = struct {
    method: []const u8 = "GET",
    url: []const u8,
    token: []const u8 = "", // "" = no Authorization header (token request, upload host)
    json: ?[]const u8 = null,
    form: ?[]const u8 = null, // application/x-www-form-urlencoded body (token request)
    body_file: ?net.BodyFile = null,
    body_head: []const u8 = "",
    body_tail: []const u8 = "",
    headers: []const std.http.Header = &.{},
    timeout_s: u32 = 0, // 0 = net.timeout_s
};

fn netInfo(e: net.Err) err.Info {
    return .{ .class = .retry, .msg = @errorName(e) };
}

// ids that go into URL paths: letters, digits, dash, underscore only (Dailymotion ids look like x9xyz456 / k123abc)
pub fn idOk(s: []const u8) bool {
    if (s.len == 0 or s.len > 64) return false;
    for (s) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_')) return false;
    return true;
}

// percent-encode a form/query value (RFC 3986 unreserved stay)
pub fn pct(a: std.mem.Allocator, s: []const u8) ![]u8 {
    var o: std.ArrayList(u8) = .empty;
    for (s) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') try o.append(a, c) else try o.print(a, "%{X:0>2}", .{c});
    }
    return o.items;
}

pub fn apiUrl(cx: *const Ctx, a: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "{s}/{s}", .{ std.mem.trimEnd(u8, cx.cfg.dmot.api_base, "/"), path });
}

pub fn call(cx: *const Ctx, a: std.mem.Allocator, sp: Spec) Result {
    const t = guard.parseUrl(a, sp.url, .{ .allow_hosts = cx.cfg.net.allow_hosts, .mock = cx.mock }) catch |e| return .{ .fail = .{ .info = .{ .class = .failed, .msg = @errorName(e) } } };
    const ip = guard.pin(cx.io, cx.resolver, t) catch |e| return .{ .fail = .{ .info = .{ .class = .retry, .msg = @errorName(e) } } };
    var hs: std.ArrayList(std.http.Header) = .empty;
    if (sp.token.len > 0) {
        const auth = std.fmt.allocPrint(a, "Bearer {s}", .{sp.token}) catch return oom();
        hs.append(a, .{ .name = "Authorization", .value = auth }) catch return oom();
    }
    if (sp.json != null) hs.append(a, .{ .name = "Content-Type", .value = "application/json" }) catch return oom();
    if (sp.form != null) hs.append(a, .{ .name = "Content-Type", .value = "application/x-www-form-urlencoded" }) catch return oom();
    hs.append(a, .{ .name = "Accept", .value = "application/json" }) catch return oom();
    hs.appendSlice(a, sp.headers) catch return oom();
    var flushed = false;
    const tmo = if (sp.timeout_s == 0) cx.cfg.net.timeout_s else sp.timeout_s;
    const r = net.call(cx.io, a, t, ip, .{
        .ua = cx.cfg.net.user_agent,
        .timeout_s = tmo,
        .cap_bytes = @as(usize, cx.cfg.net.body_cap_kb) * 1024,
        .headers = hs.items,
        .method = sp.method,
        .body = sp.json orelse sp.form,
        .body_file = sp.body_file,
        .body_head = sp.body_head,
        .body_tail = sp.body_tail,
        .flushed = &flushed,
    }) catch |e| {
        const red = guard.redactUrl(a, sp.url) catch "?";
        log.log(cx, "warn", "net {s} {s} {s}", .{ sp.method, red, @errorName(e) });
        return .{ .fail = .{ .info = netInfo(e), .net = e, .sent = flushed } };
    };
    if (r.status >= 200 and r.status < 300) return .{ .ok = .{ .status = r.status, .body = r.body, .headers = r.headers, .location = r.location } };
    const info = err.classify(a, r.status, r.body);
    const red = guard.redactUrl(a, sp.url) catch "?";
    log.log(cx, "warn", "http {d} {s} {s} class={s} code={s} corr={s}", .{ r.status, sp.method, red, @tagName(info.class), info.code, info.corr });
    return .{ .fail = .{ .info = info, .http = r.status, .sent = flushed, .body = r.body, .retry_after_s = r.retry_after_s } };
}

fn oom() Result {
    return .{ .fail = .{ .info = .{ .class = .failed, .msg = "out of memory" } } };
}

test "ids are plain and bounded; pct encodes" {
    try std.testing.expect(idOk("x9xyz456"));
    try std.testing.expect(idOk("k123-abc_9"));
    try std.testing.expect(!idOk(""));
    try std.testing.expect(!idOk("12/../x"));
    try std.testing.expect(!idOk("12 34"));
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("a%26b%3Dc%20d", try pct(arena.allocator(), "a&b=c d"));
}
