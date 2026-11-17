// One LinkedIn call: guard the URL, pin the IP, send (Bearer token in the header only, never in a URL), classify the answer.
// Part uploads go to LinkedIn's signed URLs: token "" = no Authorization header at all, label = what the log says instead of the (secret) URL.
const std = @import("std");
const Ctx = @import("co-ctx.zig").Ctx;
const guard = @import("co-guard.zig");
const net = @import("co-net.zig");
const err = @import("ap-error.zig");
const log = @import("co-log.zig");

pub const Reply = struct { status: u16, body: []const u8, headers: []const u8 };
pub const Fail = struct { info: err.Info, http: u16 = 0, net: ?net.Err = null, sent: bool = false, body: []const u8 = "" };
pub const Result = union(enum) { ok: Reply, fail: Fail };
pub fn Out(comptime T: type) type {
    return union(enum) { ok: T, fail: Fail };
}

pub const Spec = struct {
    method: []const u8 = "GET",
    url: []const u8,
    token: []const u8 = "", // "" = no Authorization header
    rest: bool = true, // versioned LinkedIn call: Linkedin-Version + X-Restli-Protocol-Version
    json: ?[]const u8 = null, // request body (JSON unless content_type says otherwise)
    content_type: []const u8 = "application/json",
    body_file: ?net.BodyFile = null,
    headers: []const std.http.Header = &.{},
    timeout_s: u32 = 0, // 0 = net.timeout_s
    label: []const u8 = "", // log this instead of the url
};

fn netInfo(e: net.Err) err.Info {
    return .{ .class = .retry, .msg = @errorName(e) };
}

pub fn restUrl(cx: *const Ctx, a: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "{s}/rest/{s}", .{ std.mem.trimEnd(u8, cx.cfg.api.base, "/"), path });
}
pub fn v2Url(cx: *const Ctx, a: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "{s}/v2/{s}", .{ std.mem.trimEnd(u8, cx.cfg.api.base, "/"), path });
}
pub fn oauthUrl(cx: *const Ctx, a: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "{s}/oauth/v2/{s}", .{ std.mem.trimEnd(u8, cx.cfg.api.oauth_base, "/"), path });
}

// a URN that goes into a URL path: urn:li:<type>:<id>, id = letters digits _ - only
pub fn urnOk(urn: []const u8, kind: []const u8) bool {
    var pre: [32]u8 = undefined;
    const p = std.fmt.bufPrint(&pre, "urn:li:{s}:", .{kind}) catch return false;
    if (!std.mem.startsWith(u8, urn, p) or urn.len == p.len or urn.len > 120) return false;
    for (urn[p.len..]) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-')) return false;
    return true;
}
// person URN id part (what the owner stores): letters digits _ - only
pub fn idOk(s: []const u8) bool {
    if (s.len == 0 or s.len > 80) return false;
    for (s) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-')) return false;
    return true;
}
pub fn urnEnc(a: std.mem.Allocator, urn: []const u8) ![]u8 {
    var o: std.ArrayList(u8) = .empty;
    for (urn) |c| {
        if (c == ':') try o.appendSlice(a, "%3A") else try o.append(a, c);
    }
    return o.items;
}

pub fn call(cx: *const Ctx, a: std.mem.Allocator, sp: Spec) Result {
    const t = guard.parseUrl(a, sp.url, .{ .allow_hosts = cx.cfg.net.allow_hosts, .mock = cx.mock }) catch |e| return .{ .fail = .{ .info = .{ .class = .failed, .msg = @errorName(e) } } };
    const ip = guard.pin(cx.io, cx.resolver, t) catch |e| return .{ .fail = .{ .info = .{ .class = .retry, .msg = @errorName(e) } } };
    var hs: std.ArrayList(std.http.Header) = .empty;
    if (sp.token.len > 0) {
        const auth = std.fmt.allocPrint(a, "Bearer {s}", .{sp.token}) catch return oom();
        hs.append(a, .{ .name = "Authorization", .value = auth }) catch return oom();
    }
    if (sp.rest) {
        hs.append(a, .{ .name = "Linkedin-Version", .value = cx.cfg.api.version }) catch return oom();
        hs.append(a, .{ .name = "X-Restli-Protocol-Version", .value = "2.0.0" }) catch return oom();
    }
    if (sp.json != null) hs.append(a, .{ .name = "Content-Type", .value = sp.content_type }) catch return oom();
    hs.appendSlice(a, sp.headers) catch return oom();
    var flushed = false;
    const tmo = if (sp.timeout_s == 0) cx.cfg.net.timeout_s else sp.timeout_s;
    const shown = if (sp.label.len > 0) sp.label else (guard.redactUrl(a, sp.url) catch "?");
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
        log.log(cx, "warn", "net {s} {s} {s}", .{ sp.method, shown, @errorName(e) });
        return .{ .fail = .{ .info = netInfo(e), .net = e, .sent = flushed } };
    };
    const rep = Reply{ .status = r.status, .body = r.body, .headers = r.headers };
    if (r.status >= 200 and r.status < 300) return .{ .ok = rep };
    const info = err.classify(a, r.status, r.body);
    log.log(cx, "warn", "http {d} {s} {s} class={s} code={s}", .{ r.status, sp.method, shown, @tagName(info.class), info.code });
    return .{ .fail = .{ .info = info, .http = r.status, .sent = flushed, .body = r.body } };
}

// header of a reply, any letter case ("" when absent)
pub fn header(rep: Reply, name: []const u8) []const u8 {
    return net.headerValue(rep.headers, name);
}

fn oom() Result {
    return .{ .fail = .{ .info = .{ .class = .failed, .msg = "out of memory" } } };
}

test "urn and id shapes that may enter a URL" {
    try std.testing.expect(urnOk("urn:li:video:C5505AQH-oV1qvnFtKA", "video"));
    try std.testing.expect(urnOk("urn:li:share:6844785523593134080", "share"));
    try std.testing.expect(!urnOk("urn:li:video:", "video"));
    try std.testing.expect(!urnOk("urn:li:video:a/../b", "video"));
    try std.testing.expect(!urnOk("urn:li:person:abc", "video"));
    try std.testing.expect(!urnOk("urn:li:video:a b", "video"));
    try std.testing.expect(idOk("782bbtaQ"));
    try std.testing.expect(!idOk(""));
    try std.testing.expect(!idOk("a/b"));
}
test "urn is percent-encoded for a path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("urn%3Ali%3Avideo%3AABC", try urnEnc(arena.allocator(), "urn:li:video:ABC"));
}
