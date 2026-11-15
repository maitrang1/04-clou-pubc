// =====================================================================
// Des: The run log - one redacted line per event appended to log/run.log in the data folder; tokens and query strings never reach the file
// Flo: format line > redact secrets > add time > append
// Cre: 2026-11-15                          - | Mod: 2026-11-15
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: Ctx, level, message
// Out: appended log line (errors are swallowed: logging never stops a run)
// Run: not run directly - imported by publish, resolve, approve, login
// =====================================================================
const std = @import("std");
const ctx_mod = @import("co-ctx.zig");
const util = @import("co-util.zig");
const guard = @import("co-guard.zig");

pub fn line(cx: *const ctx_mod.Ctx, level: []const u8, comptime fmt: []const u8, args: anytype) void {
    var arena = std.heap.ArenaAllocator.init(cx.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const msg = std.fmt.allocPrint(a, fmt, args) catch return;
    const red = guard.redactText(a, msg) catch return;
    var tb: [32]u8 = undefined;
    const full = std.fmt.allocPrint(a, "{s} {s} {s}", .{ util.fmtTs(&tb, cx.nowMs(), cx.cfg.tz_offset_hours), level, red }) catch return;
    const dir = cx.dataPath(a, "log") catch return;
    util.mkdirp(cx.io, dir) catch return;
    const p = cx.dataPath(a, "log/run.log") catch return;
    util.appendLine(cx.io, p, full) catch {};
}

test "log line is written, timed and redacted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    var env = std.process.Environ.Map.init(a);
    var cx = ctx_mod.testCtx(a, &env, dir);
    cx.fake_now_ms = 1_700_000_000_000;
    line(&cx, "INFO", "sent {s} Authorization: Bearer TOPSECRET url=https://x.com/a?token=abc", .{"v1"});
    const t = try util.readAll(a, cx.io, try cx.dataPath(a, "log/run.log"), 4096);
    try std.testing.expect(std.mem.indexOf(u8, t, "INFO sent v1") != null);
    try std.testing.expect(std.mem.indexOf(u8, t, "TOPSECRET") == null);
    try std.testing.expect(std.mem.indexOf(u8, t, "abc") == null);
    try std.testing.expect(std.mem.startsWith(u8, t, "2023-11-"));
}
// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
