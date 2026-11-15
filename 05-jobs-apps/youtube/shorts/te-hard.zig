// =====================================================================
// Des: The hard-code guard - fails the build when shipped code (not comments, not tests) contains a home path, a drive letter or a Google address outside the config defaults, and checks the app folder stays truly flat
// Flo: list the app folder > read each .zig file up to its first test > scan code lines for forbidden text > check no source subfolders except sqlite/
// Cre: 2026-11-15                          - | Mod: 2026-11-15
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: the app folder (tests run in it)
// Out: pass or fail with the file and line
// Run: cd /home/mai_trang/04-clou-base/05-jobs-apps/youtube/shorts && zig build test --summary all
// =====================================================================
const std = @import("std");

// built from pieces so this file does not match its own scan
const bad_paths = [_][]const u8{ "/ho" ++ "me/", "/Us" ++ "ers/", "C:" ++ "\\\\", "D:" ++ "\\\\", "E:" ++ "\\\\" };
const bad_hosts = [_][]const u8{ "googleapis" ++ ".com", "accounts.goo" ++ "gle.com" };

fn isCodeLine(l: []const u8) bool {
    const t = std.mem.trimStart(u8, l, " \t");
    return t.len > 0 and !std.mem.startsWith(u8, t, "//");
}

test "no home paths, drive letters or Google addresses in shipped code" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var dir = try std.Io.Dir.cwd().openDir(io, ".", .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    var checked: usize = 0;
    while (try it.next(io)) |e| {
        if (e.kind != .file or !std.mem.endsWith(u8, e.name, ".zig")) continue;
        if (std.mem.eql(u8, e.name, "te-hard.zig") or std.mem.eql(u8, e.name, "build.zig")) continue;
        const text = try dir.readFileAlloc(io, e.name, gpa, .limited(2 * 1024 * 1024));
        defer gpa.free(text);
        checked += 1;
        const is_cfg = std.mem.eql(u8, e.name, "co-cfg.zig");
        var ln: usize = 0;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |l| {
            ln += 1;
            if (std.mem.startsWith(u8, l, "test ") or std.mem.indexOf(u8, l, "---- tests") != null or std.mem.indexOf(u8, l, "---- test ") != null) break;
            if (!isCodeLine(l)) continue;
            for (bad_paths) |p| if (std.mem.indexOf(u8, l, p) != null) {
                std.debug.print("hard-coded path in {s}:{d}: {s}\n", .{ e.name, ln, l });
                return error.TestUnexpectedResult;
            };
            if (!is_cfg) for (bad_hosts) |h| if (std.mem.indexOf(u8, l, h) != null) {
                std.debug.print("hard-coded address in {s}:{d}: {s}\n", .{ e.name, ln, l });
                return error.TestUnexpectedResult;
            };
        }
    }
    try std.testing.expect(checked >= 30);
}

test "the app folder is truly flat: only sqlite/ and the two doc folders are subfolders" {
    const io = std.testing.io;
    var dir = try std.Io.Dir.cwd().openDir(io, ".", .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |e| {
        if (e.kind != .directory) continue;
        const ok = std.mem.eql(u8, e.name, "sqlite") or std.mem.eql(u8, e.name, ".10-docs") or std.mem.eql(u8, e.name, ".10-documents") or std.mem.eql(u8, e.name, "zig-out") or std.mem.eql(u8, e.name, ".zig-cache");
        if (!ok) {
            std.debug.print("unexpected subfolder: {s}\n", .{e.name});
            return error.TestUnexpectedResult;
        }
    }
}
// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
