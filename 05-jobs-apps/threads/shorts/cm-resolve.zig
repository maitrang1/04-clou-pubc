// resolve: settle an `unsure` send by asking Threads (container status, then the account's recent posts). NEVER re-sends. A person can also answer: --as posted|failed.
const std = @import("std");
const Ctx = @import("co-ctx.zig").Ctx;
const args = @import("co-args.zig");
const exit = @import("co-exit.zig");
const out = @import("co-out.zig");
const log = @import("co-log.zig");
const kill = @import("co-kill.zig");
const send = @import("rw-send.zig");
const dupe = @import("rw-dupe.zig");
const text = @import("rw-text.zig");
const host = @import("rw-host.zig");
const auth = @import("ap-auth.zig");
const st_api = @import("ap-status.zig");
const look = @import("ap-lookup.zig");

const Decision = struct { state: send.State, note: []const u8, code: u8, media: []const u8 = "", url: []const u8 = "" };

// "YYYY-MM-DDTHH:MM:SS" in UTC from epoch ms (Threads timestamps are ISO 8601 +0000)
fn isoUtc(buf: []u8, ms: i64) []const u8 {
    if (ms < 0) return "";
    const es = std.time.epoch.EpochSeconds{ .secs = @intCast(@divTrunc(ms, 1000)) };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.bufPrint(buf, "{d}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}", .{ yd.year, md.month.numeric(), md.day_index + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute() }) catch "";
}

// the post in the account's list that starts like our text (we keep the text prefix in the ledger)
fn findPost(cx: *Ctx, a: std.mem.Allocator, row: send.Row, tok: []const u8, uid: []const u8) ?look.Item {
    const since = @divTrunc(row.created, 1000) - 3600;
    switch (look.list(cx, a, tok, uid, since)) {
        .fail => return null,
        .ok => |items| {
            const hit = (dupe.match(a, row.text_key, items, cx.cfg.safety.dup_chars) catch return null) orelse return null;
            for (items) |it| if (std.mem.eql(u8, it.id, hit)) {
                var ib: [24]u8 = undefined; // only a post made at or after our row can be ours: same opening words alone are not enough
                const iso = isoUtc(&ib, row.created);
                if (it.timestamp.len >= 19 and iso.len == 19 and std.mem.order(u8, it.timestamp[0..19], iso) == .lt) return null;
                return it;
            };
            return null;
        },
    }
}

fn decide(cx: *Ctx, a: std.mem.Allocator, row: send.Row, tok: []const u8, uid: []const u8) Decision {
    const keep = Decision{ .state = .unsure, .note = "Threads cannot confirm yet: wait a few minutes and run resolve again", .code = exit.UNSURE };
    if (row.media_id.len > 0 and row.state == .unsure) { // the answer had an id once: just read it
        switch (look.media(cx, a, tok, row.media_id)) {
            .ok => |it| return .{ .state = .posted, .note = "Threads shows the post", .code = exit.OK, .media = row.media_id, .url = it.permalink },
            .fail => {},
        }
    }
    if (row.container_id.len > 0) switch (st_api.get(cx, a, tok, row.container_id)) {
        .fail => |f| {
            if (findPost(cx, a, row, tok, uid)) |it| return .{ .state = .posted, .note = "found in the account's posts", .code = exit.OK, .media = it.id, .url = it.permalink };
            return .{ .state = .unsure, .note = std.fmt.allocPrint(a, "could not ask Threads ({s}): try again", .{f.info.msg}) catch "could not ask Threads", .code = exit.UNSURE };
        },
        .ok => |s| switch (s.kind) {
            .published => {
                if (findPost(cx, a, row, tok, uid)) |it| return .{ .state = .posted, .note = "container PUBLISHED, post found", .code = exit.OK, .media = it.id, .url = it.permalink };
                return .{ .state = .posted, .note = "container PUBLISHED (post id not found in the list yet)", .code = exit.OK };
            },
            .finished => {
                if (findPost(cx, a, row, tok, uid)) |it| return .{ .state = .posted, .note = "found in the account's posts", .code = exit.OK, .media = it.id, .url = it.permalink };
                // the status and the list can lag behind a publish that Threads accepted: only after a cool-off is "still FINISHED" an answer
                const wait_ms = @as(i64, cx.cfg.limits.unsure_wait_min) * 60_000;
                if (cx.nowMs() - row.updated < wait_ms) return .{ .state = .unsure, .note = "container is still FINISHED but the request was sent a moment ago: Threads may still post it; run resolve again later", .code = exit.UNSURE };
                return .{ .state = .failed, .note = "container is still FINISHED long after the request: the publish never landed, nothing is posted; a person may retry with publish --again", .code = exit.OK };
            },
            .failed, .expired => return .{ .state = .failed, .note = std.fmt.allocPrint(a, "container {s}: nothing was published", .{s.raw}) catch "container ended", .code = exit.OK },
            .in_progress, .unknown => return keep,
        },
    };
    // no container id: only the list can tell
    if (findPost(cx, a, row, tok, uid)) |it| return .{ .state = .posted, .note = "found in the account's posts", .code = exit.OK, .media = it.id, .url = it.permalink };
    return keep;
}

