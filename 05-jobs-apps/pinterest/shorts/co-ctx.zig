// App context: io, allocators, config, paths, secrets. One place for every path and secret lookup.
const std = @import("std");
const cfg_mod = @import("co-cfg.zig");
const util = @import("co-util.zig");
const guard = @import("co-guard.zig");

pub const Ctx = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator, // process-lifetime (config strings)
    env: *std.process.Environ.Map,
    cfg: cfg_mod.Config,
    home: []const u8,
    cfg_dir: []const u8 = ".", // relative config paths resolve against the config file's folder
    mock: bool = false, // build option: loopback http allowed
    resolver: guard.Resolver = .{},
    live: bool = false, // --live given
    json: bool = false, // --json given
    fake_now_ms: i64 = 0, // tests only: fixed clock, 0 = real
    fake_sleep: bool = false, // tests only: no real waiting
    crash_at: u8 = 0, // tests only: simulate a process death in publish (1 after register, 2 after upload, 3 after create)

    pub fn nowMs(self: *const Ctx) i64 {
        return if (self.fake_now_ms != 0) self.fake_now_ms else util.nowMs(self.io);
    }
    pub fn sleepMs(self: *const Ctx, ms: i64) void {
        if (!self.fake_sleep) util.sleepMs(self.io, ms);
    }
    // "~/x" = under home · absolute = as is · else relative to the config folder. Caller frees.
    pub fn path(self: *const Ctx, a: std.mem.Allocator, p: []const u8) ![]u8 {
        if (std.mem.startsWith(u8, p, "~/") or std.mem.startsWith(u8, p, "~\\")) return std.fmt.allocPrint(a, "{s}/{s}", .{ self.home, p[2..] });
        if (p.len > 0 and (p[0] == '/' or (p.len > 2 and p[1] == ':'))) return a.dupe(u8, p);
        return std.fmt.allocPrint(a, "{s}/{s}", .{ self.cfg_dir, p });
    }
    pub fn dataPath(self: *const Ctx, a: std.mem.Allocator, sub: []const u8) ![]u8 {
        const d = try self.path(a, self.cfg.data_dir);
        defer a.free(d);
        return std.fmt.allocPrint(a, "{s}/{s}", .{ d, sub });
    }
    pub fn envGet(self: *const Ctx, key: []const u8) ?[]const u8 {
        if (key.len == 0) return null;
        const v = self.env.get(key) orelse return null;
        return if (v.len == 0) null else v;
    }
    // secret by env name first, then file in secrets_dir. Value is trimmed, arena-owned, never logged.
    pub fn secret(self: *const Ctx, env_name: []const u8, file_name: []const u8) ?[]const u8 {
        if (self.envGet(env_name)) |v| return self.arena.dupe(u8, std.mem.trim(u8, v, " \t\r\n")) catch null;
        if (file_name.len == 0) return null;
        const dir = self.path(self.arena, self.cfg.secrets_dir) catch return null;
        const p = std.fmt.allocPrint(self.arena, "{s}/{s}", .{ dir, file_name }) catch return null;
        const txt = util.readAll(self.arena, self.io, p, 16 * 1024) catch return null;
        const t = std.mem.trim(u8, txt, " \t\r\n");
        return if (t.len == 0) null else t;
    }
    pub fn clientId(self: *const Ctx) ?[]const u8 {
        return self.secret(self.cfg.api.app_id_env, self.cfg.api.app_id_file);
    }
    pub fn clientSecret(self: *const Ctx) ?[]const u8 {
        return self.secret(self.cfg.api.app_secret_env, self.cfg.api.app_secret_file);
    }
    // board for this run: the secret one unless post.public. null = not configured.
    pub fn boardId(self: *const Ctx) ?[]const u8 {
        if (self.cfg.post.public) return self.secret(self.cfg.account.board_public_env, self.cfg.account.board_public_file);
        return self.secret(self.cfg.account.board_secret_env, self.cfg.account.board_secret_file);
    }
    pub fn sectionId(self: *const Ctx) ?[]const u8 {
        return self.secret(self.cfg.account.section_env, self.cfg.account.section_file);
    }
    // full path of a file in secrets_dir. Caller frees.
    pub fn secretPath(self: *const Ctx, a: std.mem.Allocator, name: []const u8) ![]u8 {
        const dir = try self.path(a, self.cfg.secrets_dir);
        defer a.free(dir);
        return std.fmt.allocPrint(a, "{s}/{s}", .{ dir, name });
    }
};

pub fn resolveHome(arena: std.mem.Allocator, env: *std.process.Environ.Map) ![]const u8 {
    if (env.get("PINT_SHOR_HOME")) |h| if (h.len > 0) return arena.dupe(u8, h);
    if (env.get("HOME")) |h| if (h.len > 0) return arena.dupe(u8, h);
    if (env.get("USERPROFILE")) |h| if (h.len > 0) return arena.dupe(u8, h);
    return error.NoHome;
}

// test helper: Ctx on a temp home with the default config
pub fn testCtx(arena: std.mem.Allocator, env: *std.process.Environ.Map, home: []const u8) Ctx {
    util.quiet = true;
    return .{ .io = std.testing.io, .gpa = std.testing.allocator, .arena = arena, .env = env, .cfg = .{}, .home = home, .mock = true, .fake_sleep = true };
}

test "path expansion and secrets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("T_TOK", " abc \n");
    var cx = testCtx(arena.allocator(), &env, "/h");
    cx.cfg_dir = "/cfg";
    try std.testing.expectEqualStrings("/h/x", try cx.path(arena.allocator(), "~/x"));
    try std.testing.expectEqualStrings("/abs/y", try cx.path(arena.allocator(), "/abs/y"));
    try std.testing.expectEqualStrings("/cfg/rel", try cx.path(arena.allocator(), "rel"));
    try std.testing.expectEqualStrings("abc", cx.secret("T_TOK", "").?);
    try std.testing.expect(cx.secret("NOPE_ENV", "") == null);
}
