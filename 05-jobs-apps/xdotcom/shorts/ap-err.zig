// =====================================================================
// Des: Turns an X error answer into a class the app acts on - stop for the window, credits, blocked, duplicate (unsure), plain failure, retryable, refresh-token - from the reason table in df-xdot-errors.json, reading all three body shapes (problem+json, plain code/message, the legacy errors array)
// Flo: parse the body tolerantly > match a table row on type / detail / code > else decide by HTTP status
// Cre: 2026-11-16                          - | Mod: 2026-11-16
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: HTTP status and body text
// Out: Verdict {class, reason, why, status, retry_after_s}
// Run: not run directly - imported by ap-call, ap-upload, ap-post, ap-list, cm-send
// =====================================================================
const std = @import("std");

pub const Class = enum {
    stop_rate, // rate limit / window: stop until it resets
    credits, // no credits or a spending cap: breaker, a person buys credits
    blocked, // token, scope, app or account problem: stop, fix by hand
    duplicate, // X says duplicate content: the post may be live (unsure)
    fail, // this request failed, no retry
    notfound,
    retry, // 5xx: worth a retry
    unauth, // 401: refresh the access token once
    unknown,
};

pub const Verdict = struct { class: Class, reason: []const u8, why: []const u8, status: u16 = 0, retry_after_s: u32 = 0 };

const Row = struct { on: []const u8, has: []const u8, class: []const u8, why: []const u8 };

const table_json = @embedFile("df-xdot-errors.json");

fn classOf(name: []const u8) ?Class {
    inline for (@typeInfo(Class).@"enum".fields) |f| if (std.mem.eql(u8, name, f.name)) return @field(Class, f.name);
    return null;
}

const Inner = struct { code: i64 = 0, message: []const u8 = "" };
// every field optional: the three shapes share this struct (problem+json, {code,message}, {errors:[...]})
const Body = struct {
    type: []const u8 = "",
    title: []const u8 = "",
    detail: []const u8 = "",
    message: []const u8 = "",
    code: i64 = 0,
    errors: []const Inner = &.{},
};

pub const Parsed = struct { kind: []const u8 = "", detail: []const u8 = "", code: i64 = 0 };

// the type's last path segment ("https://api.x.com/2/problems/credits-depleted" -> "credits-depleted"), the detail or message text, a numeric code
pub fn parseBody(a: std.mem.Allocator, body: []const u8) Parsed {
    const b = std.json.parseFromSliceLeaky(Body, a, body, .{ .ignore_unknown_fields = true }) catch return .{};
    var p = Parsed{ .kind = b.type, .detail = if (b.detail.len > 0) b.detail else b.message, .code = b.code };
    if (std.mem.lastIndexOfScalar(u8, p.kind, '/')) |i| p.kind = p.kind[i + 1 ..];
    if (std.mem.eql(u8, p.kind, "blank")) p.kind = ""; // "about:blank" carries no information
    if (std.mem.eql(u8, p.kind, "about:blank")) p.kind = "";
    if (b.errors.len > 0) {
        if (p.code == 0) p.code = b.errors[0].code;
        if (p.detail.len == 0) p.detail = b.errors[0].message;
    }
    if (p.detail.len == 0) p.detail = b.title;
    return p;
}

fn containsFold(h: []const u8, n: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(h, n) != null;
}

pub fn classify(a: std.mem.Allocator, status: u16, body: []const u8) Verdict {
    var v = classifyInner(a, status, body);
    v.status = status;
    return v;
}

fn reasonOf(p: Parsed, a: std.mem.Allocator) []const u8 {
    if (p.kind.len > 0) return p.kind;
    if (p.code != 0) return std.fmt.allocPrint(a, "code {d}", .{p.code}) catch "";
    return "";
}

fn classifyInner(a: std.mem.Allocator, status: u16, body: []const u8) Verdict {
    const p = parseBody(a, body);
    const reason = reasonOf(p, a);
    if (std.json.parseFromSliceLeaky([]const Row, a, table_json, .{})) |rows| {
        var code_buf: [24]u8 = undefined;
        const code_s = std.fmt.bufPrint(&code_buf, "{d}", .{p.code}) catch "";
        for (rows) |r| {
            const hit = if (std.mem.eql(u8, r.on, "type")) containsFold(p.kind, r.has) else if (std.mem.eql(u8, r.on, "detail")) containsFold(p.detail, r.has) else if (std.mem.eql(u8, r.on, "code")) (p.code != 0 and std.mem.eql(u8, code_s, r.has)) else false;
            if (hit) return .{ .class = classOf(r.class) orelse .unknown, .reason = if (reason.len > 0) reason else r.has, .why = r.why };
        }
    } else |_| {}
    return byStatus(status, reason);
}

