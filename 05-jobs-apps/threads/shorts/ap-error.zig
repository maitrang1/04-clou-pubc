// Threads error reply -> class. The table is data (df-thre-errors.json), embedded at build time. Meta publishes no error-code table: rows from developer reports are marked and confirmed in the owner's real test.
// Two body shapes are read: {"error":{"code","error_subcode","message"}} and the flat {"error_type","code","error_message"}.
const std = @import("std");

pub const Class = enum { ok, blocked, failed, breaker, stop_day, retry, retry_publish };
pub const Info = struct { class: Class, code: i64 = 0, sub: i64 = 0, msg: []const u8 = "" };

const table_text = @embedFile("df-thre-errors.json");
const Row = struct { code: i64 = 0, sub: i64 = 0, name: []const u8 = "", status: u16 = 0, class: []const u8, why: []const u8 = "", on: bool = true };
const Table = struct { version: u32 = 0, note: []const u8 = "", codes: []const Row = &.{}, names: []const Row = &.{}, container_errors: []const Row = &.{}, http: []const Row = &.{} };

pub fn classOf(s: []const u8) Class {
    if (std.mem.eql(u8, s, "blocked")) return .blocked;
    if (std.mem.eql(u8, s, "failed")) return .failed;
    if (std.mem.eql(u8, s, "breaker")) return .breaker;
    if (std.mem.eql(u8, s, "stop_day")) return .stop_day;
    if (std.mem.eql(u8, s, "retry")) return .retry;
    if (std.mem.eql(u8, s, "retry_publish")) return .retry_publish;
    return .failed;
}

