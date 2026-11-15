// =====================================================================
// Des: Small safe file helpers - read a file that may not exist, write one atomically without following a link, list a folder's files, name a backup batch
// Flo: read with a size cap > write .part then rename over the target > walk files (no links) with skip patterns and a size cap
// Cre: 2026-11-15                          - | Mod: 2026-11-15
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: io, allocator, paths, data
// Out: bytes or null ; written file ; sorted relative file list ; stamp text
// Run: not run directly - imported by cm-plan.zig and cm-apply.zig
// Exe: n/a
// =====================================================================
const std = @import("std");
const builtin = @import("builtin");
const gm = @import("co-glob.zig");

const CF = .{ .part = ".part" };

pub const FsErro = error{ TooBig, ReadFail, WriteFail, LinkInTheWay, OutOfMemory };

// null when the file or its folder is missing; a file over the cap is an error, never a silent cut ----
pub fn readOpt(io: std.Io, a: std.mem.Allocator, path: []const u8, cap: usize) FsErro!?[]const u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(cap + 1)) catch |e| switch (e) {
        error.FileNotFound, error.NotDir => null,
        error.StreamTooLong => error.TooBig,
        error.OutOfMemory => error.OutOfMemory,
        else => error.ReadFail,
    };
}

fn openPart(io: std.Io, part: []const u8, mode: ?u32) !std.Io.File {
    const cwd = std.Io.Dir.cwd();
    if (comptime builtin.os.tag != .windows) {
        if (mode) |m| return cwd.createFile(io, part, .{ .permissions = .fromMode(@intCast(m)) });
    }
    return cwd.createFile(io, part, .{});
}

// write .part then rename over the target; a link or folder where the file should go stops the write ----
pub fn writeAtomic(io: std.Io, a: std.mem.Allocator, path: []const u8, data: []const u8, mode: ?u32) FsErro!void {
    const cwd = std.Io.Dir.cwd();
    if (cwd.statFile(io, path, .{ .follow_symlinks = false })) |st| {
        if (st.kind != .file) return error.LinkInTheWay;
    } else |_| {}
    if (std.fs.path.dirname(path)) |d| cwd.createDirPath(io, d) catch return error.WriteFail;
    const part = std.mem.concat(a, u8, &.{ path, CF.part }) catch return error.OutOfMemory;
    {
        const f = openPart(io, part, mode) catch return error.WriteFail;
        defer f.close(io);
        f.writePositionalAll(io, data, 0) catch return error.WriteFail;
    }
    cwd.rename(part, cwd, path, io) catch return error.WriteFail;
}

// modified time in whole seconds; 0 = unknown or missing ----
pub fn mtimeOf(io: std.Io, path: []const u8) i64 {
    const st = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch return 0;
    return if (st.kind == .file) st.mtime.toSeconds() else 0;
}

// the content keeps the time of the edit it came from; best effort, a failure only makes the file look newer ----
pub fn setMtime(io: std.Io, path: []const u8, secs: i64) void {
    if (secs <= 0) return;
    const ts = std.Io.Timestamp.fromNanoseconds(@as(i96, secs) * std.time.ns_per_s);
    std.Io.Dir.cwd().setTimestamps(io, path, .{ .follow_symlinks = false, .modify_timestamp = .{ .new = ts } }) catch {};
}

pub const Listed = struct { rels: []const []const u8, skipped: u32 };

fn lessStr(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.lessThan(u8, x, y);
}

// every regular file under a folder, as sorted `/` paths; links, `.part` leftovers, skip matches and files over the cap are left out ----
pub fn listFiles(io: std.Io, a: std.mem.Allocator, dir_path: []const u8, skip: []const []const u8, cap: usize) FsErro!Listed {
    var rels: std.ArrayList([]const u8) = .empty;
    var skipped: u32 = 0;
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound, error.NotDir => return .{ .rels = &.{}, .skipped = 0 },
        else => return error.ReadFail,
    };
    defer dir.close(io);
    var w = dir.walk(a) catch return error.OutOfMemory;
    defer w.deinit();
    while (w.next(io) catch return error.ReadFail) |ent| {
        if (ent.kind != .file) continue;
        const rel = try a.dupe(u8, ent.path);
        std.mem.replaceScalar(u8, rel, '\\', '/');
        if (std.mem.endsWith(u8, rel, CF.part) or gm.hitAny(skip, rel)) continue;
        const st = ent.dir.statFile(io, ent.basename, .{ .follow_symlinks = false }) catch {
            skipped += 1;
            continue;
        };
        if (st.size > cap) {
            skipped += 1;
            continue;
        }
        try rels.append(a, rel);
    }
    std.mem.sort([]const u8, rels.items, {}, lessStr);
    return .{ .rels = rels.items, .skipped = skipped };
}