fn byStatus(status: u16, reason: []const u8) Verdict {
    if (status == 401) return .{ .class = .unauth, .reason = reason, .why = "the access token was refused" };
    if (status == 402) return .{ .class = .credits, .reason = reason, .why = "payment required (HTTP 402): check the credits in the Developer Console" };
    if (status == 429) return .{ .class = .stop_rate, .reason = reason, .why = "too many requests: wait for the rate-limit window" };
    if (status == 404) return .{ .class = .notfound, .reason = reason, .why = "not found (or the media expired)" };
    if (status == 500 or status == 502 or status == 503 or status == 504) return .{ .class = .retry, .reason = reason, .why = "X had a server problem" };
    if (status == 403) return .{ .class = .blocked, .reason = reason, .why = "X refused: forbidden" };
    if (status >= 400) return .{ .class = .fail, .reason = reason, .why = "X refused the request" };
    return .{ .class = .unknown, .reason = reason, .why = "unexpected answer" };
}

test "the shipped table parses and every class name is known" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const rows = try std.json.parseFromSliceLeaky([]const Row, ar.allocator(), table_json, .{});
    try std.testing.expect(rows.len >= 10);
    for (rows) |r| {
        try std.testing.expect(classOf(r.class) != null);
        try std.testing.expect(std.mem.eql(u8, r.on, "type") or std.mem.eql(u8, r.on, "detail") or std.mem.eql(u8, r.on, "code"));
    }
}

test "the three body shapes are read: problem+json, plain, legacy errors array" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const pj = parseBody(a, "{\"title\":\"Payment Required\",\"detail\":\"credits depleted\",\"type\":\"https://api.x.com/2/problems/credits-depleted\",\"status\":402}");
    try std.testing.expectEqualStrings("credits-depleted", pj.kind);
    try std.testing.expectEqualStrings("credits depleted", pj.detail);
    const pl = parseBody(a, "{\"code\":88,\"message\":\"Rate limit exceeded\"}");
    try std.testing.expectEqual(@as(i64, 88), pl.code);
    const lg = parseBody(a, "{\"errors\":[{\"code\":88,\"message\":\"Rate limit exceeded\"}]}");
    try std.testing.expectEqual(@as(i64, 88), lg.code);
    try std.testing.expectEqualStrings("Rate limit exceeded", lg.detail);
    const bl = parseBody(a, "{\"title\":\"Forbidden\",\"detail\":\"d\",\"type\":\"about:blank\",\"status\":403}");
    try std.testing.expectEqualStrings("", bl.kind);
    try std.testing.expectEqualStrings("", parseBody(a, "<html>").kind);
}

test "classes: credits, rate, duplicate, forbidden kinds, video too long, status fallbacks" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    try std.testing.expect(classify(a, 402, "{\"detail\":\"credits depleted\",\"status\":402,\"title\":\"Payment Required\",\"type\":\"https://api.x.com/2/problems/credits-depleted\"}").class == .credits);
    try std.testing.expect(classify(a, 402, "").class == .credits);
    try std.testing.expect(classify(a, 429, "{\"errors\":[{\"code\":88,\"message\":\"Rate limit exceeded\"}]}").class == .stop_rate);
    try std.testing.expect(classify(a, 429, "").class == .stop_rate);
    try std.testing.expect(classify(a, 403, "{\"detail\":\"You are not allowed to create a Tweet with duplicate content.\",\"type\":\"about:blank\",\"title\":\"Forbidden\",\"status\":403}").class == .duplicate);
    try std.testing.expect(classify(a, 403, "{\"title\":\"Forbidden\",\"detail\":\"This user is not allowed to post a video longer than 20 minutes.\",\"type\":\"about:blank\",\"status\":403}").class == .fail);
    try std.testing.expect(classify(a, 403, "{\"type\":\"https://api.x.com/2/problems/client-forbidden\",\"title\":\"Client Forbidden\",\"detail\":\"x\"}").class == .blocked);
    try std.testing.expect(classify(a, 403, "{\"detail\":\"You are not permitted to perform this action.\"}").class == .blocked);
    try std.testing.expect(classify(a, 403, "{}").class == .blocked);
    try std.testing.expect(classify(a, 400, "{\"type\":\"https://api.x.com/2/problems/usage-capped\",\"detail\":\"d\"}").class == .credits);
    try std.testing.expect(classify(a, 401, "{}").class == .unauth);
    try std.testing.expect(classify(a, 404, "").class == .notfound);
    try std.testing.expect(classify(a, 503, "").class == .retry);
    try std.testing.expect(classify(a, 502, "<html>").class == .retry);
    try std.testing.expect(classify(a, 400, "{\"detail\":\"bad text\"}").class == .fail);
    try std.testing.expect(classify(a, 200, "").class == .unknown);
    try std.testing.expectEqualStrings("credits-depleted", classify(a, 402, "{\"type\":\"https://api.x.com/2/problems/credits-depleted\"}").reason);
    try std.testing.expectEqual(@as(u16, 402), classify(a, 402, "").status);
}
// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
