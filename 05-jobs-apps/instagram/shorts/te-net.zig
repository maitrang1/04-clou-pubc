// Tests for co-net + ap-call against the fake: stream upload, errors, timeouts, token never in a URL.
const std = @import("std");
const fk = @import("te-fake-graph.zig");
const ctxm = @import("co-ctx.zig");
const call = @import("ap-call.zig");

fn mk(arena: std.mem.Allocator, env: *std.process.Environ.Map, f: *fk.Fake) !ctxm.Ctx {
    var cx = ctxm.testCtx(arena, env, "/h");
    var bb: [64]u8 = undefined;
    cx.cfg.graph.base = try arena.dupe(u8, f.base(&bb));
    return cx;
}

test "get with token in header, never in the URL" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    const f = try fk.Fake.start(std.testing.io);
    defer f.stop();
    const cx = try mk(arena.allocator(), &env, f);
    const u = try call.graphUrl(&cx, arena.allocator(), "1234567890");
    const r = call.call(&cx, arena.allocator(), .{ .url = u, .token = "TESTTOKEN" });
    try std.testing.expect(r == .ok);
    try std.testing.expect(std.mem.indexOf(u8, r.ok.body, "test_account") != null);
    try std.testing.expect(f.logHas("auth=yes"));
    try std.testing.expect(!f.logHas("TESTTOKEN"));
    const bad = call.call(&cx, arena.allocator(), .{ .url = u, .token = "WRONG" });
    try std.testing.expect(bad == .fail);
    try std.testing.expectEqual(@import("ap-error.zig").Class.blocked, bad.fail.info.class);
}

test "a refused host never connects" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var cx = ctxm.testCtx(arena.allocator(), &env, "/h");
    cx.mock = false;
    const r = call.call(&cx, arena.allocator(), .{ .url = "https://evil.example.com/x", .token = "t" });
    try std.testing.expect(r == .fail);
    try std.testing.expectEqualStrings("NotAllowed", r.fail.info.msg);
    const r2 = call.call(&cx, arena.allocator(), .{ .url = "http://graph.facebook.com/x", .token = "t" });
    try std.testing.expect(r2 == .fail);
}
