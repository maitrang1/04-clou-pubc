// =====================================================================
// Des: Free disk space of the data folder in MB - the one OS-specific helper (statvfs on Linux and macOS; unknown on Windows, said out loud)
// Flo: comptime pick the OS > call statvfs on the path > blocks free x block size
// Cre: 2026-11-15                          - | Mod: 2026-11-15
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: folder path
// Out: free MB or null when the OS cannot tell
// Run: not run directly - imported by cm-doctor and cm-publish
// =====================================================================
const std = @import("std");
const builtin = @import("builtin");

const c = if (builtin.os.tag == .windows) struct {} else @cImport(@cInclude("sys/statvfs.h"));

pub fn freeMb(path: []const u8) ?u64 {
    if (builtin.os.tag == .windows) return null;
    var buf: [1024]u8 = undefined;
    if (path.len >= buf.len) return null;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    var sv: c.struct_statvfs = undefined;
    if (c.statvfs(@ptrCast(&buf), &sv) != 0) return null;
    const bytes: u128 = @as(u128, sv.f_bavail) * @as(u128, sv.f_frsize);
    return @intCast(bytes / (1024 * 1024));
}

test "free space of the current folder is known on unix and plausible" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const mb = freeMb(".").?;
    try std.testing.expect(mb > 0);
    try std.testing.expect(freeMb("no/such/folder") == null);
}
// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
