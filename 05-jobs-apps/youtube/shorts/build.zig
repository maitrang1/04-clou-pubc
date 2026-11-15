// =====================================================================
// Des: Build script - makes the shorts exe and the test step, and compiles the one vendored C file (SQLite) with safe flags
// Flo: read version > options (mock flag, version) > root module + sqlite C source > exe + run step > test step
// Cre: 2026-11-15                          - | Mod: 2026-11-15
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: zig build [-Dtarget=..] [-Doptimize=..] [-Dmock=true] [test]
// Out: zig-out/bin/shorts · test run (offline, mocks only)
// Run: cd /home/mai_trang/04-clou-base/05-jobs-apps/youtube/shorts && zig build test --summary all
// Exe: /home/mai_trang/04-clou-base/05-jobs-apps/youtube/shorts/zig-out/bin/shorts
// =====================================================================
const std = @import("std");
const zon = @import("build.zig.zon");

const CF = .{ .sql_flags = &[_][]const u8{ "-std=c99", "-fno-sanitize=undefined", "-DSQLITE_THREADSAFE=1", "-DSQLITE_OMIT_LOAD_EXTENSION=1", "-DSQLITE_DQS=0", "-DSQLITE_DEFAULT_MEMSTATUS=0", "-DSQLITE_OMIT_DEPRECATED=1" } };

// one root module per consumer: options + sqlite attached
fn rootModule(b: *std.Build, target: std.Build.ResolvedTarget, opt: std.builtin.OptimizeMode, mock: bool) *std.Build.Module {
    const opts = b.addOptions();
    opts.addOption(bool, "mock", mock);
    opts.addOption([]const u8, "version", zon.version);
    const m = b.createModule(.{ .root_source_file = b.path("main.zig"), .target = target, .optimize = opt, .link_libc = true });
    m.addImport("build_options", opts.createModule());
    m.addIncludePath(b.path("sqlite"));
    m.addCSourceFiles(.{ .root = b.path("sqlite"), .files = &.{"sqlite3.c"}, .flags = CF.sql_flags });
    return m;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const opt = b.option(std.builtin.OptimizeMode, "optimize", "Debug | ReleaseSafe | ReleaseFast | ReleaseSmall") orelse .ReleaseSafe;
    const mock = b.option(bool, "mock", "allow loopback http for mocks (never in release)") orelse false;
    const exe = b.addExecutable(.{ .name = "shorts", .root_module = rootModule(b, target, opt, mock) });
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |a| run.addArgs(a);
    b.step("run", "Run shorts").dependOn(&run.step);
    const filters = b.option([]const []const u8, "test-filter", "only tests whose name contains this") orelse &.{};
    const tests = b.addTest(.{ .root_module = rootModule(b, target, .Debug, true), .filters = filters });
    b.step("test", "Run all tests (offline, mocks only)").dependOn(&b.addRunArtifact(tests).step);
}
// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
