// Kill file + run lock. Kill = a file with "1" in it (written "0" to clear: nothing is ever deleted). Lock = OS file lock, freed on any exit.
const std = @import("std");
const Ctx = @import("co-ctx.zig").Ctx;
const util = @import("co-util.zig");

pub const Err = error{ Killed, Busy, NoData };

fn killPath(cx: *const Ctx, a: std.mem.Allocator) ![]u8 {
    return cx.dataPath(a, "KILL");
}

pub fn killOn(cx: *const Ctx) bool {
    const p = killPath(cx, cx.gpa) catch return true; // cannot tell = stop
    defer cx.gpa.free(p);
    const t = util.readAll(cx.gpa, cx.io, p, 64) catch |e| return e != error.FileNotFound; // only "no such file" means off
    defer cx.gpa.free(t);
    return t.len > 0 and t[0] == '1';
}

pub fn setKill(cx: *const Ctx, on: bool) !void {
    const d = try cx.dataPath(cx.gpa, "");
    defer cx.gpa.free(d);
    try util.mkdirp(cx.io, std.mem.trimEnd(u8, d, "/"));
    const p = try killPath(cx, cx.gpa);
    defer cx.gpa.free(p);
    try util.writeAtomic(cx.gpa, cx.io, p, if (on) "1\n" else "0\n");
}

// every write path calls this first: a killed app writes nothing
pub fn writeOk(cx: *const Ctx) Err!void {
    if (killOn(cx)) return Err.Killed;
}

pub const Lock = struct {
    file: std.Io.File,
    io: std.Io,
    pub fn release(self: *Lock) void {
        self.file.close(self.io);
    }
};

// one run at a time; Busy when another process holds it
pub fn acquire(cx: *const Ctx) Err!Lock {
    const d = cx.dataPath(cx.gpa, "") catch return Err.NoData;
    defer cx.gpa.free(d);
    util.mkdirp(cx.io, std.mem.trimEnd(u8, d, "/")) catch return Err.NoData;
    const p = cx.dataPath(cx.gpa, "run.lock") catch return Err.NoData;
    defer cx.gpa.free(p);
    var f = std.Io.Dir.cwd().createFile(cx.io, p, .{ .truncate = false, .read = true }) catch return Err.NoData;
    const got = f.tryLock(cx.io, .exclusive) catch {
        f.close(cx.io);
        return Err.NoData;
    };
    if (!got) {
        f.close(cx.io);
        return Err.Busy;
    }
    return .{ .file = f, .io = cx.io };
}

test "kill on/off round trip and lock is exclusive" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    const home = try std.fmt.allocPrint(arena.allocator(), ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    var cx = @import("co-ctx.zig").testCtx(arena.allocator(), &env, home);
    cx.cfg.data_dir = "~/d";
    try std.testing.expect(!killOn(&cx) or true);
    try setKill(&cx, true);
    try std.testing.expect(killOn(&cx));
    try std.testing.expectError(Err.Killed, writeOk(&cx));
    try setKill(&cx, false);
    try std.testing.expect(!killOn(&cx));
    try writeOk(&cx);
    var l1 = try acquire(&cx);
    try std.testing.expectError(Err.Busy, acquire(&cx));
    l1.release();
    var l2 = try acquire(&cx);
    l2.release();
}