pub fn run(cx: *Ctx, av: []const []const u8) u8 {
    var arena = std.heap.ArenaAllocator.init(cx.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const name = args.value(av, "--video") orelse {
        out.warn(cx, "error: --video <name> is required", .{});
        return exit.USAGE;
    };
    var lock: ?kill.Lock = null;
    if (cx.live) lock = kill.acquire(cx) catch {
        out.warn(cx, "blocked: a run is active (or the data folder is unusable); try again when it ends", .{});
        return exit.BLOCKED;
    };
    defer if (lock) |*l| l.release();
    var db = send.open(cx) catch return exit.BLOCKED;
    defer db.close();
    const row = (send.byName(&db, a, name) catch return exit.BLOCKED) orelse {
        out.warn(cx, "error: '{s}' is not in the ledger", .{name});
        return exit.FAILED;
    };
    if (row.state != .unsure) {
        out.say(cx, "'{s}' is {s}: nothing to resolve", .{ name, send.stateName(row.state) });
        return exit.OK;
    }
    var d: Decision = undefined;
    if (args.value(av, "--as")) |as| {
        if (std.mem.eql(u8, as, "posted")) d = .{ .state = .posted, .note = "a person confirmed it is on the account", .code = exit.OK } else if (std.mem.eql(u8, as, "failed")) d = .{ .state = .failed, .note = "a person confirmed it is not on the account", .code = exit.OK } else {
            out.warn(cx, "error: --as must be posted or failed", .{});
            return exit.USAGE;
        }
    } else {
        const tok = cx.token() orelse {
            out.warn(cx, "error: no access token (env var or file named in config)", .{});
            return exit.USAGE;
        };
        var uid: []const u8 = cx.userId() orelse "";
        if (uid.len == 0) switch (auth.me(cx, a, tok)) {
            .ok => |m| uid = m.id,
            .fail => {
                out.warn(cx, "error: cannot learn the account id", .{});
                return exit.BLOCKED;
            },
        };
        d = decide(cx, a, row, tok, uid);
    }
    d.note = text.safeNote(a, d.note, 300);
    out.say(cx, "{s}: {s} -> {s} | {s}", .{ name, send.stateName(row.state), send.stateName(d.state), d.note });
    if (d.state == .unsure) {
        out.json(cx, a, .{ .name = name, .state = "unsure", .note = d.note, .written = false });
        return exit.UNSURE;
    }
    if (!cx.live) {
        out.say(cx, "dry-run: nothing written. Add --live to settle it.", .{});
        out.json(cx, a, .{ .name = name, .would = send.stateName(d.state), .note = d.note, .written = false });
        return exit.OK;
    }
    send.setState(cx, &db, row.id, d.state, d.note, d.media, d.url) catch |e| {
        out.warn(cx, "blocked: {s}", .{if (e == error.Killed) "kill file is on" else @errorName(e)});
        return exit.BLOCKED;
    };
    if (d.state == .posted or d.state == .failed) host.finish(cx, a, row.host_file) catch {};
    log.log(cx, "info", "{s} resolved to {s}: {s}", .{ name, send.stateName(d.state), d.note });
    out.json(cx, a, .{ .name = name, .state = send.stateName(d.state), .note = d.note, .written = true });
    return exit.OK;
}
