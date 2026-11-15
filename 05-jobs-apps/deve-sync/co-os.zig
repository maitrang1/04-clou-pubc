// =====================================================================
// Des: The one thin place that knows which operating system this is, and reads the home and app-data folders from the environment
// Flo: pick the OS tag at compile time > read the right variable > hand back a plain value or null
// Cre: 2026-11-15                          - | Mod: 2026-11-15
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: environment map
// Out: Os tag ; home path or null ; app-data path or null ; any variable or null
// Run: not run directly - imported by main.zig and co-config.zig
// Exe: n/a
// =====================================================================
const std = @import("std");
const builtin = @import("builtin");

pub const Os = enum { linux, macos, windows };

pub fn cur() Os {
    return switch (builtin.os.tag) {
        .windows => .windows,
        .macos => .macos,
        else => .linux,
    };
}

// a variable that is set and not empty ----
pub fn envGet(env: *const std.process.Environ.Map, key: []const u8) ?[]const u8 {
    const v = env.get(key) orelse return null;
    return if (v.len == 0) null else v;
}

pub fn homePath(env: *const std.process.Environ.Map) ?[]const u8 {
    return envGet(env, if (comptime builtin.os.tag == .windows) "USERPROFILE" else "HOME");
}

pub fn appdataPath(env: *const std.process.Environ.Map) ?[]const u8 {
    return envGet(env, "APPDATA");
}

test "home comes from the right variable; an empty value is no value" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try std.testing.expect(homePath(&env) == null);
    try env.put(if (builtin.os.tag == .windows) "USERPROFILE" else "HOME", "");
    try std.testing.expect(homePath(&env) == null);
    try env.put(if (builtin.os.tag == .windows) "USERPROFILE" else "HOME", "/h/me");
    try std.testing.expectEqualStrings("/h/me", homePath(&env).?);
    try std.testing.expect(appdataPath(&env) == null);
    try env.put("APPDATA", "/h/me/ad");
    try std.testing.expectEqualStrings("/h/me/ad", appdataPath(&env).?);
}
// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
