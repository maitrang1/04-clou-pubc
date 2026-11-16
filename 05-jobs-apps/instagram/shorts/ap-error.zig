// Graph error reply -> class. The table is data (df-inst-errors.json), embedded at build time. `definite` = a documented 4xx answer that proves nothing was published.
const std = @import("std");

pub const Class = enum { ok, blocked, failed, breaker, stop_day, retry, retry_once, notready, wait, expired };
pub const Info = struct { class: Class, code: i64 = 0, sub: i64 = 0, msg: []const u8 = "", definite: bool = false };

const table_text = @embedFile("df-inst-errors.json");
const Row = struct { code: i64 = 0, sub: i64 = 0, name: []const u8 = "", status: u16 = 0, class: []const u8, maybe: bool = false, definite: bool = false, why: []const u8 = "" };
const Table = struct { version: u32 = 0, note: []const u8 = "", codes: []const Row = &.{}, upload_errors: []const Row = &.{}, http: []const Row = &.{} };

fn classOf(s: []const u8) Class {
    inline for (@typeInfo(Class).@"enum".fields) |f| if (std.mem.eql(u8, s, f.name)) return @enumFromInt(f.value);
    return .failed;
}

// (code, sub) -> class. A row with a sub matches only that pair; a row without matches the code. Unknown on a 4xx = failed, not definite.
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
    const is4 = http >= 400 and http < 500;
    for (tbl.upload_errors) |r| if (std.mem.indexOf(u8, body, "debug_info") != null and std.mem.indexOf(u8, body, r.name) != null) return .{ .class = classOf(r.class), .code = code, .sub = sub, .msg = r.name };
    if (code != 0) {
        for (tbl.codes) |r| if (r.code == code and r.sub != 0 and r.sub == sub) return .{ .class = classOf(r.class), .code = code, .sub = sub, .msg = if (msg.len > 0) msg else r.why, .definite = is4 and !r.maybe };
        for (tbl.codes) |r| if (r.code == code and r.sub == 0) return .{ .class = classOf(r.class), .code = code, .sub = sub, .msg = if (msg.len > 0) msg else r.why, .definite = is4 and r.definite };
    }
    for (tbl.http) |r| if (r.status == http) return .{ .class = classOf(r.class), .code = code, .sub = sub, .msg = msg, .definite = is4 and r.definite };
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

fn errJson(a: std.mem.Allocator, code: i64, sub: i64) []const u8 {
    return std.fmt.allocPrint(a, "{{\"error\":{{\"code\":{d},\"error_subcode\":{d},\"message\":\"m\"}}}}", .{ code, sub }) catch "";
}

test "official rows map by (code, subcode)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const nr = classify(a, 400, errJson(a, 9007, 2207027));
    try std.testing.expectEqual(Class.notready, nr.class);
    try std.testing.expect(nr.definite);
    try std.testing.expectEqual(Class.failed, classify(a, 400, errJson(a, 352, 2207026)).class);
    try std.testing.expectEqual(Class.expired, classify(a, 400, errJson(a, -2, 2207020)).class);
    try std.testing.expectEqual(Class.wait, classify(a, 400, errJson(a, 24, 2207008)).class);
    try std.testing.expectEqual(Class.breaker, classify(a, 400, errJson(a, 4, 2207051)).class);
    try std.testing.expectEqual(Class.breaker, classify(a, 400, errJson(a, 25, 2207050)).class);
    try std.testing.expectEqual(Class.stop_day, classify(a, 400, errJson(a, 9, 2207042)).class);
    try std.testing.expectEqual(Class.failed, classify(a, 400, errJson(a, 36004, 2207010)).class);
}

test "code 4 without the spam subcode is the app limit; rate codes stop the day" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqual(Class.stop_day, classify(a, 400, errJson(a, 4, 0)).class);
    try std.testing.expectEqual(Class.stop_day, classify(a, 400, errJson(a, 613, 1996)).class);
    try std.testing.expectEqual(Class.stop_day, classify(a, 400, errJson(a, 80002, 0)).class);
    try std.testing.expectEqual(Class.stop_day, classify(a, 429, "").class);
    try std.testing.expectEqual(Class.blocked, classify(a, 400, errJson(a, 190, 0)).class);
    // code-only rows are definite only when the table says so: 190/100 yes, an unknown subcode under 24 no
    try std.testing.expect(classify(a, 400, errJson(a, 190, 0)).definite);
    try std.testing.expect(classify(a, 400, errJson(a, 100, 0)).definite);
    try std.testing.expect(!classify(a, 401, "").definite);
    try std.testing.expect(!classify(a, 400, errJson(a, 24, 999)).definite);
}

test "the maybe rows are never definite: -1 server errors, 5xx, unknown codes, upload retry" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const e1 = classify(a, 400, errJson(a, -1, 2207001));
    try std.testing.expectEqual(Class.retry, e1.class);
    try std.testing.expect(!e1.definite);
    try std.testing.expect(!classify(a, 400, errJson(a, -1, 2207032)).definite);
    try std.testing.expect(!classify(a, 503, "oops").definite);
    try std.testing.expectEqual(Class.retry, classify(a, 503, "oops").class);
    const unk = classify(a, 400, errJson(a, 77777, 123));
    try std.testing.expectEqual(Class.failed, unk.class);
    try std.testing.expect(!unk.definite); // unknown code: never proof of "not published"
    try std.testing.expectEqual(Class.failed, classify(a, 400, "{\"weird\":1}").class);
    try std.testing.expectEqual(Class.retry_once, classify(a, 200, "{\"debug_info\":{\"retriable\":false,\"type\":\"ProcessingFailedError\"}}").class);
    try std.testing.expectEqual(Class.failed, classify(a, 400, "{\"data\":[{\"caption\":\"ProcessingFailedError\"}]}").class); // a caption is not an upload error
}
