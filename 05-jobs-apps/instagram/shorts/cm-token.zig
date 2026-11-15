// token: read-only check that the token still works: the account answers a read (id, username). No expiry date exists for these tokens, so none is shown. Never prints the token.
const std = @import("std");
const Ctx = @import("co-ctx.zig").Ctx;
const exit = @import("co-exit.zig");
const out = @import("co-out.zig");
const auth = @import("ap-auth.zig");

pub const Check = struct { code: u8, valid: bool = false, username: []const u8 = "", msg: []const u8 = "" };

// shared with doctor
pub fn check(cx: *Ctx, a: std.mem.Allocator) Check {
    const tok = cx.token() orelse return .{ .code = exit.USAGE, .msg = "no access token (env var or file named in config graph.token_*)" };
    const ig = cx.igId() orelse return .{ .code = exit.USAGE, .msg = "no Instagram user id (env var or file named in config account.ig_user_id_*)" };
    switch (auth.who(cx, a, tok, ig)) {
        .fail => |f| return .{ .code = if (f.info.class == .blocked) exit.BLOCKED else exit.FAILED, .msg = f.info.msg },
        .ok => |w| {
            if (!std.mem.eql(u8, w.id, ig)) return .{ .code = exit.BLOCKED, .msg = "the token answers for a different Instagram account than account.ig_user_id" };
            return .{ .code = exit.OK, .valid = true, .username = w.username };
        },
    }
}

pub fn run(cx: *Ctx, av: []const []const u8) u8 {
    _ = av;
    var arena = std.heap.ArenaAllocator.init(cx.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const c = check(cx, a);
    if (c.msg.len > 0) out.warn(cx, "token: {s}", .{c.msg});
    if (c.valid) out.say(cx, "token: works · account {s} · expiry date unknown", .{if (c.username.len > 0) c.username else "(no name)"});
    out.json(cx, a, .{ .valid = c.valid, .username = c.username, .message = c.msg, .exit = c.code });
    return c.code;
}
