// =====================================================================
// Des: Merges two edits of the same code or text file into ONE version with git's own three-way merge, and refuses anything that is not clean, valid text
// Flo: file is on the merge list and has a base > write near, base, far to three fixed scratch files > git merge-file > exit 0 and valid output = merged text, else nothing
// Cre: 2026-11-15                          - | Mod: 2026-11-15
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: Git runner (folder = scratch folder), relative path, near, base, far bytes, merge globs
// Out: merged bytes or null (null = no clean merge: the newest edit wins)
// Run: not run directly - imported by cm-apply.zig
// Exe: n/a
// =====================================================================
const std = @import("std");
const fio = @import("co-fsio.zig");
const gm = @import("co-glob.zig");

const CF = .{ .near = "near.txt", .base = "base.txt", .far = "far.txt", .mode = 0o600, .size_maxz = 4 * 1024 * 1024, .tmos_secs = 60 };

pub const Run = struct { io: std.Io, a: std.mem.Allocator, env: *const std.process.Environ.Map, bin: []const u8, dir: []const u8 };

pub fn mergeable(globs: []const []const u8, rel: []const u8) bool {
    return gm.hitAny(globs, rel);
}

fn hasMarker(text: []const u8) bool {
    return std.mem.startsWith(u8, text, "<<<<<<< ") or std.mem.indexOf(u8, text, "\n<<<<<<< ") != null or std.mem.indexOf(u8, text, "\n>>>>>>> ") != null;
}

// the scratch files are fixed names that are overwritten each time: nothing is ever removed ----
pub fn tryMerge(r: Run, rel: []const u8, near: []const u8, base: []const u8, far: []const u8) ?[]const u8 {
    if (near.len > CF.size_maxz or base.len > CF.size_maxz or far.len > CF.size_maxz) return null;
    for ([_][]const u8{ near, base, far }) |t| if (std.mem.indexOfScalar(u8, t, 0) != null or !std.unicode.utf8ValidateSlice(t)) return null;
    const names = [_][]const u8{ CF.near, CF.base, CF.far };
    const datas = [_][]const u8{ near, base, far };
    var paths: [3][]const u8 = undefined;
    for (names, datas, 0..) |n, d, i| {
        paths[i] = std.fs.path.join(r.a, &.{ r.dir, n }) catch return null;
        fio.writeAtomic(r.io, r.a, paths[i], d, CF.mode) catch return null;
    }
    const got = std.process.run(r.a, r.io, .{
        .argv = &.{ r.bin, "-C", r.dir, "merge-file", "-p", CF.near, CF.base, CF.far },
        .environ_map = r.env,
        .stdout_limit = .limited(CF.size_maxz + 1024),
        .stderr_limit = .limited(64 * 1024),
        .timeout = .{ .duration = .{ .raw = .fromNanoseconds(@as(i96, CF.tmos_secs) * std.time.ns_per_s), .clock = .awake } },
    }) catch return null;
    switch (got.term) {
        .exited => |c| if (c != 0) return null,
        else => return null,
    }
    const out = got.stdout;
    if (out.len > CF.size_maxz or !std.unicode.utf8ValidateSlice(out)) return null;
    if (hasMarker(out) and !hasMarker(near) and !hasMarker(far)) return null;
    if (std.mem.endsWith(u8, rel, ".json")) {
        _ = std.json.parseFromSliceLeaky(std.json.Value, r.a, out, .{}) catch return null;
    }
    return out;
}

test "merge: non-overlapping edits merge into one version; overlapping, binary and bad json give null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try a.dupe(u8, buf[0..try tmp.dir.realPath(io, &buf)]);
    var env = std.process.Environ.Map.init(a);
    if (std.c.getenv("PATH")) |p| try env.put("PATH", std.mem.span(p));
    try env.put("HOME", root);
    const r: Run = .{ .io = io, .a = a, .env = &env, .bin = "git", .dir = root };
    const probe = std.process.run(a, io, .{ .argv = &.{ "git", "--version" }, .environ_map = &env }) catch return error.SkipZigTest;
    _ = probe;
    const base = "a\nb\nc\nd\ne\n";
    const got = tryMerge(r, "x.zig", "A\nb\nc\nd\ne\n", base, "a\nb\nc\nd\nE\n") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("A\nb\nc\nd\nE\n", got);
    try std.testing.expect(tryMerge(r, "x.zig", "a\nX\nc\nd\ne\n", base, "a\nY\nc\nd\ne\n") == null);
    try std.testing.expect(tryMerge(r, "x.bin", "a\x00b", base, "c") == null);
    try std.testing.expect(tryMerge(r, "x.json", "{\"a\":9,\n\"b\":2}", "{\"a\":1,\n\"b\":2}", "{\"a\":1,\n\"b\":") == null);
    try std.testing.expect(mergeable(&.{ "*.zig", "*.md" }, "app/main.zig"));
    try std.testing.expect(!mergeable(&.{}, "app/main.zig"));
}
// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
