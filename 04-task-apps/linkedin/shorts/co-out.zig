// Output: plain lines for people, one JSON object for --json. Results go to stdout, problems to stderr.
const std = @import("std");
const Ctx = @import("co-ctx.zig").Ctx;
const util = @import("co-util.zig");

pub fn say(cx: *const Ctx, comptime fmt: []const u8, args: anytype) void {
    if (cx.json) return;
    util.print(cx.io, fmt ++ "\n", args);
}
pub fn warn(cx: *const Ctx, comptime fmt: []const u8, args: anytype) void {
    if (cx.json) return;
    util.eprint(cx.io, fmt ++ "\n", args);
}
// the --json result: one object on stdout
pub fn json(cx: *const Ctx, a: std.mem.Allocator, v: anytype) void {
    if (!cx.json) return;
    const s = util.jsonStr(a, v) catch return;
    util.printAll(cx.io, s);
    util.printAll(cx.io, "\n");
}
