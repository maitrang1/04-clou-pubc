// =====================================================================
// Des: The base store - what this device and the vault last agreed on for every file (a copy of each file plus a list of hashes), so a sync can tell which side changed; it only grows (`forget` is for a moved path only)
// Flo: load manifest (missing = nothing agreed yet) > read a base copy only when its hash still matches > set = write copy + remember hash > save manifest .part then rename
// Cre: 2026-11-15                          - | Mod: 2026-11-15
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: io, allocator, base folder, relative path, file bytes
// Out: Base (in memory) | bytes or null | BaseErro
// Run: not run directly - imported by sync-flow.zig
// Exe: n/a
// =====================================================================
const std = @import("std");
const apply = @import("bundle-apply.zig");
const arc = @import("bundle-archive.zig");

const CF = .{ .manifest = "manifest.txt", .files = "files", .file_maxz = 4 * 1024 * 1024, .mode = 0o600, .hex_len = 64 };

pub const BaseErro = error{ BadFormat, Unsafe, WriteFail, OutOfMemory };

pub const Base = struct {
    dir: []const u8,
    files: std.StringHashMapUnmanaged([]const u8) = .empty,
    dirty: bool = false,
};

pub fn hexOf(data: []const u8) [CF.hex_len]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

fn hexOk(h: []const u8) bool {
    if (h.len != CF.hex_len) return false;
    for (h) |c| if (!std.ascii.isHex(c) or std.ascii.isUpper(c)) return false;
    return true;
}

// lines: `F<TAB>sha<TAB>rel`; an old `C` line (the retired conflict list) is read and dropped ----
pub fn load(io: std.Io, a: std.mem.Allocator, dir: []const u8) BaseErro!Base {
    var b: Base = .{ .dir = dir };
    const path = std.fs.path.join(a, &.{ dir, CF.manifest }) catch return error.OutOfMemory;
    const raw = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(CF.file_maxz)) catch |e| return if (e == error.FileNotFound) b else error.BadFormat;
    var it = std.mem.splitScalar(u8, raw, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        var f = std.mem.splitScalar(u8, line, '\t');
        const tag = f.next() orelse return error.BadFormat;
        if (std.mem.eql(u8, tag, "F")) {
            const sha = f.next() orelse return error.BadFormat;
            const rel = f.rest();
            if (!hexOk(sha) or !arc.safePath(rel)) return error.BadFormat;
            b.files.put(a, a.dupe(u8, rel) catch return error.OutOfMemory, a.dupe(u8, sha) catch return error.OutOfMemory) catch return error.OutOfMemory;
        } else if (std.mem.eql(u8, tag, "C")) {
            continue;
        } else return error.BadFormat;
    }
    return b;
}

fn copyPath(a: std.mem.Allocator, b: *const Base, rel: []const u8) ![]u8 {
    return std.fs.path.join(a, &.{ b.dir, CF.files, rel });
}

// the agreed copy, or null when there is none or it no longer matches its hash (a damaged base is "no base", never a guess) ----
pub fn content(b: *const Base, io: std.Io, a: std.mem.Allocator, rel: []const u8) ?[]const u8 {
    const want = b.files.get(rel) orelse return null;
    if (!arc.safePath(rel)) return null;
    const path = copyPath(a, b, rel) catch return null;
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(CF.file_maxz)) catch return null;
    const got = hexOf(data);
    return if (std.mem.eql(u8, &got, want)) data else null;
}

// remember this content as agreed: write the copy, then the hash in memory ----
pub fn set(b: *Base, io: std.Io, a: std.mem.Allocator, rel: []const u8, data: []const u8) BaseErro!void {
    if (!arc.safePath(rel)) return error.Unsafe;
    const sha = hexOf(data);
    // already agreed and the copy is intact: nothing to do; a damaged or missing copy is written again (self-heal) ----
    if (b.files.get(rel)) |old| if (std.mem.eql(u8, old, &sha) and content(b, io, a, rel) != null) return;
    const path = copyPath(a, b, rel) catch return error.OutOfMemory;
    apply.writeOwner(io, path, data, CF.mode, a) catch return error.WriteFail;
    b.files.put(a, a.dupe(u8, rel) catch return error.OutOfMemory, a.dupe(u8, &sha) catch return error.OutOfMemory) catch return error.OutOfMemory;
    b.dirty = true;
}

// a moved path is no longer agreed: its hash goes, the copy file stays harmlessly ----
pub fn forget(b: *Base, rel: []const u8) void {
    if (b.files.remove(rel)) b.dirty = true;
}

fn lessStr(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.lessThan(u8, x, y);
}

pub fn save(b: *Base, io: std.Io, a: std.mem.Allocator) BaseErro!void {
    if (!b.dirty) return;
    var keys: std.ArrayList([]const u8) = .empty;
    var it = b.files.keyIterator();
    while (it.next()) |k| keys.append(a, k.*) catch return error.OutOfMemory;
    std.mem.sort([]const u8, keys.items, {}, lessStr);
    var text: std.ArrayList(u8) = .empty;
    for (keys.items) |k| text.print(a, "F\t{s}\t{s}\n", .{ b.files.get(k).?, k }) catch return error.OutOfMemory;
    const path = std.fs.path.join(a, &.{ b.dir, CF.manifest }) catch return error.OutOfMemory;
    apply.writeOwner(io, path, text.items, CF.mode, a) catch return error.WriteFail;
    b.dirty = false;
}

test "base: nothing agreed at first; set, save, load round trip; a damaged copy counts as no base; the manifest only grows" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try a.dupe(u8, buf[0..try tmp.dir.realPath(io, &buf)]);
    const dir = try std.fs.path.join(a, &.{ root, "base" });
    var b = try load(io, a, dir);
    try std.testing.expect(content(&b, io, a, "x/y.txt") == null);
    try set(&b, io, a, "x/y.txt", "ONE");
    try set(&b, io, a, ".d/z.md", "TWO");
    try save(&b, io, a);
    var c = try load(io, a, dir);
    try std.testing.expectEqualStrings("ONE", content(&c, io, a, "x/y.txt").?);
    try std.testing.expectEqualStrings("TWO", content(&c, io, a, ".d/z.md").?);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ dir, "files", "x/y.txt" }), .data = "TAMPERED" });
    try std.testing.expect(content(&c, io, a, "x/y.txt") == null);
    try set(&c, io, a, "x/y.txt", "ONE");
    try std.testing.expectEqualStrings("ONE", content(&c, io, a, "x/y.txt").?);
    try std.testing.expectError(error.Unsafe, set(&c, io, a, "../evil", "x"));
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ dir, "manifest.txt" }), .data = "F\tnothex\tx\n" });
    try std.testing.expectError(error.BadFormat, load(io, a, dir));
    // an old conflict line from an earlier version is ignored
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ dir, "manifest.txt" }), .data = "C\t00\t00\tx\n" });
    _ = try load(io, a, dir);
}
// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
