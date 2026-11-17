// token: the sign-in at a glance (read-only unless --refresh --live). Asks Pinterest who the token belongs to; never prints a token.
const std = @import("std");
const Ctx = @import("co-ctx.zig").Ctx;
const args = @import("co-args.zig");
const exit = @import("co-exit.zig");
const out = @import("co-out.zig");
const auth = @import("ap-auth.zig");
const board = @import("ap-board.zig");
const send = @import("rw-send.zig");
const kill = @import("co-kill.zig");

pub const Check = struct { code: u8, user: []const u8 = "", access_days: i64 = -1, refresh_days: i64 = -1, msg: []const u8 = "" };

fn daysTo(cx: *const Ctx, at: i64) i64 {
    if (at == 0) return -1;
    return @divTrunc(at - @divTrunc(cx.nowMs(), 1000), 86400);
}

// shared with doctor. Read-only.
pub fn check(cx: *Ctx, a: std.mem.Allocator) Check {
    const t = auth.load(cx, a) orelse return .{ .code = exit.USAGE, .msg = "no sign-in yet: run login (see 10-HOW-TO)" };
    var c = Check{ .code = exit.OK, .access_days = daysTo(cx, t.access_expires_at), .refresh_days = daysTo(cx, t.refresh_expires_at) };
    const tok: []const u8 = switch (auth.ensure(cx, a, false)) {
        .ok => |x| x,
        .fail => |f| {
            c.code = exit.BLOCKED;
            c.msg = f.msg;
            return c;
        },
    };
    switch (board.userName(cx, a, tok)) {
        .ok => |u| c.user = u,
        .fail => |f| {
            c.code = if (f.info.class == .blocked) exit.BLOCKED else exit.FAILED;
            c.msg = f.info.msg;
        },
    }
    if (c.refresh_days >= 0 and c.refresh_days < cx.cfg.token_warn_days and c.msg.len == 0) c.msg = "refresh token is getting old: a live run or token --refresh --live renews it";
    return c;
}

pub fn run(cx: *Ctx, av: []const []const u8) u8 {
    var arena = std.heap.ArenaAllocator.init(cx.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    if (args.has(av, "--refresh")) {
        if (!cx.live) {
            out.say(cx, "dry-run: would swap the refresh token for a new pair and store it. Add --live.", .{});
            return exit.OK;
        }
        if (kill.killOn(cx)) {
            out.warn(cx, "blocked: kill file is on", .{});
            return exit.BLOCKED;
        }
        const t = auth.load(cx, a) orelse {
            out.warn(cx, "error: no sign-in yet: run login", .{});
            return exit.USAGE;
        };
        switch (auth.refresh(cx, a, t)) {
            .ok => out.say(cx, "refreshed: new tokens stored", .{}),
            .fail => |f| {
                out.warn(cx, "error: refresh failed: {s}{s}", .{ f.info.msg, if (f.info.class == .blocked) " (sign-in is dead: run login again)" else "" });
                return if (f.info.class == .blocked) exit.BLOCKED else exit.FAILED;
            },
        }
    }
    const c = check(cx, a);
    if (c.code == exit.OK or c.access_days >= 0) {
        if (send.open(cx)) |d| {
            var db = d;
            defer db.close();
            if (!kill.killOn(cx)) {
                const t = auth.load(cx, a);
                send.metaSetInt(&db, "tok_exp", if (t) |x| x.refresh_expires_at else 0) catch {};
                send.metaSetInt(&db, "tok_chk", cx.nowMs()) catch {};
            }
        } else |_| {}
    }
    if (c.msg.len > 0) out.warn(cx, "token: {s}", .{c.msg});
    if (c.user.len > 0) out.say(cx, "token: works for account '{s}' · access {d} days left · refresh {d} days left", .{ c.user, c.access_days, c.refresh_days });
    out.json(cx, a, .{ .account = c.user, .access_days_left = c.access_days, .refresh_days_left = c.refresh_days, .message = c.msg, .exit = c.code });
    return c.code;
}
