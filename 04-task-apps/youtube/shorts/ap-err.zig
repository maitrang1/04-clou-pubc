// =====================================================================
// Des: Turns a Google error answer into a class the app acts on - stop for the day, hard stop, blocked, plain failure, retryable - using the reason table in df-yout-errors.json
// Flo: parse {error:{errors:[{reason}]}} > look the reason up in the data table > else decide by HTTP status
// Cre: 2026-11-15                          - | Mod: 2026-11-15
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: HTTP status and body text
// Out: Verdict {class, reason, why}
// Run: not run directly - imported by ap-session, ap-upload, ap-status, ap-list, cm-publish
// =====================================================================
const std = @import("std");

pub const Class = enum {
    stop_quota, // API project quota: stop until Pacific midnight
    stop_channel, // channel's own daily limit: same remedy, other cause
    hard, // refused by YouTube: breaker open, a person looks
    blocked, // token / channel problem: stop, fix by hand
    fail, // this video failed, no retry
    notfound,
    retry, // 5xx: worth a retry
    unauth, // 401: refresh the access token once
    unknown,
};

pub const Verdict = struct { class: Class, reason: []const u8, why: []const u8, status: u16 = 0, retry_after_s: u32 = 0 };

const Row = struct { reason: []const u8, class: []const u8, why: []const u8 };

const table_json = @embedFile("df-yout-errors.json");

fn classOf(name: []const u8) ?Class {
    inline for (@typeInfo(Class).@"enum".fields) |f| if (std.mem.eql(u8, name, f.name)) return @field(Class, f.name);
    return null;
}

// first error reason inside a Google error body, or ""
pub fn reasonOf(a: std.mem.Allocator, body: []const u8) []const u8 {
    const Inner = struct { reason: []const u8 = "" };
    const Err = struct { code: u32 = 0, message: []const u8 = "", errors: []const Inner = &.{} };
    const Body = struct { @"error": ?Err = null };
    const p = std.json.parseFromSliceLeaky(Body, a, body, .{ .ignore_unknown_fields = true }) catch return "";
    const e = p.@"error" orelse return "";
    if (e.errors.len == 0) return "";
    return e.errors[0].reason;
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
    if (status == 404) return .{ .class = .notfound, .reason = reason, .why = "not found (or the upload session expired)" };
    if (status == 500 or status == 502 or status == 503 or status == 504) return .{ .class = .retry, .reason = reason, .why = "YouTube had a server problem" };
    if (status >= 400) return .{ .class = .fail, .reason = reason, .why = "YouTube refused the request" };
    return .{ .class = .unknown, .reason = reason, .why = "unexpected answer" };
}

test "the shipped table parses and every class name is known" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const rows = try std.json.parseFromSliceLeaky([]const Row, ar.allocator(), table_json, .{});
    try std.testing.expect(rows.len >= 15);
    for (rows) |r| try std.testing.expect(classOf(r.class) != null);
}

fn errBody(comptime reason: []const u8) []const u8 {
    return "{\"error\":{\"code\":403,\"message\":\"m\",\"errors\":[{\"reason\":\"" ++ reason ++ "\",\"domain\":\"youtube.quota\"}]}}";
}

test "reasons map to classes; the two daily limits stay separate" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    try std.testing.expect(classify(a, 403, errBody("quotaExceeded")).class == .stop_quota);
    try std.testing.expect(classify(a, 400, errBody("uploadLimitExceeded")).class == .stop_channel);
    try std.testing.expect(classify(a, 403, errBody("forbidden")).class == .hard);
    try std.testing.expect(classify(a, 403, errBody("forbiddenPrivacySetting")).class == .hard);
    try std.testing.expect(classify(a, 403, errBody("insufficientPermissions")).class == .blocked);
    try std.testing.expect(classify(a, 401, errBody("youtubeSignupRequired")).class == .blocked);
    try std.testing.expect(classify(a, 400, errBody("invalidTitle")).class == .fail);
    try std.testing.expect(classify(a, 404, errBody("videoNotFound")).class == .notfound);
}

test "unknown reasons and bad bodies fall back to the HTTP status" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    try std.testing.expect(classify(a, 503, "").class == .retry);
    try std.testing.expect(classify(a, 502, "<html>").class == .retry);
    try std.testing.expect(classify(a, 401, "{}").class == .unauth);
    try std.testing.expect(classify(a, 404, "").class == .notfound);
    try std.testing.expect(classify(a, 400, errBody("somethingNew")).class == .fail);
    try std.testing.expectEqualStrings("somethingNew", classify(a, 400, errBody("somethingNew")).reason);
    try std.testing.expect(classify(a, 200, "").class == .unknown);
}
// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
