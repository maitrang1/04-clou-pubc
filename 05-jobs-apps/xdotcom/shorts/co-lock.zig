// =====================================================================
// Des: The run lock - one run at a time, held through an exclusive file lock the OS frees by itself if the program crashes
// Flo: open lock file > try exclusive non-blocking lock > hold until release
// Cre: 2026-11-15                          - | Mod: 2026-11-15
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: Ctx
// Out: Lock handle | error.Busy when another run holds it
// Run: not run directly - imported by publish, approve, resolve
// =====================================================================
const std = @import("std");
const ctx_mod = @import("co-ctx.zig");
const util = @import("co-util.zig");

pub const Lock = struct {
    io: std.Io,
    f: std.Io.File,
    pub fn release(self: Lock) void {
        self.f.close(self.io);
    }
};

// Busy = another run holds the lock; NoDir = the data folder or lock file cannot be used (permissions, full disk)
pub const Err = error{ Busy, NoDir };

pub fn take(cx: *const ctx_mod.Ctx, a: std.mem.Allocator) Err!Lock {
    util.mkdirPrivate(cx.io, cx.data_dir) catch return Err.NoDir;
    const p = cx.dataPath(a, "run.lock") catch return Err.NoDir;
    const f = std.Io.Dir.cwd().createFile(cx.io, p, .{ .truncate = false, .lock = .exclusive, .lock_nonblocking = true }) catch |e| return if (e == error.WouldBlock) Err.Busy else Err.NoDir;
    return .{ .io = cx.io, .f = f };
}

test "second run is refused while the first holds the lock" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    var env = std.process.Environ.Map.init(a);
    const cx = ctx_mod.testCtx(a, &env, dir);
    const l1 = try take(&cx, a);
    try std.testing.expectError(Err.Busy, take(&cx, a));
    l1.release();
    const l2 = try take(&cx, a);
    l2.release();
}
// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
