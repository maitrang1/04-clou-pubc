// status: counts by state, rolling-24h publishes and containers vs cap, breaker, held/staged lists. Ledger only; with --verify it also reads Meta's own allowance (one read-only call).
const std = @import("std");
const Ctx = @import("co-ctx.zig").Ctx;
const exit = @import("co-exit.zig");
const out = @import("co-out.zig");
const open = @import("co-open.zig");
const send = @import("rw-send.zig");
const caps = @import("rw-caps.zig");
const pair = @import("rw-pair.zig");
const kill = @import("co-kill.zig");
const args = @import("co-args.zig");
const quota_api = @import("ap-quota.zig");

const CF = .{ .day_ms = 24 * 3600 * 1000 };

fn localTime(buf: []u8, ms: i64, tz: i32) []const u8 {
    const secs: i64 = @divTrunc(ms, 1000) + @as(i64, tz) * 3600;
    if (secs < 0) return "?";
    const es = std.time.epoch.EpochSeconds{ .secs = @intCast(secs) };
    const day = es.getEpochDay().calculateYearDay();
    const md = day.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.bufPrint(buf, "{d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}", .{ day.year, md.month.numeric(), md.day_index + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour() }) catch "?";
}

pub fn run(cx: *Ctx, av: []const []const u8) u8 {
    const verify = args.has(av, "--verify");
    var arena = std.heap.ArenaAllocator.init(cx.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const killed = kill.killOn(cx);
    var db = open.existing(cx) orelse {
        out.say(cx, "no ledger yet: nothing was ever sent here. kill file: {s}", .{if (killed) "ON" else "off"});
        out.json(cx, a, .{ .sent = 0, .kill = killed });
        return exit.OK;
    };
    defer db.close();
    const now = cx.nowMs();
    const sending = send.count(&db, .sending) catch 0;
    const staged = send.count(&db, .staged) catch 0;
    const posted = send.count(&db, .posted) catch 0;
    const failed = send.count(&db, .failed) catch 0;
    const unsure = send.count(&db, .unsure) catch 0;
    const expired = send.count(&db, .expired) catch 0;
    const last24 = send.countSince(&db, now - CF.day_ms) catch -1;
    const conts24 = send.contSince(&db, now - CF.day_ms) catch -1;
    const blk = (caps.blocked(cx, &db, a) catch null);
    var held: std.ArrayList([]const u8) = .empty;
    var staged_names: std.ArrayList([]const u8) = .empty;
    if (pair.scan(cx, a, &db)) |es| {
        for (es) |e| {
            if (e.kind == .held) held.append(a, e.name) catch {};
            if (e.kind == .done and std.mem.eql(u8, e.reason, "staged")) staged_names.append(a, e.name) catch {};
        }
    } else |_| {}
    out.say(cx, "posted {d} · staged {d} · failed {d} · expired {d} · unsure {d} · sending {d}", .{ posted, staged, failed, expired, unsure, sending });
    out.say(cx, "last 24 h: {d} of {d} publishes (cap) · {d} of {d} containers", .{ last24, cx.cfg.limits.daily_cap, conts24, cx.cfg.limits.container_cap });
    out.say(cx, "kill file: {s} · run: {s}", .{ if (killed) "ON" else "off", if (blk) |b| b.why else "free to send" });
    out.say(cx, "token: no expiry date is available for these tokens: run `token` (a read) to see if it still works", .{});
    var meta_usage: i64 = -1;
    var meta_total: i64 = -1;
    if (verify) {
        if (cx.token()) |tok| if (cx.igId()) |ig| switch (quota_api.get(cx, a, tok, ig)) {
            .ok => |q| {
                meta_usage = q.usage;
                meta_total = q.total;
                out.say(cx, "Instagram allowance: {d} used of {d} (our cap {d})", .{ q.usage, q.total, cx.cfg.limits.meta_cap });
            },
            .fail => |f| out.say(cx, "Instagram allowance: could not read ({s})", .{f.info.msg}),
        };
    }
    const lastf = send.lastFinish(&db) catch 0;
    if (lastf > 0) {
        var tb: [32]u8 = undefined;
        out.say(cx, "last publish: {s} (UTC offset {d} h)", .{ localTime(&tb, lastf, cx.cfg.tz_offset_hours), cx.cfg.tz_offset_hours });
    }
    if (unsure > 0) out.say(cx, "{d} unsure: run resolve --video <name>", .{unsure});
    for (held.items) |h| out.say(cx, "held: {s} (approve --video {s} --live)", .{ h, h });
    for (staged_names.items) |h| out.say(cx, "staged: {s} (not public; set post.public then publish --video {s} --live)", .{ h, h });
    out.json(cx, a, .{ .posted = posted, .staged = staged, .failed = failed, .expired = expired, .unsure = unsure, .sending = sending, .last_24h = last24, .containers_24h = conts24, .daily_cap = cx.cfg.limits.daily_cap, .container_cap = cx.cfg.limits.container_cap, .meta_usage = meta_usage, .meta_total = meta_total, .kill = killed, .blocked = if (blk) |b| b.why else "", .held = held.items, .staged_names = staged_names.items });
    return if (unsure > 0) exit.UNSURE else exit.OK;
}
