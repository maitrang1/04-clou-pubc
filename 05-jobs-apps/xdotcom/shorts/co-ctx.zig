// =====================================================================
// Des: The app context - io, allocators, config, env, folders (data, secrets, config) and the clock, in one place so tests can swap the clock and skip waiting
// Flo: main loads config > resolve data and secrets folders > Ctx handed to every command
// Cre: 2026-11-16                          - | Mod: 2026-11-15
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: io, config, env map, config folder
// Out: Ctx with path helpers (dataPath, secretPath, rel) and env lookup
// Run: not run directly - imported by every command
// =====================================================================
const std = @import("std");
const cfg_mod = @import("co-cfg.zig");
const util = @import("co-util.zig");
const guard = @import("co-guard.zig");

pub const Ctx = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator, // process-lifetime (config strings, paths)
    env: *std.process.Environ.Map,
    cfg: cfg_mod.Config,
    cfg_dir: []const u8 = ".",
    data_dir: []const u8 = ".",
    secrets_dir: []const u8 = ".",
    mock: bool = false, // build option: loopback http allowed
    resolver: guard.Resolver = .{},
    fake_now_ms: i64 = 0, // tests: fixed clock (0 = real)
    no_wait: bool = false, // tests: sleeps return at once

    pub fn nowMs(self: *const Ctx) i64 {
        return if (self.fake_now_ms != 0) self.fake_now_ms else util.nowMs(self.io);
    }
    pub fn sleepMs(self: *const Ctx, ms: i64) void {
        if (self.no_wait) return;
        util.sleepMs(self.io, ms);
    }
    pub fn envGet(self: *const Ctx, key: []const u8) ?[]const u8 {
        const v = self.env.get(key) orelse return null;
        return if (v.len == 0) null else v;
    }
    // relative paths from the config resolve against the config file's folder
    pub fn rel(self: *const Ctx, a: std.mem.Allocator, p: []const u8) ![]u8 {
        return joinRel(a, self.cfg_dir, p);
    }
    pub fn dataPath(self: *const Ctx, a: std.mem.Allocator, name: []const u8) ![]u8 {
        return std.fmt.allocPrint(a, "{s}/{s}", .{ self.data_dir, name });
    }
    pub fn secretPath(self: *const Ctx, a: std.mem.Allocator, name: []const u8) ![]u8 {
        return std.fmt.allocPrint(a, "{s}/{s}", .{ self.secrets_dir, name });
    }
};

// absolute (unix or drive) paths stay; others join the base
pub fn joinRel(a: std.mem.Allocator, base: []const u8, p: []const u8) ![]u8 {
    if (p.len > 0 and (p[0] == '/' or (p.len > 2 and p[1] == ':'))) return a.dupe(u8, p);
    return std.fmt.allocPrint(a, "{s}/{s}", .{ base, p });
}

fn homeOf(env: *std.process.Environ.Map) ?[]const u8 {
    if (env.get("HOME")) |h| if (h.len > 0) return h;
    if (env.get("USERPROFILE")) |h| if (h.len > 0) return h;
    return null;
}

pub const home_env = "XDOT_HOME";
const data_leaf = ".xdot-shorts";
const secr_leaf = ".04-clou-secr";

// data folder: config > XDOT_HOME > ~/.xdot-shorts
pub fn resolveData(arena: std.mem.Allocator, env: *std.process.Environ.Map, cfg_dir: []const u8, v: []const u8) ![]const u8 {
    if (v.len > 0) return joinRel(arena, cfg_dir, v);
    if (env.get(home_env)) |h| if (h.len > 0) return arena.dupe(u8, h);
    const h = homeOf(env) orelse return error.NoHome;
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ h, data_leaf });
}

// secrets folder: config > ~/.04-clou-secr
pub fn resolveSecrets(arena: std.mem.Allocator, env: *std.process.Environ.Map, cfg_dir: []const u8, v: []const u8) ![]const u8 {
    if (v.len > 0) return joinRel(arena, cfg_dir, v);
    const h = homeOf(env) orelse return error.NoHome;
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ h, secr_leaf });
}

// test helper: Ctx on a temp folder with default config, fixed clock, no waiting
pub fn testCtx(arena: std.mem.Allocator, env: *std.process.Environ.Map, dir: []const u8) Ctx {
    util.quiet = true;
    return .{ .io = std.testing.io, .gpa = std.testing.allocator, .arena = arena, .env = env, .cfg = .{}, .cfg_dir = dir, .data_dir = dir, .secrets_dir = dir, .mock = true, .no_wait = true };
}

test "folders resolve: config wins, then env, then home" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = std.process.Environ.Map.init(a);
    try env.put("HOME", "/h");
    try std.testing.expectEqualStrings("/h/.xdot-shorts", try resolveData(a, &env, "/cfg", ""));
    try std.testing.expectEqualStrings("/h/.04-clou-secr", try resolveSecrets(a, &env, "/cfg", ""));
    try env.put("XDOT_HOME", "/data");
    try std.testing.expectEqualStrings("/data", try resolveData(a, &env, "/cfg", ""));
    try std.testing.expectEqualStrings("/cfg/rel", try resolveData(a, &env, "/cfg", "rel"));
    try std.testing.expectEqualStrings("/abs", try resolveData(a, &env, "/cfg", "/abs"));
    var empty = std.process.Environ.Map.init(a);
    try std.testing.expectError(error.NoHome, resolveData(a, &empty, "/cfg", ""));
}
// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
