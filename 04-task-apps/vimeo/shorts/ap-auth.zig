// =====================================================================
// Des: Vimeo sign-in - reads the personal access token from the environment or a file in the secrets folder (there is no login flow and no refresh token on Vimeo) and never prints or logs it
// Flo: env variable first > else the token file (trimmed) > token or NoToken
// Cre: 2026-11-16                          - | Mod: 2026-11-16
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: Ctx (vimeo config, secrets folder, env)
// Out: the access token string (memory only) | Err.NoToken
// Run: not run directly - imported by ap-call, cm-token, cm-doctor
// =====================================================================
const std = @import("std");
const ctx_mod = @import("co-ctx.zig");
const util = @import("co-util.zig");

pub const Err = error{ NoToken, OutOfMemory };

// env first, then a file in the secrets folder; trimmed; null when neither has it
pub fn secret(cx: *const ctx_mod.Ctx, a: std.mem.Allocator, env_key: []const u8, file_name: []const u8) ?[]const u8 {
    if (env_key.len > 0) if (cx.envGet(env_key)) |v| return util.trimSecret(v);
    if (file_name.len == 0) return null;
    const p = cx.secretPath(a, file_name) catch return null;
    const t = util.readAll(a, cx.io, p, 16 * 1024) catch return null;
    const s = util.trimSecret(t);
    return if (s.len == 0) null else s;
}

// the personal access token
pub fn token(cx: *const ctx_mod.Ctx, a: std.mem.Allocator) Err![]const u8 {
    return secret(cx, a, cx.cfg.vimeo.token_env, cx.cfg.vimeo.token_file) orelse Err.NoToken;
}

test "secret: env wins over the file, trimmed, empty is none" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = std.process.Environ.Map.init(a);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    var cx = ctx_mod.testCtx(a, &env, dir);
    try std.testing.expect(secret(&cx, a, "VIME_TOKEN", "t.txt") == null);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "t.txt", .data = "  from-file\n" });
    try std.testing.expectEqualStrings("from-file", secret(&cx, a, "VIME_TOKEN", "t.txt").?);
    try env.put("VIME_TOKEN", "from-env");
    try std.testing.expectEqualStrings("from-env", secret(&cx, a, "VIME_TOKEN", "t.txt").?);
    try env.put("VIME_TOKEN", "");
    try std.testing.expectEqualStrings("from-file", secret(&cx, a, "VIME_TOKEN", "t.txt").?);
}

test "token: missing is NoToken, present comes back" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = std.process.Environ.Map.init(a);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    var cx = ctx_mod.testCtx(a, &env, dir);
    try std.testing.expectError(Err.NoToken, token(&cx, a));
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "vime-token.txt", .data = "TOK-1\n" });
    try std.testing.expectEqualStrings("TOK-1", try token(&cx, a));
}
// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
