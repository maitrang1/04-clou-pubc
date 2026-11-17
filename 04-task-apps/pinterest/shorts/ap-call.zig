// One Pinterest call: guard the URL, pin the IP, send with the token in the Authorization header (never in the URL), classify the answer.
// The media upload host gets NO Authorization header (the signed form fields are the auth).
const std = @import("std");
const Ctx = @import("co-ctx.zig").Ctx;
const guard = @import("co-guard.zig");
const net = @import("co-net.zig");
const err = @import("ap-error.zig");
const log = @import("co-log.zig");
const caps = @import("rw-caps.zig");

// worst rate-limit use seen since the last reset (percent), Pinterest's reset hint (minutes), calls made to the API host this run
pub var usage_pct: u32 = 0;
pub var usage_regain: u32 = 0;
pub var calls_made: u32 = 0;
pub fn resetUsage() void {
    usage_pct = 0;
    usage_regain = 0;
    calls_made = 0;
}

pub const Reply = struct { status: u16, body: []const u8, headers: []const u8 };
pub const Fail = struct { info: err.Info, http: u16 = 0, net: ?net.Err = null, sent: bool = false, body: []const u8 = "" };
pub const Result = union(enum) { ok: Reply, fail: Fail };
pub fn Out(comptime T: type) type {
    return union(enum) { ok: T, fail: Fail };
}

pub const Auth = union(enum) { none, bearer: []const u8, basic: []const u8 }; // basic = "client_id:client_secret"

pub const Spec = struct {
    method: []const u8 = "GET",
    url: []const u8,
    auth: Auth = .none,
    body: ?[]const u8 = null,
    ctype: []const u8 = "application/json",
    body_file: ?net.BodyFile = null,
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

pub fn apiUrl(cx: *const Ctx, a: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "{s}/{s}/{s}", .{ std.mem.trimEnd(u8, cx.cfg.api.base, "/"), cx.cfg.api.version, path });
}

pub fn call(cx: *const Ctx, a: std.mem.Allocator, sp: Spec) Result {
    const t = guard.parseUrl(a, sp.url, .{ .allow_hosts = cx.cfg.net.allow_hosts, .mock = cx.mock }) catch |e| return .{ .fail = .{ .info = .{ .class = .failed, .msg = @errorName(e) } } };
    const ip = guard.pin(cx.io, cx.resolver, t) catch |e| return .{ .fail = .{ .info = .{ .class = .retry, .msg = @errorName(e) } } };
    var hs: std.ArrayList(std.http.Header) = .empty;
    switch (sp.auth) {
        .none => {},
        .bearer => |tok| {
            calls_made += 1;
            const v = std.fmt.allocPrint(a, "Bearer {s}", .{tok}) catch return oom();
            hs.append(a, .{ .name = "Authorization", .value = v }) catch return oom();
        },
        .basic => |idsec| {
            calls_made += 1;
            const enc = std.base64.standard.Encoder;
            const buf = a.alloc(u8, enc.calcSize(idsec.len)) catch return oom();
            const v = std.fmt.allocPrint(a, "Basic {s}", .{enc.encode(buf, idsec)}) catch return oom();
            hs.append(a, .{ .name = "Authorization", .value = v }) catch return oom();
        },
    }
    if (sp.body != null or sp.body_file != null) hs.append(a, .{ .name = "Content-Type", .value = sp.ctype }) catch return oom();
    var flushed = false;
    const tmo = if (sp.timeout_s == 0) cx.cfg.net.timeout_s else sp.timeout_s;
    const r = net.call(cx.io, a, t, ip, .{
        .ua = cx.cfg.net.user_agent,
        .timeout_s = tmo,
        .cap_bytes = @as(usize, cx.cfg.net.body_cap_kb) * 1024,
        .headers = hs.items,
        .method = sp.method,
        .body = sp.body,
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
    if (r.status >= 200 and r.status < 300) return .{ .ok = rep };
    const info = err.classify(a, r.status, r.body);
    const red = guard.redactUrl(a, sp.url) catch "?";
    log.log(cx, "warn", "http {d} {s} {s} class={s} code={d}", .{ r.status, sp.method, red, @tagName(info.class), info.code });
    return .{ .fail = .{ .info = info, .http = r.status, .sent = flushed, .body = r.body } };
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
