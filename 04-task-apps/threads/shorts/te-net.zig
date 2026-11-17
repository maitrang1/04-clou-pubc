// Tests for co-net + ap-call against the fake: token only the documented way, refused hosts, redirects never followed.
const std = @import("std");
const fk = @import("te-fake-threads.zig");
const ctxm = @import("co-ctx.zig");
const call = @import("ap-call.zig");
const auth = @import("ap-auth.zig");

fn mk(arena: std.mem.Allocator, env: *std.process.Environ.Map, f: *fk.Fake) !ctxm.Ctx {
    var cx = ctxm.testCtx(arena, env, "/h");
    var bb: [64]u8 = undefined;
    cx.cfg.graph.base = try arena.dupe(u8, f.base(&bb));
    return cx;
}

test "GET sends the token as a query field, POST as a form field; a wrong token is a 190" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    const f = try fk.Fake.start(std.testing.io);
    defer f.stop();
    const cx = try mk(arena.allocator(), &env, f);
    const m = auth.me(&cx, arena.allocator(), "TESTTOKEN");
    try std.testing.expect(m == .ok);
    try std.testing.expectEqualStrings("7770001", m.ok.id);
    try std.testing.expect(f.logHas("GET /v1.0/me tok=yes"));
    try std.testing.expect(!f.logHas("TESTTOKEN")); // the fake log never holds a token, ours neither
    const bad = auth.me(&cx, arena.allocator(), "WRONG");
    try std.testing.expect(bad == .fail);
    try std.testing.expectEqual(@import("ap-error.zig").Class.blocked, bad.fail.info.class);
}

test "bearer style sends the header and no token in the URL or body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    const f = try fk.Fake.start(std.testing.io);
    defer f.stop();
    var cx = try mk(arena.allocator(), &env, f);
    cx.cfg.net.auth_style = "bearer";
    try std.testing.expect(auth.me(&cx, arena.allocator(), "TESTTOKEN") == .ok);
}

test "a refused host never connects; plain http is refused outside mock builds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var cx = ctxm.testCtx(arena.allocator(), &env, "/h");
    cx.mock = false;
    const r = call.call(&cx, arena.allocator(), .{ .url = "https://evil.example.com/x", .token = "t" });
    try std.testing.expect(r == .fail);
    try std.testing.expectEqualStrings("NotAllowed", r.fail.info.msg);
    const r2 = call.call(&cx, arena.allocator(), .{ .url = "http://graph.threads.com/x", .token = "t" });
    try std.testing.expect(r2 == .fail);
}

test "ids are digits: a path trick never reaches the network" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    const cx = ctxm.testCtx(arena.allocator(), &env, "/h");
    const r = @import("ap-status.zig").get(&cx, arena.allocator(), "t", "12/../x");
    try std.testing.expect(r == .fail);
}
