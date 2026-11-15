// =====================================================================
// Des: Turns a Vimeo error answer into a class the app acts on - stop for the day, hard stop, blocked, rate limited, stale offset, plain failure, retryable - using the error-code table in df-vime-errors.json
// Flo: parse {error_code} from the body > look the code up in the data table > else decide by HTTP status
// Cre: 2026-11-16                          - | Mod: 2026-11-16
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: HTTP status and body text
// Out: Verdict {class, reason (the error code), why}
// Run: not run directly - imported by ap-call and every ap-* client, cm-send, cm-publish
// =====================================================================
const std = @import("std");

pub const Class = enum {
    stop_quota, // upload space / quota used up: stop for the day (the quota check names the reset)
    hard, // refused (403 that is not a quota): breaker open, a person looks
    blocked, // token problem: stop, fix by hand (no refresh exists on Vimeo)
    rate, // 429 / 9000: too many calls per minute
    conflict, // 409: the tus offset was stale, ask again
    fail, // this video failed, no retry
    notfound,
    retry, // 5xx: worth a retry
    unauth, // 401: the token is not accepted
    unknown,
};

pub const Verdict = struct { class: Class, reason: []const u8, why: []const u8, status: u16 = 0, retry_after_s: u32 = 0 };

const Row = struct { reason: []const u8, class: []const u8, why: []const u8 };

const table_json = @embedFile("df-vime-errors.json");

fn classOf(name: []const u8) ?Class {
    inline for (@typeInfo(Class).@"enum".fields) |f| if (std.mem.eql(u8, name, f.name)) return @field(Class, f.name);
    return null;
}

// the error_code of a Vimeo error body as text, or ""
pub fn reasonOf(a: std.mem.Allocator, body: []const u8) []const u8 {
    const Body = struct { error_code: u32 = 0 };
    const p = std.json.parseFromSliceLeaky(Body, a, body, .{ .ignore_unknown_fields = true }) catch return "";
    if (p.error_code == 0) return "";
    return std.fmt.allocPrint(a, "{d}", .{p.error_code}) catch "";
}

pub fn classify(a: std.mem.Allocator, status: u16, body: []const u8) Verdict {
    var v = classifyInner(a, status, body);
    v.status = status;
    return v;
}

fn classifyInner(a: std.mem.Allocator, status: u16, body: []const u8) Verdict {
    const reason = reasonOf(a, body);
    if (reason.len > 0) {
        const rows = std.json.parseFromSliceLeaky([]const Row, a, table_json, .{}) catch return byStatus(status, reason);
        for (rows) |r| if (std.mem.eql(u8, r.reason, reason)) {
            return .{ .class = classOf(r.class) orelse .unknown, .reason = reason, .why = r.why };
        };
    }
    return byStatus(status, reason);
}

fn byStatus(status: u16, reason: []const u8) Verdict {
    if (status == 401) return .{ .class = .unauth, .reason = reason, .why = "the access token was refused" };
    if (status == 429) return .{ .class = .rate, .reason = reason, .why = "too many requests per minute" };
    if (status == 409) return .{ .class = .conflict, .reason = reason, .why = "the upload offset was out of date" };
    if (status == 404 or status == 410) return .{ .class = .notfound, .reason = reason, .why = "not found (or the upload link expired)" };
    if (status == 500 or status == 502 or status == 503 or status == 504) return .{ .class = .retry, .reason = reason, .why = "Vimeo had a server problem" };
    // a 403 that is not a known quota code may be missing upload access or a refused setting: a person must look
    if (status == 403) return .{ .class = .hard, .reason = reason, .why = "Vimeo refused the request (upload access missing? see 10-HOW-TO)" };
    if (status >= 400) return .{ .class = .fail, .reason = reason, .why = "Vimeo refused the request" };
    return .{ .class = .unknown, .reason = reason, .why = "unexpected answer" };
}

test "the shipped table parses and every class name is known" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const rows = try std.json.parseFromSliceLeaky([]const Row, ar.allocator(), table_json, .{});
    try std.testing.expect(rows.len >= 12);
    for (rows) |r| try std.testing.expect(classOf(r.class) != null);
}

fn errBody(comptime code: []const u8) []const u8 {
    return "{\"error\":\"m\",\"link\":null,\"developer_message\":\"d\",\"error_code\":" ++ code ++ "}";
}

test "codes map to classes; the three upload limits stay apart in the message" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    try std.testing.expect(classify(a, 403, errBody("4101")).class == .stop_quota);
    const w = classify(a, 403, errBody("4102"));
    try std.testing.expect(w.class == .stop_quota and std.mem.indexOf(u8, w.why, "weekly") != null);
    try std.testing.expect(std.mem.indexOf(u8, classify(a, 403, errBody("4104")).why, "daily") != null);
    try std.testing.expect(classify(a, 401, errBody("8002")).class == .unauth);
    try std.testing.expect(classify(a, 401, errBody("8003")).class == .unauth);
    try std.testing.expect(classify(a, 429, errBody("9000")).class == .rate);
    try std.testing.expect(classify(a, 400, errBody("2204")).class == .fail);
    try std.testing.expect(classify(a, 400, errBody("2230")).class == .fail);
    try std.testing.expect(classify(a, 400, errBody("2002")).class == .fail);
}

test "unknown codes and bad bodies fall back to the HTTP status; a stray 403 is hard" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    try std.testing.expect(classify(a, 503, "").class == .retry);
    try std.testing.expect(classify(a, 502, "<html>").class == .retry);
    try std.testing.expect(classify(a, 401, "{}").class == .unauth);
    try std.testing.expect(classify(a, 404, "").class == .notfound);
    try std.testing.expect(classify(a, 409, "").class == .conflict);
    try std.testing.expect(classify(a, 429, "").class == .rate);
    try std.testing.expect(classify(a, 403, errBody("7777")).class == .hard);
    try std.testing.expect(classify(a, 403, "").class == .hard);
    try std.testing.expect(classify(a, 400, errBody("7777")).class == .fail);
    try std.testing.expectEqualStrings("7777", classify(a, 400, errBody("7777")).reason);
    try std.testing.expect(classify(a, 200, "").class == .unknown);
}
// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
