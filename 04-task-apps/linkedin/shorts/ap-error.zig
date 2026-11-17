// LinkedIn error reply -> class. The table is data (df-link-errors.json), embedded at build time. Two body shapes are read: old {message, serviceErrorCode, status} and new (+ string `code`).
const std = @import("std");

pub const Class = enum { ok, blocked, failed, stop_day, retry, new_init };
pub const Info = struct { class: Class, code: []const u8 = "", msg: []const u8 = "" };

const table_text = @embedFile("df-link-errors.json");
const CRow = struct { code: []const u8 = "", class: []const u8, why: []const u8 = "" };
const HRow = struct { status: u16 = 0, class: []const u8, why: []const u8 = "" };
const Table = struct { version: u32 = 0, note: []const u8 = "", codes: []const CRow = &.{}, http: []const HRow = &.{} };

fn classOf(s: []const u8) Class {
    if (std.mem.eql(u8, s, "blocked")) return .blocked;
    if (std.mem.eql(u8, s, "failed")) return .failed;
    if (std.mem.eql(u8, s, "stop_day")) return .stop_day;
    if (std.mem.eql(u8, s, "retry")) return .retry;
    if (std.mem.eql(u8, s, "new_init")) return .new_init;
    return .failed;
}

fn hasDup(body: []const u8) bool {
    var buf: [2048]u8 = undefined;
    const n = @min(body.len, buf.len);
    for (body[0..n], 0..) |c, i| buf[i] = std.ascii.toLower(c);
    return std.mem.indexOf(u8, buf[0..n], "duplicate") != null;
}

// status-first, then the string code; unknown 4xx = failed (body goes to the ledger note), 5xx = retry
pub fn classify(a: std.mem.Allocator, http: u16, body: []const u8) Info {
    const tbl = std.json.parseFromSliceLeaky(Table, a, table_text, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return .{ .class = .failed, .msg = "error table unreadable" };
    var code: []const u8 = "";
    var msg: []const u8 = "";
    if (std.json.parseFromSliceLeaky(std.json.Value, a, body, .{})) |v| {
        if (v == .object) {
            if (v.object.get("code")) |c| if (c == .string) {
                code = c.string;
            };
            if (v.object.get("message")) |m| if (m == .string) {
                msg = m.string;
            };
        }
    } else |_| {}
    if (http == 422 and hasDup(body)) return .{ .class = .failed, .code = code, .msg = "duplicate post refused by LinkedIn (the text matches a recent post)" };
    for (tbl.http) |r| if (r.status == http) return .{ .class = classOf(r.class), .code = code, .msg = if (msg.len > 0) msg else r.why };
    if (code.len > 0) for (tbl.codes) |r| if (std.mem.eql(u8, r.code, code)) return .{ .class = classOf(r.class), .code = code, .msg = if (msg.len > 0) msg else r.why };
    if (http >= 500) return .{ .class = .retry, .code = code, .msg = msg };
    return .{ .class = .failed, .code = code, .msg = msg };
}

test "status first, then string code; both body shapes; unknown guessed never" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqual(Class.blocked, classify(a, 401, "{\"code\":\"EMPTY_ACCESS_TOKEN\",\"status\":401}").class);
    try std.testing.expectEqual(Class.blocked, classify(a, 403, "{\"message\":\"Accessing this video resource is forbidden.\",\"status\":403}").class);
    try std.testing.expectEqual(Class.blocked, classify(a, 426, "{\"status\":426,\"code\":\"NONEXISTENT_VERSION\"}").class);
    try std.testing.expectEqual(Class.blocked, classify(a, 400, "{\"status\":400,\"code\":\"VERSION_MISSING\"}").class);
    try std.testing.expectEqual(Class.blocked, classify(a, 400, "{\"code\":\"INVALID_URN_ID\"}").class);
    try std.testing.expectEqual(Class.stop_day, classify(a, 429, "").class);
    try std.testing.expectEqual(Class.new_init, classify(a, 400, "{\"code\":\"EXPIRED_UPLOAD_URL\"}").class);
    try std.testing.expectEqual(Class.failed, classify(a, 400, "{\"code\":\"FIELD_LENGTH_TOO_LONG\"}").class);
    try std.testing.expectEqual(Class.failed, classify(a, 400, "{\"message\":\"x\",\"serviceErrorCode\":10007,\"status\":400}").class);
    try std.testing.expectEqual(Class.failed, classify(a, 422, "{\"message\":\"field is required\"}").class);
    try std.testing.expect(std.mem.indexOf(u8, classify(a, 422, "{\"message\":\"Content is a DUPLICATE of a recent post\"}").msg, "duplicate post") != null);
    try std.testing.expectEqual(Class.retry, classify(a, 409, "{\"code\":\"CONFLICT\"}").class);
    try std.testing.expectEqual(Class.retry, classify(a, 503, "oops").class);
    try std.testing.expectEqual(Class.retry, classify(a, 500, "{\"code\":\"INTERNAL_SERVER_ERROR\"}").class);
    try std.testing.expectEqual(Class.failed, classify(a, 400, "not json").class);
    try std.testing.expectEqual(Class.failed, classify(a, 418, "{\"code\":\"BRAND_NEW\"}").class);
}
