// Run log: one JSON line per event, appended to <data_dir>/run.jsonl. Text is redacted first, so a token can never land here.
const std = @import("std");
const Ctx = @import("co-ctx.zig").Ctx;
const util = @import("co-util.zig");
const guard = @import("co-guard.zig");

pub fn log(cx: *const Ctx, lvl: []const u8, comptime fmt: []const u8, args: anytype) void {
    const a = cx.gpa;
    const raw = std.fmt.allocPrint(a, fmt, args) catch return;
    defer a.free(raw);
    const red = guard.redactText(a, raw) catch return;
    defer a.free(red);
    const line = util.jsonStr(a, .{ .t = cx.nowMs(), .lvl = lvl, .msg = red }) catch return;
    defer a.free(line);
    const d = cx.dataPath(a, "") catch return;
    defer a.free(d);
    util.mkdirp(cx.io, std.mem.trimEnd(u8, d, "/")) catch return;
    const p = cx.dataPath(a, "run.jsonl") catch return;
    defer a.free(p);
    util.appendLine(cx.io, p, line) catch {};
}

test "log redacts tokens" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    const home = try std.fmt.allocPrint(arena.allocator(), ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    var cx = @import("co-ctx.zig").testCtx(arena.allocator(), &env, home);
    log(&cx, "info", "call ?access_token=SECRET123&x=1 done", .{});
    const p = try cx.dataPath(arena.allocator(), "run.jsonl");
    const txt = try util.readAll(arena.allocator(), cx.io, p, 4096);
    try std.testing.expect(std.mem.indexOf(u8, txt, "SECRET123") == null);
    try std.testing.expect(std.mem.indexOf(u8, txt, "access_token=***") != null);
}
