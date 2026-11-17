// Graph error reply -> class. The table is data (df-face-errors.json), embedded at build time.
const std = @import("std");

pub const Class = enum { ok, blocked, failed, breaker, stop_day, retry, resume_up, retry_once };
pub const Info = struct { class: Class, code: i64 = 0, sub: i64 = 0, msg: []const u8 = "" };

const table_text = @embedFile("df-face-errors.json");
const Row = struct { code: i64 = 0, name: []const u8 = "", status: u16 = 0, class: []const u8, why: []const u8 = "" };
const Table = struct { version: u32 = 0, note: []const u8 = "", codes: []const Row = &.{}, upload_errors: []const Row = &.{}, http: []const Row = &.{} };

fn classOf(s: []const u8) Class {
    if (std.mem.eql(u8, s, "blocked")) return .blocked;
    if (std.mem.eql(u8, s, "failed")) return .failed;
    if (std.mem.eql(u8, s, "breaker")) return .breaker;
    if (std.mem.eql(u8, s, "stop_day")) return .stop_day;
    if (std.mem.eql(u8, s, "retry")) return .retry;
    if (std.mem.eql(u8, s, "resume")) return .resume_up;
    if (std.mem.eql(u8, s, "retry_once")) return .retry_once;
    return .failed;
}

// code -> class; unknown code on a 4xx = failed (the body goes to the ledger note)
pub fn classify(a: std.mem.Allocator, http: u16, body: []const u8) Info {
    const tbl = std.json.parseFromSliceLeaky(Table, a, table_text, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return .{ .class = .failed, .msg = "error table unreadable" };
    var code: i64 = 0;
    var sub: i64 = 0;
    var msg: []const u8 = "";
    if (std.json.parseFromSliceLeaky(std.json.Value, a, body, .{})) |v| {
        if (v == .object) if (v.object.get("error")) |e| if (e == .object) {
            if (e.object.get("code")) |c| code = intOf(c);
            if (e.object.get("error_subcode")) |c| sub = intOf(c);
            if (e.object.get("message")) |m| if (m == .string) {
                msg = m.string;
            };
        };
    } else |_| {}
    for (tbl.upload_errors) |r| if (std.mem.indexOf(u8, body, r.name) != null) return .{ .class = classOf(r.class), .code = code, .sub = sub, .msg = r.name };
    for (tbl.codes) |r| if (r.code == code and code != 0) return .{ .class = classOf(r.class), .code = code, .sub = sub, .msg = msg };
    for (tbl.http) |r| if (r.status == http) return .{ .class = classOf(r.class), .code = code, .sub = sub, .msg = msg };
    if (http >= 500) return .{ .class = .retry, .code = code, .sub = sub, .msg = msg };
    return .{ .class = .failed, .code = code, .sub = sub, .msg = msg };
}

fn intOf(v: std.json.Value) i64 {
    return switch (v) {
        .integer => |i| i,
        .float => |f| if (std.math.isNan(f)) 0 else @intFromFloat(std.math.clamp(f, -9e18, 9e18)),
        .string => |s| std.fmt.parseInt(i64, s, 10) catch 0,
        else => 0,
    };
}

test "codes map to classes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqual(Class.blocked, classify(a, 400, "{\"error\":{\"code\":190,\"message\":\"x\"}}").class);
    try std.testing.expectEqual(Class.blocked, classify(a, 403, "{\"error\":{\"code\":200}}").class);
    try std.testing.expectEqual(Class.failed, classify(a, 400, "{\"error\":{\"code\":100}}").class);
    try std.testing.expectEqual(Class.failed, classify(a, 400, "{\"error\":{\"code\":6000}}").class);
    try std.testing.expectEqual(Class.breaker, classify(a, 400, "{\"error\":{\"code\":368}}").class);
    try std.testing.expectEqual(Class.stop_day, classify(a, 400, "{\"error\":{\"code\":613,\"error_subcode\":1996}}").class);
    try std.testing.expectEqual(@as(i64, 1996), classify(a, 400, "{\"error\":{\"code\":613,\"error_subcode\":1996}}").sub);
    try std.testing.expectEqual(Class.stop_day, classify(a, 400, "{\"error\":{\"code\":80001}}").class);
    try std.testing.expectEqual(Class.stop_day, classify(a, 429, "").class);
    try std.testing.expectEqual(Class.retry, classify(a, 503, "oops").class);
    try std.testing.expectEqual(Class.failed, classify(a, 400, "{\"weird\":1}").class);
    try std.testing.expectEqual(Class.resume_up, classify(a, 400, "{\"debug_info\":{\"type\":\"OffsetInvalidError\"}}").class);
    try std.testing.expectEqual(Class.retry_once, classify(a, 200, "ProcessingFailedError").class);
}
