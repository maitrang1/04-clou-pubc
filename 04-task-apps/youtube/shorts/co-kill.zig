// =====================================================================
// Des: The kill file - while a file with the configured name exists in the data folder, every write is refused
// Flo: check file exists > on/off commands create or move it
// Cre: 2026-11-15                          - | Mod: 2026-11-15
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: Ctx
// Out: bool (is killed) | file created/removed state
// Run: not run directly - imported by publish, resolve
// =====================================================================
const std = @import("std");
const ctx_mod = @import("co-ctx.zig");
const util = @import("co-util.zig");

pub fn isOn(cx: *const ctx_mod.Ctx, a: std.mem.Allocator) bool {
    const p = cx.dataPath(a, cx.cfg.kill_file) catch return true; // cannot tell = stay safe
    return util.exists(cx.io, p);
}

pub fn set(cx: *const ctx_mod.Ctx, a: std.mem.Allocator, on: bool) !void {
    const p = try cx.dataPath(a, cx.cfg.kill_file);
    if (on) {
        try util.mkdirp(cx.io, cx.data_dir);
        try util.writeAtomic(a, cx.io, p, "stop\n");
    } else if (util.exists(cx.io, p)) {
        // never delete: the file moves to the trash folder through the owner's guard tool (see HOW-TO); a plain rename here keeps it
        var nb: [64]u8 = undefined;
        const n = try std.fmt.bufPrint(&nb, ".off-{d}", .{cx.nowMs()});
        const to = try std.fmt.allocPrint(a, "{s}{s}", .{ p, n });
        const cwd = std.Io.Dir.cwd();
        try cwd.rename(p, cwd, to, cx.io);
    }
}

test "kill file on, off, and an unreadable path means killed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    var env = std.process.Environ.Map.init(a);
    const cx = ctx_mod.testCtx(a, &env, dir);
    try std.testing.expect(!isOn(&cx, a));
    try set(&cx, a, true);
    try std.testing.expect(isOn(&cx, a));
    try set(&cx, a, false);
    try std.testing.expect(!isOn(&cx, a));
    try set(&cx, a, false); // off again is a no-op
}
// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
