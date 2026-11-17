// token: read-only check (who is it, scopes when an app secret is present, days left from the stored issue date) and the 60-day refresh. Never prints the token.
const std = @import("std");
const Ctx = @import("co-ctx.zig").Ctx;
const args = @import("co-args.zig");
const exit = @import("co-exit.zig");
const out = @import("co-out.zig");
const log = @import("co-log.zig");
const kill = @import("co-kill.zig");
const os = @import("co-os.zig");
const util = @import("co-util.zig");
const auth = @import("ap-auth.zig");

const CF = .{ .life_days = 60, .min_age_h = 24, .day_s = 86400 };

// days since the stored issue date (seconds since epoch in the meta file), or null when unknown
pub fn ageS(cx: *const Ctx) ?i64 {
    const p = cx.secretPath(cx.arena, cx.cfg.account.token_meta_file) catch return null;
    const t = util.readAll(cx.arena, cx.io, p, 256) catch return null;
    const issued = std.fmt.parseInt(i64, std.mem.trim(u8, t, " \t\r\n"), 10) catch return null;
    return @divTrunc(cx.nowMs(), 1000) - issued;
}
pub fn daysLeft(cx: *const Ctx) ?i64 {
    const age = ageS(cx) orelse return null;
    return CF.life_days - @divTrunc(age, CF.day_s);
}

pub const Check = struct { code: u8, id: []const u8 = "", username: []const u8 = "", scopes_checked: bool = false, missing: []const []const u8 = &.{}, msg: []const u8 = "" };

// shared with doctor: me + optional scopes
pub fn check(cx: *Ctx, a: std.mem.Allocator) Check {
    const tok = cx.token() orelse return .{ .code = exit.USAGE, .msg = "no access token (env var or file named in config account.token_*)" };
    var c = Check{ .code = exit.OK };
    switch (auth.me(cx, a, tok)) {
        .fail => |f| return .{ .code = if (f.info.class == .blocked) exit.BLOCKED else exit.FAILED, .msg = f.info.msg },
        .ok => |m| {
            c.id = m.id;
            c.username = m.username;
        },
    }
    if (cx.userId()) |stored| if (!std.mem.eql(u8, stored, c.id)) {
        c.code = exit.BLOCKED;
        c.msg = "the stored user id is not the id of this token: fix account.user_id_file";
        return c;
    };
    if (cx.appToken()) |app| {
        switch (auth.debugToken(cx, a, tok, app)) {
            .fail => |f| {
                c.msg = f.info.msg;
                c.code = exit.BLOCKED;
            },
            .ok => |i| {
                c.scopes_checked = true;
                var miss: std.ArrayList([]const u8) = .empty;
                for (cx.cfg.graph.need_scopes) |need| {
                    var have = false;
                    for (i.scopes) |s| if (std.mem.eql(u8, s, need)) {
                        have = true;
                    };
                    if (!have) miss.append(a, need) catch {};
                }
                c.missing = miss.items;
                if (!i.is_valid or miss.items.len > 0) c.code = exit.BLOCKED;
                if (!i.is_valid) c.msg = if (i.err_msg.len > 0) i.err_msg else "token is not valid";
            },
        }
    }
    return c;
}

pub const Refreshed = enum { not_needed, done, too_young, no_file, failed, dry };

// refresh when due (or forced). Live only; rewrites the token file and the meta file atomically. The old token stays valid until the new one is on disk.
pub fn refresh(cx: *Ctx, a: std.mem.Allocator, force: bool) Refreshed {
    if (!cx.tokenInFile()) return .no_file; // env tokens are the owner's to rotate
    const tok = cx.token() orelse return .failed;
    if (!force) {
        const left = daysLeft(cx) orelse return .not_needed;
        if (left >= cx.cfg.token_refresh_days) return .not_needed;
    }
    if (ageS(cx)) |age| if (age < CF.min_age_h * 3600) return .too_young;
    if (!cx.live) return .dry;
    kill.writeOk(cx) catch return .failed;
    switch (auth.refresh(cx, a, tok)) {
        .fail => |f| {
            log.log(cx, "warn", "token refresh failed: {s}", .{f.info.msg});
            return .failed;
        },
        .ok => |n| {
            const tp = cx.secretPath(a, cx.cfg.account.token_file) catch return .failed;
            const mp = cx.secretPath(a, cx.cfg.account.token_meta_file) catch return .failed;
            os.writeSecretAtomic(a, cx.io, tp, n.token) catch return .failed;
            const ms = std.fmt.allocPrint(a, "{d}\n", .{@divTrunc(cx.nowMs(), 1000)}) catch return .failed;
            os.writeSecretAtomic(a, cx.io, mp, ms) catch return .failed;
            log.log(cx, "info", "token refreshed", .{});
            return .done;
        },
    }
}

pub fn run(cx: *Ctx, av: []const []const u8) u8 {
    var arena = std.heap.ArenaAllocator.init(cx.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    if (args.has(av, "--refresh")) {
        const r = refresh(cx, a, true);
        const msg: []const u8 = switch (r) {
            .done => "token refreshed (valid 60 more days)",
            .dry => "dry-run: would refresh the token now. Add --live.",
            .too_young => "token is under 24 h old: Threads refuses a refresh yet",
            .no_file => "the token comes from an env var: rotate it by hand (only a token file can be rewritten)",
            .failed => "refresh failed (see run.jsonl); the old token is untouched",
            .not_needed => "not needed",
        };
        out.say(cx, "token: {s}", .{msg});
        out.json(cx, a, .{ .refresh = @tagName(r) });
        return switch (r) {
            .done, .dry => exit.OK,
            .too_young => exit.NOTHING,
            else => exit.FAILED,
        };
    }
    const c = check(cx, a);
    const left = daysLeft(cx);
    if (c.msg.len > 0) out.warn(cx, "token: {s}", .{c.msg});
    if (c.id.len > 0) out.say(cx, "token: valid · account {s}{s}", .{ c.username, if (c.scopes_checked) " · scopes checked" else " · scopes unchecked (no app id/secret)" });
    for (c.missing) |m| out.warn(cx, "token: missing permission {s}", .{m});
    if (left) |d| out.say(cx, "token: {d} days left{s}", .{ d, if (d < cx.cfg.token_warn_days) "  <-- refresh soon (token --refresh --live)" else "" }) else out.say(cx, "token: issue date unknown (no {s} file): days left unknown", .{cx.cfg.account.token_meta_file});
    out.json(cx, a, .{ .ok = c.code == exit.OK, .account = c.username, .scopes_checked = c.scopes_checked, .missing_scopes = c.missing, .days_left = left orelse -1, .message = c.msg, .exit = c.code });
    return c.code;
}

test "age and days left come from the meta file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    const home = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    var cx = @import("co-ctx.zig").testCtx(a, &env, home);
    cx.cfg.secrets_dir = "~/sec";
    try util.mkdirp(cx.io, try cx.path(a, "~/sec"));
    try std.testing.expect(daysLeft(&cx) == null);
    cx.fake_now_ms = 1_800_000_000_000;
    const mp = try cx.secretPath(a, cx.cfg.account.token_meta_file);
    try util.writeAtomic(a, cx.io, mp, "1794816000\n"); // 60 days before now
    try std.testing.expectEqual(@as(i64, 0), daysLeft(&cx).?);
    try util.writeAtomic(a, cx.io, mp, "1799568000\n"); // 5 days before now
    try std.testing.expectEqual(@as(i64, 55), daysLeft(&cx).?);
}
