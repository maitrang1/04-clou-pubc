// Tiny tolerant JSON reads: Meta's docs print odd JSON and mix spellings, so every field is optional.
const std = @import("std");

pub fn parse(a: std.mem.Allocator, body: []const u8) ?std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, a, body, .{}) catch null;
}
fn clampF(f: f64) i64 {
    if (std.math.isNan(f)) return 0;
    return @intFromFloat(std.math.clamp(f, -9e18, 9e18));
}
pub fn obj(v: ?std.json.Value, key: []const u8) ?std.json.Value {
    const x = v orelse return null;
    if (x != .object) return null;
    return x.object.get(key);
}
pub fn str(v: ?std.json.Value, key: []const u8) []const u8 {
    const x = obj(v, key) orelse return "";
    return if (x == .string) x.string else "";
}
// number or numeric string -> i64
pub fn int(v: ?std.json.Value, key: []const u8) i64 {
    const x = obj(v, key) orelse return 0;
    return switch (x) {
        .integer => |i| i,
        .float => |f| clampF(f),
        .string => |s| std.fmt.parseInt(i64, s, 10) catch 0,
        else => 0,
    };
}
pub fn boolean(v: ?std.json.Value, key: []const u8) bool {
    const x = obj(v, key) orelse return false;
    return x == .bool and x.bool;
}

test "hostile numbers do not panic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = parse(arena.allocator(), "{\"a\":1e300,\"b\":-1e300,\"c\":\"99999999999999999999\",\"d\":12}");
    try std.testing.expect(int(v, "a") > 0);
    try std.testing.expect(int(v, "b") < 0);
    try std.testing.expectEqual(@as(i64, 0), int(v, "c"));
    try std.testing.expectEqual(@as(i64, 12), int(v, "d"));
}
