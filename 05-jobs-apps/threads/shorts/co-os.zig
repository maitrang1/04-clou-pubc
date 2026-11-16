// The ONE thin OS file: free disk space, owner-only file writes. Everything else in the app is portable std.
const std = @import("std");
const builtin = @import("builtin");

const has_statvfs = builtin.os.tag != .windows and !builtin.abi.isMusl(); // musl: translate-c makes statvfs opaque, free space is then "unknown"
const posix_c = if (!has_statvfs) struct {} else @cImport(@cInclude("sys/statvfs.h"));
extern "kernel32" fn GetDiskFreeSpaceExA(dir: ?[*:0]const u8, avail: *u64, total: *u64, free: *u64) callconv(.winapi) c_int;

// free MB on the volume holding `path` (must exist); null = unknown on this OS
pub fn diskFreeMb(alloc: std.mem.Allocator, path: []const u8) ?u64 {
    const z = alloc.dupeZ(u8, path) catch return null;
    defer alloc.free(z);
    if (builtin.os.tag == .windows) {
        var a: u64 = 0;
        var t: u64 = 0;
        var f: u64 = 0;
        if (GetDiskFreeSpaceExA(z.ptr, &a, &t, &f) == 0) return null;
        return a / (1024 * 1024);
    }
    if (!has_statvfs) return null;
    var s: posix_c.struct_statvfs = undefined;
    if (posix_c.statvfs(z.ptr, &s) != 0) return null;
    return (@as(u64, s.f_bavail) * @as(u64, s.f_frsize)) / (1024 * 1024);
}

// Write a secret file atomically: p.part (owner-only mode where the OS has modes) then rename. Never leaves half a file.
pub fn writeSecretAtomic(alloc: std.mem.Allocator, io: std.Io, path: []const u8, data: []const u8) !void {
    const tmp = try std.fmt.allocPrint(alloc, "{s}.part", .{path});
    defer alloc.free(tmp);
    const cwd = std.Io.Dir.cwd();
    var f = if (comptime builtin.os.tag != .windows)
        try cwd.createFile(io, tmp, .{ .truncate = true, .permissions = .fromMode(0o600) })
    else
        try cwd.createFile(io, tmp, .{ .truncate = true });
    errdefer f.close(io);
    try f.writePositionalAll(io, data, 0);
    f.close(io);
    try cwd.rename(tmp, cwd, path, io);
}

test "disk free is readable here (or honestly unknown on musl)" {
    const v = diskFreeMb(std.testing.allocator, ".");
    if (!has_statvfs and builtin.os.tag != .windows) return try std.testing.expect(v == null);
    try std.testing.expect(v != null and v.? > 0);
}

test "secret file is written whole, owner-only on posix" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = std.testing.allocator;
    const p = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/s.txt", .{&tmp.sub_path});
    defer a.free(p);
    try writeSecretAtomic(a, std.testing.io, p, "v1");
    try writeSecretAtomic(a, std.testing.io, p, "v2-longer");
    const got = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, p, a, .limited(100));
    defer a.free(got);
    try std.testing.expectEqualStrings("v2-longer", got);
    if (builtin.os.tag != .windows) {
        const st = try std.Io.Dir.cwd().statFile(std.testing.io, p, .{});
        try std.testing.expectEqual(@as(u32, 0o600), @as(u32, @intCast(st.permissions.toMode() & 0o777)));
    }
}
