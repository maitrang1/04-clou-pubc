// status: counts by state, rolling-24h publish requests vs cap, breaker, token days, held and staged lists. Reads the ledger and the secrets folder only; no call to Threads.
const std = @import("std");
const Ctx = @import("co-ctx.zig").Ctx;
const exit = @import("co-exit.zig");
const out = @import("co-out.zig");
const open = @import("co-open.zig");
const send = @import("rw-send.zig");
const caps = @import("rw-caps.zig");
const pair = @import("rw-pair.zig");
const kill = @import("co-kill.zig");
const tokc = @import("cm-token.zig");

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
    _ = av;
    var arena = std.heap.ArenaAllocator.init(cx.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const killed = kill.killOn(cx);
    const left = tokc.daysLeft(cx);
    var db = open.existing(cx) orelse {
        out.say(cx, "no ledger yet: nothing was ever sent here. kill file: {s} · publisher device: {s}", .{ if (killed) "ON" else "off", if (cx.cfg.device.publisher) "yes" else "no" });
        out.json(cx, a, .{ .sent = 0, .kill = killed, .publisher = cx.cfg.device.publisher });
        return exit.OK;
    };
    defer db.close();
    const now = cx.nowMs();
    const sending = send.count(&db, .sending) catch 0;
    const staged = send.count(&db, .staged) catch 0;
    const posted = send.count(&db, .posted) catch 0;
    const failed = send.count(&db, .failed) catch 0;
    const unsure = send.count(&db, .unsure) catch 0;
    const last24 = send.countSince(&db, now - CF.day_ms) catch -1;
    const blk = (caps.blocked(cx, &db, a) catch null);
    var held: std.ArrayList([]const u8) = .empty;
    if (pair.scan(cx, a, &db)) |es| {
        for (es) |e| if (e.kind == .held) held.append(a, e.name) catch {};
    } else |_| {}
    out.say(cx, "posted {d} · staged {d} · failed {d} · unsure {d} · sending {d}", .{ posted, staged, failed, unsure, sending });
    out.say(cx, "last 24 h: {d} of {d} (cap) · publisher device: {s}", .{ last24, cx.cfg.limits.daily_cap, if (cx.cfg.device.publisher) "yes" else "NO (publish --live is refused here)" });
    out.say(cx, "kill file: {s} · run: {s}", .{ if (killed) "ON" else "off", if (blk) |b| b.why else "free to send" });
    if (left) |d| out.say(cx, "token: {d} days left{s}", .{ d, if (d < cx.cfg.token_warn_days) "  <-- refresh soon (token --refresh --live)" else "" }) else out.say(cx, "token: issue date unknown", .{});
    const lastp = send.lastPub(&db) catch 0;
    if (lastp > 0) {
        var tb: [32]u8 = undefined;
        out.say(cx, "last publish request: {s} (UTC offset {d} h)", .{ localTime(&tb, lastp, cx.cfg.tz_offset_hours), cx.cfg.tz_offset_hours });
    }
    if (unsure > 0) out.say(cx, "{d} unsure: run resolve --video <name>", .{unsure});
    if (staged > 0) out.say(cx, "{d} staged: finished containers that expire in 24 h (set post.public to publish them)", .{staged});
    for (held.items) |h| out.say(cx, "held: {s} (approve --video {s} --live)", .{ h, h });
    out.json(cx, a, .{ .posted = posted, .staged = staged, .failed = failed, .unsure = unsure, .sending = sending, .last_24h = last24, .daily_cap = cx.cfg.limits.daily_cap, .kill = killed, .blocked = if (blk) |b| b.why else "", .token_days_left = left orelse -1, .publisher = cx.cfg.device.publisher, .held = held.items });
    return if (unsure > 0) exit.UNSURE else exit.OK;
}
