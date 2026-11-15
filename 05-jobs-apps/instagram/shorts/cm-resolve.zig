// resolve: settle an `unsure` send by asking Instagram (container status, then the recent media). NEVER re-sends. A person can also answer: --as posted|failed.
const std = @import("std");
const Ctx = @import("co-ctx.zig").Ctx;
const args = @import("co-args.zig");
const exit = @import("co-exit.zig");
const out = @import("co-out.zig");
const log = @import("co-log.zig");
const kill = @import("co-kill.zig");
const send = @import("rw-send.zig");
const call = @import("ap-call.zig");
const st_api = @import("ap-status.zig");
const list_api = @import("ap-list.zig");

const Decision = struct { state: send.State, note: []const u8, code: u8, media_id: []const u8 = "" };

// container PUBLISHED proves the post exists. The media id comes from the recent-media list: exactly one new Reel since the send, else we say so and keep the container as proof.
fn findMedia(cx: *Ctx, a: std.mem.Allocator, row: send.Row, tok: []const u8, ig: []const u8) []const u8 {
    const since = @divTrunc(row.created, 1000) - 3600;
    switch (list_api.list(cx, a, tok, ig, since)) {
        .fail => return "",
        .ok => |items| {
            var n: usize = 0;
            var id: []const u8 = "";
            for (items) |it| {
                if (it.product.len > 0 and !std.mem.eql(u8, it.product, "REELS")) continue;
                n += 1;
                id = it.id;
            }
            return if (n == 1) id else "";
        },
    }
}

fn decide(cx: *Ctx, a: std.mem.Allocator, row: send.Row, tok: []const u8, ig: []const u8) Decision {
    const keep = Decision{ .state = .unsure, .note = "Instagram cannot confirm yet: wait a few minutes and run resolve again", .code = exit.UNSURE };
    if (row.cont_id.len == 0) return .{ .state = .failed, .note = "no container id was ever issued: nothing could have been published", .code = exit.OK };
    switch (st_api.get(cx, a, tok, row.cont_id)) {
        .fail => |f| return .{ .state = .unsure, .note = std.fmt.allocPrint(a, "could not ask Instagram ({s}): try again", .{f.info.msg}) catch "could not ask Instagram", .code = exit.UNSURE },
        .ok => |s| switch (st_api.verdict(s)) {
            .published => {
                const mid = findMedia(cx, a, row, tok, ig);
                return .{ .state = .posted, .note = if (mid.len > 0) "container shows PUBLISHED; media found in the recent list" else "container shows PUBLISHED (media id not identified: more or fewer than one new Reel since the send)", .code = exit.OK, .media_id = mid };
            },
            .finished => {
                if (row.pub_at == 0) return .{ .state = .staged, .note = "container FINISHED and no publish call was ever sent: staged, not published", .code = exit.OK };
                // the call went out but the container still says FINISHED: not published (a published container reads PUBLISHED). Staged again, a person re-runs publish
                return .{ .state = .staged, .note = "container still FINISHED after the publish call: not published. publish --video NAME --live tries again", .code = exit.OK };
            },
            .failed => return .{ .state = .failed, .note = std.fmt.allocPrint(a, "Instagram says the container failed (subcode {s})", .{s.sub}) catch "Instagram says it failed", .code = exit.OK },
            .expired => return .{ .state = .expired, .note = "the container expired (24 h): nothing was published", .code = exit.OK },
            .in_progress, .unknown => {
                if (row.pub_at == 0) return .{ .state = .failed, .note = "publish was never sent: nothing is published, safe to send again with --again", .code = exit.OK };
                return keep;
            },
        },
    }
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
    if (row.state != .unsure and row.state != .sending) {
        out.say(cx, "'{s}' is {s}: nothing to resolve", .{ name, send.stateName(row.state) });
        return exit.OK;
    }
    var d: Decision = undefined;
    if (args.value(av, "--as")) |as| {
        if (std.mem.eql(u8, as, "posted")) d = .{ .state = .posted, .note = "a person confirmed it is on Instagram", .code = exit.OK } else if (std.mem.eql(u8, as, "failed")) d = .{ .state = .failed, .note = "a person confirmed it is not on Instagram", .code = exit.OK } else {
            out.warn(cx, "error: --as must be posted or failed", .{});
            return exit.USAGE;
        }
    } else {
        const tok = cx.token() orelse {
            out.warn(cx, "error: no access token (env var or file named in config)", .{});
            return exit.USAGE;
        };
        const ig = cx.igId() orelse {
            out.warn(cx, "error: no Instagram user id (env var or file named in config)", .{});
            return exit.USAGE;
        };
        d = decide(cx, a, row, tok, ig);
    }
    d.note = @import("rw-text.zig").safeNote(a, d.note, 300);
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
    send.setState(cx, &db, row.id, d.state, d.note, d.media_id, "") catch |e| {
        out.warn(cx, "blocked: {s}", .{if (e == error.Killed) "kill file is on" else @errorName(e)});
        return exit.BLOCKED;
    };
    log.log(cx, "info", "{s} resolved to {s}: {s}", .{ name, send.stateName(d.state), d.note });
    out.json(cx, a, .{ .name = name, .state = send.stateName(d.state), .note = d.note, .written = true });
    return exit.OK;
}