fn table(a: std.mem.Allocator) ?Table {
    return std.json.parseFromSliceLeaky(Table, a, table_text, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch null;
}

// code -> class; unknown code on a 4xx = failed (the body goes to the ledger note). `enable_race` switches on rows marked "on": false.
pub fn classify(a: std.mem.Allocator, http: u16, body: []const u8) Info {
    return classifyWith(a, http, body, false);
}

pub fn classifyWith(a: std.mem.Allocator, http: u16, body: []const u8, enable_race: bool) Info {
    const tbl = table(a) orelse return .{ .class = .failed, .msg = "error table unreadable" };
    var code: i64 = 0;
    var sub: i64 = 0;
    var msg: []const u8 = "";
    if (std.json.parseFromSliceLeaky(std.json.Value, a, body, .{})) |v| {
        if (v == .object) {
            if (v.object.get("error")) |e| if (e == .object) {
                if (e.object.get("code")) |c| code = intOf(c);
                if (e.object.get("error_subcode")) |c| sub = intOf(c);
                if (e.object.get("message")) |m| if (m == .string) {
                    msg = m.string;
                };
            };
            if (code == 0 and sub == 0) { // flat shape
                if (v.object.get("code")) |c| code = intOf(c);
                if (v.object.get("error_message")) |m| if (m == .string) {
                    msg = m.string;
                };
            }
        }
    } else |_| {}
    for (tbl.names) |r| if (std.mem.indexOf(u8, body, r.name) != null) return .{ .class = classOf(r.class), .code = code, .sub = sub, .msg = r.name };
    // most specific first: code + subcode, then subcode alone (code 0), then code alone
    for (tbl.codes) |r| {
        if (!r.on and !enable_race) continue;
        if (r.sub != 0 and r.sub == sub and (r.code == code or r.code == 0)) return .{ .class = classOf(r.class), .code = code, .sub = sub, .msg = msg };
    }
    for (tbl.codes) |r| {
        if (!r.on and !enable_race) continue;
        if (r.sub == 0 and r.code == code and code != 0) return .{ .class = classOf(r.class), .code = code, .sub = sub, .msg = msg };
    }
    for (tbl.http) |r| if (r.status == http) return .{ .class = classOf(r.class), .code = code, .sub = sub, .msg = msg };
    if (http >= 500) return .{ .class = .retry, .code = code, .sub = sub, .msg = msg };
    return .{ .class = .failed, .code = code, .sub = sub, .msg = msg };
}

// container error_message -> class + plain reason (unknown text = UNKNOWN row)
pub fn containerError(a: std.mem.Allocator, name: []const u8) struct { class: Class, why: []const u8 } {
    const tbl = table(a) orelse return .{ .class = .failed, .why = "error table unreadable" };
    for (tbl.container_errors) |r| if (std.mem.eql(u8, r.name, name)) return .{ .class = classOf(r.class), .why = r.why };
    for (tbl.container_errors) |r| if (std.mem.eql(u8, r.name, "UNKNOWN")) return .{ .class = classOf(r.class), .why = r.why };
    return .{ .class = .failed, .why = "unknown container error" };
}

fn intOf(v: std.json.Value) i64 {
    return switch (v) {
        .integer => |i| i,
        .float => |f| if (std.math.isNan(f)) 0 else @intFromFloat(std.math.clamp(f, -9e18, 9e18)),
        .string => |s| std.fmt.parseInt(i64, s, 10) catch 0,
        else => 0,
    };
}

test "codes map to classes (both body shapes)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqual(Class.blocked, classify(a, 400, "{\"error\":{\"code\":190,\"message\":\"x\"}}").class);
    try std.testing.expectEqual(Class.blocked, classify(a, 400, "{\"error\":{\"code\":452,\"error_subcode\":4279019}}").class);
    try std.testing.expectEqual(Class.blocked, classify(a, 403, "{\"error\":{\"code\":200}}").class);
    try std.testing.expectEqual(Class.blocked, classify(a, 400, "{\"error\":{\"code\":10}}").class);
    try std.testing.expectEqual(Class.blocked, classify(a, 400, "{\"error\":{\"code\":100,\"error_subcode\":33}}").class);
    try std.testing.expectEqual(Class.failed, classify(a, 400, "{\"error\":{\"code\":100}}").class);
    try std.testing.expectEqual(Class.breaker, classify(a, 400, "{\"error\":{\"code\":1,\"error_subcode\":4279013}}").class);
    try std.testing.expectEqual(Class.retry, classify(a, 400, "{\"error\":{\"code\":1,\"error_subcode\":2207052}}").class);
    try std.testing.expectEqual(Class.retry, classify(a, 400, "{\"error\":{\"code\":2,\"is_transient\":true}}").class);
    try std.testing.expectEqual(Class.stop_day, classify(a, 400, "{\"error\":{\"code\":613}}").class);
    try std.testing.expectEqual(Class.stop_day, classify(a, 429, "").class);
    try std.testing.expectEqual(Class.retry, classify(a, 503, "oops").class);
    try std.testing.expectEqual(Class.failed, classify(a, 400, "{\"weird\":1}").class);
    // flat OAuth-style shape: unknown code on a 400 is failed, 401 blocks by status
    try std.testing.expectEqual(Class.failed, classify(a, 400, "{\"error_type\":\"OAuthException\",\"code\":400,\"error_message\":\"Matching code was not found\"}").class);
    try std.testing.expectEqual(Class.blocked, classify(a, 401, "{\"error_type\":\"OAuthException\",\"code\":190,\"error_message\":\"bad\"}").class);
    // named error
    try std.testing.expectEqual(Class.failed, classify(a, 400, "{\"error\":{\"message\":\"THREADS_API__LINK_LIMIT_EXCEEDED\"}}").class);
}

test "the race row is off until switched on" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const body = "{\"error\":{\"code\":24,\"error_subcode\":4279009,\"message\":\"media cannot be found\"}}";
    try std.testing.expectEqual(Class.failed, classify(a, 400, body).class);
    try std.testing.expectEqual(Class.retry_publish, classifyWith(a, 400, body, true).class);
}

test "container errors: download is retried, the rest fail, unknown text = UNKNOWN" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqual(Class.retry, containerError(a, "FAILED_DOWNLOADING_VIDEO").class);
    try std.testing.expectEqual(Class.failed, containerError(a, "INVALID_DURATION").class);
    try std.testing.expectEqual(Class.failed, containerError(a, "SOMETHING_NEW").class);
    try std.testing.expect(std.mem.indexOf(u8, containerError(a, "SOMETHING_NEW").why, "no reason") != null);
}