// yyMMdd_HHmmss from epoch seconds: the folder name of one backup batch ----
pub fn stampOf(a: std.mem.Allocator, secs: i64) ![]const u8 {
    const es = std.time.epoch.EpochSeconds{ .secs = @intCast(@max(secs, 0)) };
    const ymd = es.getEpochDay().calculateYearDay();
    const md = ymd.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.allocPrint(a, "{d:0>2}{d:0>2}{d:0>2}_{d:0>2}{d:0>2}{d:0>2}", .{ @as(u32, ymd.year) % 100, md.month.numeric(), md.day_index + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute() });
}

fn put(dir: std.Io.Dir, io: std.Io, path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(path)) |d| try dir.createDirPath(io, d);
    try dir.writeFile(io, .{ .sub_path = path, .data = data });
}

test "readOpt: missing is null, over the cap is an error, exact cap is fine" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try a.dupe(u8, buf[0..try tmp.dir.realPath(io, &buf)]);
    try put(tmp.dir, io, "f.txt", "12345");
    const p = try std.fs.path.join(a, &.{ root, "f.txt" });
    try std.testing.expectEqualStrings("12345", (try readOpt(io, a, p, 5)).?);
    try std.testing.expectError(error.TooBig, readOpt(io, a, p, 4));
    try std.testing.expect((try readOpt(io, a, try std.fs.path.join(a, &.{ root, "none.txt" }), 5)) == null);
    try std.testing.expect((try readOpt(io, a, try std.fs.path.join(a, &.{ root, "f.txt", "x" }), 5)) == null);
}

test "writeAtomic creates folders, replaces in place, leaves no .part, refuses a link or folder in the way" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try a.dupe(u8, buf[0..try tmp.dir.realPath(io, &buf)]);
    const p = try std.fs.path.join(a, &.{ root, "x/y/z.txt" });
    try writeAtomic(io, a, p, "ONE", null);
    try writeAtomic(io, a, p, "TWO", 0o600);
    try std.testing.expectEqualStrings("TWO", (try readOpt(io, a, p, 10)).?);
    try std.testing.expect((try readOpt(io, a, try std.mem.concat(a, u8, &.{ p, ".part" }), 10)) == null);
    if (comptime builtin.os.tag != .windows) {
        const st = try std.Io.Dir.cwd().statFile(io, p, .{});
        try std.testing.expectEqual(@as(u32, 0o600), @as(u32, @intCast(st.permissions.toMode() & 0o777)));
    }
    try std.Io.Dir.cwd().createDirPath(io, try std.fs.path.join(a, &.{ root, "adir" }));
    try std.testing.expectError(error.LinkInTheWay, writeAtomic(io, a, try std.fs.path.join(a, &.{ root, "adir" }), "x", null));
    if (comptime builtin.os.tag != .windows) {
        const target = try std.fs.path.join(a, &.{ root, "real.txt" });
        try writeAtomic(io, a, target, "REAL", null);
        const link = try std.fs.path.join(a, &.{ root, "lnk.txt" });
        try std.Io.Dir.cwd().symLink(io, target, link, .{});
        try std.testing.expectError(error.LinkInTheWay, writeAtomic(io, a, link, "EVIL", null));
        try std.testing.expectEqualStrings("REAL", (try readOpt(io, a, target, 10)).?);
    }
}

test "listFiles: sorted, skips by pattern, big files, links and .part leftovers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try a.dupe(u8, buf[0..try tmp.dir.realPath(io, &buf)]);
    try put(tmp.dir, io, "d/b.txt", "B");
    try put(tmp.dir, io, "d/a.txt", "A");
    try put(tmp.dir, io, "d/sub/c.txt", "C");
    try put(tmp.dir, io, "d/synced/x.txt", "X");
    try put(tmp.dir, io, "d/half.txt.part", "P");
    try put(tmp.dir, io, "d/big.bin", "0123456789");
    if (comptime builtin.os.tag != .windows) try std.Io.Dir.cwd().symLink(io, "/etc/hostname", try std.fs.path.join(a, &.{ root, "d/lnk" }), .{});
    const got = try listFiles(io, a, try std.fs.path.join(a, &.{ root, "d" }), &.{"synced/*"}, 5);
    const want = [_][]const u8{ "a.txt", "b.txt", "sub/c.txt" };
    try std.testing.expectEqual(want.len, got.rels.len);
    for (want, got.rels) |w, g| try std.testing.expectEqualStrings(w, g);
    try std.testing.expectEqual(@as(u32, 1), got.skipped);
    const none = try listFiles(io, a, try std.fs.path.join(a, &.{ root, "nope" }), &.{}, 5);
    try std.testing.expectEqual(@as(usize, 0), none.rels.len);
}

test "the backup batch name is yyMMdd_HHmmss" {
    const a = std.testing.allocator;
    const s = try stampOf(a, 0);
    defer a.free(s);
    try std.testing.expectEqualStrings("700101_000000", s);
}
// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
