// token: read-only check of the Page token with debug_token (valid, expiry, scopes). Never prints the token.
const std = @import("std");
const Ctx = @import("co-ctx.zig").Ctx;
const exit = @import("co-exit.zig");
const out = @import("co-out.zig");
const auth = @import("ap-auth.zig");
const call = @import("ap-call.zig");
const send = @import("rw-send.zig");
const kill = @import("co-kill.zig");

pub const Check = struct { code: u8, valid: bool = false, never: bool = false, expires_at: i64 = 0, missing: []const []const u8 = &.{}, msg: []const u8 = "" };

// shared with doctor
pub fn check(cx: *Ctx, a: std.mem.Allocator) Check {
    const tok = cx.pageToken() orelse return .{ .code = exit.USAGE, .msg = "no Page token (env var or file named in config graph.page_token_*)" };
    const app = cx.appToken() orelse return .{ .code = exit.USAGE, .msg = "no app id/secret: debug_token needs them (config graph.app_id_*, app_secret_*)" };
    switch (auth.debugToken(cx, a, tok, app)) {
        .fail => |f| return .{ .code = if (f.info.class == .blocked) exit.BLOCKED else exit.FAILED, .msg = f.info.msg },
        .ok => |i| {
            var miss: std.ArrayList([]const u8) = .empty;
            for (cx.cfg.graph.need_scopes) |need| {
                var have = false;
                for (i.scopes) |s| if (std.mem.eql(u8, s, need)) {
                    have = true;
                };
                if (!have) miss.append(a, need) catch {};
            }
            const code: u8 = if (!i.is_valid or miss.items.len > 0) exit.BLOCKED else exit.OK;
            const msg: []const u8 = if (!i.is_valid) (if (i.err_msg.len > 0) i.err_msg else "token is not valid") else "";
            return .{ .code = code, .valid = i.is_valid, .never = i.expires_at == 0, .expires_at = i.expires_at, .missing = miss.items, .msg = msg };
        },
    }
}

pub fn run(cx: *Ctx, av: []const []const u8) u8 {
    _ = av;
    var arena = std.heap.ArenaAllocator.init(cx.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const c = check(cx, a);
    if (c.valid and !kill.killOn(cx)) {
        // remember expiry for `status` (a ledger note, not a send)
        if (send.open(cx)) |d| {
            var db = d;
            defer db.close();
            send.metaSetInt(&db, "tok_exp", c.expires_at) catch {};
            send.metaSetInt(&db, "tok_chk", cx.nowMs()) catch {};
        } else |_| {}
    }
    if (c.msg.len > 0) out.warn(cx, "token: {s}", .{c.msg});
    if (c.valid) out.say(cx, "token: valid · {s}", .{if (c.never) "never expires" else "has an expiry date"});
    for (c.missing) |m| out.warn(cx, "token: missing permission {s}", .{m});
    out.json(cx, a, .{ .valid = c.valid, .never_expires = c.never, .expires_at = c.expires_at, .missing_scopes = c.missing, .message = c.msg, .exit = c.code });
    return c.code;
}
