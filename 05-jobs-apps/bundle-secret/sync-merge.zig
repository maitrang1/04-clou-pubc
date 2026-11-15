// =====================================================================
// Des: Merges two edits of the same code or text file into ONE version with git's own three-way merge, and refuses anything that is not clean, valid text
// Flo: file is on the merge list and has a base > write near, base, far to three fixed scratch files > git merge-file > exit 0 and valid output = merged text, else nothing
// Cre: 2026-11-15                          - | Mod: 2026-11-15
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: Git runner (folder = scratch folder), relative path, near, base, far bytes, merge globs
// Out: merged bytes or null (null = keep both copies, nobody wins)
// Run: not run directly - imported by sync-flow.zig
// Exe: n/a
// =====================================================================
const std = @import("std");
const apply = @import("bundle-apply.zig");
const git_run = @import("git-run.zig");
const gm = @import("glob-match.zig");

const CF = .{ .near = "near.txt", .base = "base.txt", .far = "far.txt", .mode = 0o600, .size_maxz = 4 * 1024 * 1024 };

pub fn mergeable(globs: []const []const u8, rel: []const u8) bool {
    return gm.hitAny(globs, rel);
}

fn hasMarker(text: []const u8) bool {
    return std.mem.startsWith(u8, text, "<<<<<<< ") or std.mem.indexOf(u8, text, "\n<<<<<<< ") != null or std.mem.indexOf(u8, text, "\n>>>>>>> ") != null;
}

// the scratch files are fixed names that are overwritten each time: nothing is ever removed ----
pub fn tryMerge(g: git_run.Git, rel: []const u8, near: []const u8, base: []const u8, far: []const u8) ?[]const u8 {
    if (near.len > CF.size_maxz or base.len > CF.size_maxz or far.len > CF.size_maxz) return null;
    for ([_][]const u8{ near, base, far }) |t| if (std.mem.indexOfScalar(u8, t, 0) != null or !std.unicode.utf8ValidateSlice(t)) return null;
    const names = [_][]const u8{ CF.near, CF.base, CF.far };
    const datas = [_][]const u8{ near, base, far };
    var paths: [3][]const u8 = undefined;
    for (names, datas, 0..) |n, d, i| {
        paths[i] = std.fs.path.join(g.a, &.{ g.root, n }) catch return null;
        apply.writeOwner(g.io, paths[i], d, CF.mode, g.a) catch return null;
    }
    const r = g.run(&.{ "merge-file", "-p", CF.near, CF.base, CF.far }) catch return null;
    if (r.code != 0) return null;
    const out = r.out;
    if (out.len > CF.size_maxz or !std.unicode.utf8ValidateSlice(out)) return null;
    if (hasMarker(out) and !hasMarker(near) and !hasMarker(far)) return null;
    if (std.mem.endsWith(u8, rel, ".json")) {
        _ = std.json.parseFromSliceLeaky(std.json.Value, g.a, out, .{}) catch return null;
    }
    return out;
}

test "merge: non-overlapping edits merge into one version; overlapping, binary, bad json and no-merge cases give null" {
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
    try env.put("GIT_CONFIG_NOSYSTEM", "1");
    const g: git_run.Git = .{ .io = io, .a = a, .env = &env, .root = root };
    _ = g.run(&.{"--version"}) catch |e| if (e == error.Missing) return error.SkipZigTest else return e;
    const base = "a\nb\nc\nd\ne\n";
    const got = tryMerge(g, "x.zig", "A\nb\nc\nd\ne\n", base, "a\nb\nc\nd\nE\n") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("A\nb\nc\nd\nE\n", got);
    try std.testing.expect(tryMerge(g, "x.zig", "a\nX\nc\nd\ne\n", base, "a\nY\nc\nd\ne\n") == null);
    try std.testing.expect(tryMerge(g, "x.bin", "a\x00b", base, "c") == null);
    try std.testing.expect(tryMerge(g, "x.txt", "\xff\xfe", base, "c") == null);
    const jb = "{\"a\":1,\n\"b\":2,\n\"c\":3}";
    try std.testing.expect(tryMerge(g, "x.json", "{\"a\":9,\n\"b\":2,\n\"c\":3}", jb, "{\"a\":1,\n\"b\":2,\n\"c\":8}") != null);
    try std.testing.expect(tryMerge(g, "x.json", "{\"a\":9,\n\"b\":2,\n\"c\":3}", jb, "{\"a\":1,\n\"b\":2,\n\"c\":3,") == null);
    try std.testing.expect(mergeable(&.{ "*.zig", "*.md" }, "app/main.zig"));
    try std.testing.expect(!mergeable(&.{ "*.zig", "*.md" }, "app/key.enc"));
    try std.testing.expect(!mergeable(&.{}, "app/main.zig"));
}
// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
