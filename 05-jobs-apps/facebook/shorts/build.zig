// Build: one exe + one test step. -Dmock=true allows loopback http (tests/e2e only; never in release). SQLite amalgamation is compiled in (written exception in .10-docs/10-RULE.md).
const std = @import("std");
const zon = @import("build.zig.zon");

fn rootModule(b: *std.Build, target: std.Build.ResolvedTarget, opt: std.builtin.OptimizeMode, mock: bool) *std.Build.Module {
    const opts = b.addOptions();
    opts.addOption(bool, "mock", mock);
    opts.addOption([]const u8, "version", zon.version);
    const m = b.createModule(.{ .root_source_file = b.path("main.zig"), .target = target, .optimize = opt, .link_libc = true });
    m.addImport("build_options", opts.createModule());
    m.addIncludePath(b.path("."));
    m.addCSourceFile(.{ .file = b.path("sqlite3.c"), .flags = &.{ "-DSQLITE_OMIT_LOAD_EXTENSION=1", "-DSQLITE_DQS=0", "-DSQLITE_THREADSAFE=1", "-DSQLITE_DEFAULT_MEMSTATUS=0" } });
    return m;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const opt = b.option(std.builtin.OptimizeMode, "optimize", "Debug | ReleaseSafe | ReleaseFast | ReleaseSmall") orelse .ReleaseSafe;
    const mock = b.option(bool, "mock", "allow loopback http for mocks (never in release)") orelse false;
    const exe = b.addExecutable(.{ .name = "facebook-shorts", .root_module = rootModule(b, target, opt, mock) });
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |a| run.addArgs(a);
    b.step("run", "Run facebook-shorts").dependOn(&run.step);
    const filters = b.option([]const []const u8, "test-filter", "only tests whose name contains this") orelse &.{};
    const tests = b.addTest(.{ .root_module = rootModule(b, target, .Debug, true), .filters = filters });
    b.step("test", "Run all tests (offline, mocks only)").dependOn(&b.addRunArtifact(tests).step);
}
