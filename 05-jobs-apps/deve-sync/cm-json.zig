// =====================================================================
// Des: Tiny JSON helpers for settings files - parse an object, print it compact (to compare values) or indented (to write), keeping key order
// Flo: strip a BOM > parse into a Value tree > require an object > print with std.json
// Cre: 2026-11-15                          - | Mod: 2026-11-15
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: allocator, JSON text or Value
// Out: Value | compact text | indented text with a final newline
// Run: not run directly - imported by cm-plan.zig and cm-apply.zig
// Exe: n/a
// =====================================================================
const std = @import("std");

pub const JsonErro = error{ NotObject, BadJson, OutOfMemory };

fn stripBom(text: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, text, "\xEF\xBB\xBF")) text[3..] else text;
}

// any JSON value; the caller's arena owns it (leaky parse) ----
pub fn parseVal(a: std.mem.Allocator, text: []const u8) JsonErro!std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, a, stripBom(text), .{}) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.BadJson,
    };
}

// a settings file must be one JSON object ----
pub fn parseObj(a: std.mem.Allocator, text: []const u8) JsonErro!std.json.Value {
    const v = try parseVal(a, text);
    if (v != .object) return error.NotObject;
    return v;
}

pub fn emptyObj() std.json.Value {
    return .{ .object = .empty };
}

// compact text: two equal values print the same bytes (same key order) ----
pub fn canon(a: std.mem.Allocator, v: std.json.Value) JsonErro![]u8 {
    return std.json.Stringify.valueAlloc(a, v, .{}) catch return error.OutOfMemory;
}

// indented text for a file, with a final newline ----
pub fn render(a: std.mem.Allocator, v: std.json.Value) JsonErro![]u8 {
    const body = std.json.Stringify.valueAlloc(a, v, .{ .whitespace = .indent_2 }) catch return error.OutOfMemory;
    return std.mem.concat(a, u8, &.{ body, "\n" }) catch return error.OutOfMemory;
}

pub fn getKey(obj: std.json.Value, key: []const u8) ?std.json.Value {
    return if (obj == .object) obj.object.get(key) else null;
}

// replace the value in place (key keeps its place) or append a new key ----
pub fn putKey(a: std.mem.Allocator, obj: *std.json.Value, key: []const u8, val: std.json.Value) JsonErro!void {
    obj.object.put(a, key, val) catch return error.OutOfMemory;
}

test "parse, compact, indented; BOM stripped; non-object and bad text refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var o = try parseObj(a, "\xEF\xBB\xBF{\"b\": 1, \"a\": {\"x\": [1, 2]}}");
    try std.testing.expectEqualStrings("{\"b\":1,\"a\":{\"x\":[1,2]}}", try canon(a, o));
    try putKey(a, &o, "b", .{ .string = "new" });
    try putKey(a, &o, "c", .{ .bool = true });
    try std.testing.expectEqualStrings("{\"b\":\"new\",\"a\":{\"x\":[1,2]},\"c\":true}", try canon(a, o));
    const pretty = try render(a, o);
    try std.testing.expect(std.mem.endsWith(u8, pretty, "}\n"));
    try std.testing.expect(std.mem.indexOf(u8, pretty, "\n  \"b\": \"new\"") != null);
    try std.testing.expectEqualStrings("{\"b\":\"new\",\"a\":{\"x\":[1,2]},\"c\":true}", try canon(a, try parseObj(a, pretty)));
    try std.testing.expect(getKey(o, "zz") == null);
    try std.testing.expectEqualStrings("{}", try canon(a, emptyObj()));
    try std.testing.expectError(error.NotObject, parseObj(a, "[1]"));
    try std.testing.expectError(error.BadJson, parseObj(a, "{\"a\": }"));
    try std.testing.expectError(error.BadJson, parseObj(a, "// comment\n{}"));
}
// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
