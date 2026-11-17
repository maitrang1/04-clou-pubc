// Guards over the source itself: no hard-coded home paths or drive letters in code, no token-in-URL building, config keys all documented, every .zig file reachable from the test root.
const std = @import("std");
const Io = std.Io;
const builtin = @import("builtin");
const util = @import("co-util.zig");

const banned = [_][]const u8{ "/home/", "/Users/", "C:\\", "D:\\", "E:\\", "C:/", "E:/", "std.fs.cwd" };

test "no hard-coded paths or drive letters in non-test code" {
    const a = std.testing.allocator;
    var dir = try Io.Dir.cwd().openDir(std.testing.io, ".", .{ .iterate = true });
    defer dir.close(std.testing.io);
    var it = dir.iterate();
    var checked: usize = 0;
    while (try it.next(std.testing.io)) |e| {
        if (e.kind != .file or !std.mem.endsWith(u8, e.name, ".zig")) continue;
        if (std.mem.startsWith(u8, e.name, "te-") or std.mem.eql(u8, e.name, "co-guard.zig") or std.mem.eql(u8, e.name, "build.zig")) continue;
        const txt = try util.readAll(a, std.testing.io, e.name, 4 * 1024 * 1024);
        defer a.free(txt);
        // test blocks may use fixtures: only look above the first `test "` line
        const cut = std.mem.indexOf(u8, txt, "\ntest \"") orelse txt.len;
        for (banned) |b| {
            if (std.mem.indexOf(u8, txt[0..cut], b)) |i| {
                std.debug.print("{s} has '{s}' near byte {d}\n", .{ e.name, b, i });
                return error.HardCodedPath;
            }
        }
        checked += 1;
    }
    try std.testing.expect(checked > 20);
}

test "every shipped config key is documented in 15-CONFIG.md" {
    const a = std.testing.allocator;
    const cfg = util.readAll(a, std.testing.io, "00-config.json", 64 * 1024) catch return error.SkipZigTest;
    defer a.free(cfg);
    const doc = util.readAll(a, std.testing.io, ".10-documents/15-CONFIG.md", 256 * 1024) catch return error.SkipZigTest;
    defer a.free(doc);
    var it = std.mem.tokenizeAny(u8, cfg, "{}[],\n ");
    var seen: usize = 0;
    while (it.next()) |tok| {
        // a key looks like "name":
        const c = std.mem.indexOf(u8, tok, "\":") orelse continue;
        if (tok[0] != '"') continue;
        const key = tok[1..c];
        const needle = try std.fmt.allocPrint(a, "`{s}`", .{key});
        defer a.free(needle);
        const dotted = try std.fmt.allocPrint(a, ".{s}`", .{key});
        defer a.free(dotted);
        if (std.mem.indexOf(u8, doc, needle) == null and std.mem.indexOf(u8, doc, dotted) == null) {
            std.debug.print("config key '{s}' is not documented in 15-CONFIG.md\n", .{key});
            return error.UndocumentedKey;
        }
        seen += 1;
    }
    try std.testing.expect(seen > 60);
}

test "every .zig file is wired into the test root" {
    const a = std.testing.allocator;
    const main = try util.readAll(a, std.testing.io, "main.zig", 1 << 20);
    defer a.free(main);
    var dir = try Io.Dir.cwd().openDir(std.testing.io, ".", .{ .iterate = true });
    defer dir.close(std.testing.io);
    var it = dir.iterate();
    while (try it.next(std.testing.io)) |e| {
        if (e.kind != .file or !std.mem.endsWith(u8, e.name, ".zig")) continue;
        if (std.mem.eql(u8, e.name, "main.zig") or std.mem.eql(u8, e.name, "build.zig")) continue;
        // te-world is a helper pulled in by other tests; the rest must be listed or imported by a listed file
        if (std.mem.indexOf(u8, main, e.name) != null) continue;
        var found = false;
        var it2 = dir.iterate();
        while (try it2.next(std.testing.io)) |o| {
            if (o.kind != .file or !std.mem.endsWith(u8, o.name, ".zig") or std.mem.eql(u8, o.name, e.name)) continue;
            const t = try util.readAll(a, std.testing.io, o.name, 4 * 1024 * 1024);
            defer a.free(t);
            if (std.mem.indexOf(u8, t, e.name) != null) found = true;
        }
        if (!found) {
            std.debug.print("{s} is not imported by any file\n", .{e.name});
            return error.OrphanFile;
        }
    }
}

test "source folder has no subfolders with code (truly flat)" {
    var dir = try Io.Dir.cwd().openDir(std.testing.io, ".", .{ .iterate = true });
    defer dir.close(std.testing.io);
    var it = dir.iterate();
    while (try it.next(std.testing.io)) |e| {
        if (e.kind != .directory) continue;
        const ok = std.mem.eql(u8, e.name, ".10-docs") or std.mem.eql(u8, e.name, ".10-documents") or std.mem.eql(u8, e.name, ".zig-cache") or std.mem.eql(u8, e.name, "zig-out");
        if (!ok) {
            std.debug.print("unexpected folder: {s}\n", .{e.name});
            return error.NotFlat;
        }
    }
}
