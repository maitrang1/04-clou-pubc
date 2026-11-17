// The ONE thin OS file: free disk space. Everything else in the app is portable std.
const std = @import("std");
const builtin = @import("builtin");

const posix_c = if (builtin.os.tag == .windows) struct {} else @cImport(@cInclude("sys/statvfs.h"));
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
    var s: posix_c.struct_statvfs = undefined;
    if (posix_c.statvfs(z.ptr, &s) != 0) return null;
    return (@as(u64, s.f_bavail) * @as(u64, s.f_frsize)) / (1024 * 1024);
}

test "disk free is readable here" {
    const v = diskFreeMb(std.testing.allocator, ".");
    try std.testing.expect(v != null and v.? > 0);
}
