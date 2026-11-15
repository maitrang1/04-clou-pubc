// Dailymotion error reply -> class. The table is data (df-dmot-errors.json), embedded at build time. v2 envelope: {"error":{"code","message","correlation_id","details"}}; the token host answers OAuth style {"error":"invalid_client",...}.
const std = @import("std");

pub const Class = enum { ok, expired, blocked, breaker, rate, failed, retry };
pub const Info = struct { class: Class, code: []const u8 = "", msg: []const u8 = "", corr: []const u8 = "", known: bool = false };

const table_text = @embedFile("df-dmot-errors.json");
const Row = struct { code: []const u8 = "", status: u16 = 0, class: []const u8, why: []const u8 = "" };
const Table = struct { version: u32 = 0, note: []const u8 = "", codes: []const Row = &.{}, http: []const Row = &.{}, access_errors: []const Row = &.{} };

pub fn classOf(s: []const u8) Class {
    if (std.mem.eql(u8, s, "expired")) return .expired;
    if (std.mem.eql(u8, s, "blocked")) return .blocked;
    if (std.mem.eql(u8, s, "breaker")) return .breaker;
    if (std.mem.eql(u8, s, "rate")) return .rate;
    if (std.mem.eql(u8, s, "retry")) return .retry;
    return .failed;
}

fn table(a: std.mem.Allocator) ?Table {
    return std.json.parseFromSliceLeaky(Table, a, table_text, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch null;
}

// body -> class. A code in the table wins; else the HTTP status; else 5xx = retry; any other 4xx = failed (known=false: the caller counts it, two in a row open the breaker).
pub fn classify(a: std.mem.Allocator, http: u16, body: []const u8) Info {
    const tbl = table(a) orelse return .{ .class = .failed, .msg = "error table unreadable" };
    var code: []const u8 = "";
    var msg: []const u8 = "";
    var corr: []const u8 = "";
    if (std.json.parseFromSliceLeaky(std.json.Value, a, body, .{})) |v| {
        if (v == .object) if (v.object.get("error")) |e| switch (e) {
            .object => |o| {
                if (o.get("code")) |c| if (c == .string) {
                    code = c.string;
                };
                if (o.get("message")) |m| if (m == .string) {
                    msg = m.string;
                };
                if (o.get("correlation_id")) |c| if (c == .string) {
                    corr = c.string;
                };
            },
            .string => |s| {
                code = s; // OAuth style
                if (v.object.get("error_description")) |m| if (m == .string) {
                    msg = m.string;
                };
            },
            else => {},
        };
    } else |_| {}
    if (code.len > 0) for (tbl.codes) |r| if (std.mem.eql(u8, r.code, code)) return .{ .class = classOf(r.class), .code = code, .msg = if (msg.len > 0) msg else r.why, .corr = corr, .known = true };
    for (tbl.http) |r| if (r.status == http) return .{ .class = classOf(r.class), .code = code, .msg = msg, .corr = corr, .known = true };
    if (http >= 500) return .{ .class = .retry, .code = code, .msg = msg, .corr = corr, .known = true };
    return .{ .class = .failed, .code = code, .msg = msg, .corr = corr };
}

// a video's access_error (DM0xx) -> class, or null when the code is not in the table
pub fn accessClass(a: std.mem.Allocator, code: []const u8) ?Class {
    const tbl = table(a) orelse return null;
    for (tbl.access_errors) |r| if (std.mem.eql(u8, r.code, code)) return classOf(r.class);
    return null;
}

test "codes map to classes, OAuth style and envelope style" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqual(Class.expired, classify(a, 401, "{\"error\":{\"code\":\"AUTHORIZATION_EXPIRED\",\"message\":\"x\"}}").class);
    try std.testing.expectEqual(Class.breaker, classify(a, 403, "{\"error\":{\"code\":\"MISSING_PERMISSIONS\"}}").class);
    try std.testing.expectEqual(Class.breaker, classify(a, 403, "").class);
    try std.testing.expectEqual(Class.failed, classify(a, 422, "{\"error\":{\"code\":\"MISSING_REQUIRED_VALUE\"}}").class);
    try std.testing.expect(classify(a, 422, "{\"error\":{\"code\":\"MISSING_REQUIRED_VALUE\"}}").known);
    try std.testing.expectEqual(Class.rate, classify(a, 429, "{\"error\":{\"code\":\"RATE_LIMIT_EXCEEDED\"}}").class);
    try std.testing.expectEqual(Class.rate, classify(a, 429, "").class);
    try std.testing.expectEqual(Class.retry, classify(a, 503, "oops").class);
    try std.testing.expectEqual(Class.blocked, classify(a, 400, "{\"error\":\"invalid_client\",\"error_description\":\"bad key\"}").class);
    try std.testing.expectEqualStrings("bad key", classify(a, 400, "{\"error\":\"invalid_client\",\"error_description\":\"bad key\"}").msg);
    // an unknown 4xx code: failed and NOT known (counted toward the breaker by the caller)
    const u = classify(a, 400, "{\"error\":{\"code\":\"UPLOAD_LIMIT_X\",\"correlation_id\":\"c-1\"}}");
    try std.testing.expectEqual(Class.failed, u.class);
    try std.testing.expect(!u.known);
    try std.testing.expectEqualStrings("c-1", u.corr);
    try std.testing.expectEqual(Class.failed, classify(a, 400, "{\"weird\":1}").class);
    try std.testing.expectEqual(Class.breaker, accessClass(a, "DM005").?);
    try std.testing.expectEqual(Class.failed, accessClass(a, "DM011").?);
    try std.testing.expect(accessClass(a, "DM999") == null);
}
