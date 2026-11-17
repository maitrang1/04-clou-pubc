// resolve: settle an `unsure` send by asking Pinterest (the Pin by id, else the board's Pins). NEVER re-sends. A person can also answer: --as posted|failed.
const std = @import("std");
const Ctx = @import("co-ctx.zig").Ctx;
const args = @import("co-args.zig");
const exit = @import("co-exit.zig");
const out = @import("co-out.zig");
const log = @import("co-log.zig");
const kill = @import("co-kill.zig");
const send = @import("rw-send.zig");
const call = @import("ap-call.zig");
const auth = @import("ap-auth.zig");
const look = @import("ap-lookup.zig");
const pair = @import("rw-pair.zig");
const text = @import("rw-text.zig");
const sq = @import("rw-sqlite.zig");
const pub_cmd = @import("cm-publish.zig");

const Decision = struct { state: send.State, note: []const u8, code: u8, pin_id: []const u8 = "" };

fn decide(cx: *Ctx, a: std.mem.Allocator, db: *sq.Db, row: send.Row, tok: []const u8) Decision {
    const keep = Decision{ .state = .unsure, .note = "Pinterest cannot confirm yet: wait a few minutes and run resolve again, or settle it with --as posted|failed", .code = exit.UNSURE };
    if (row.finish_at == 0) return .{ .state = .failed, .note = "Pin create was never sent: nothing is posted, safe to send again with --again", .code = exit.OK };
    if (row.post_id.len > 0) {
        switch (look.getPin(cx, a, tok, row.post_id)) {
            .ok => |p| return .{ .state = .posted, .note = "Pinterest shows the Pin", .code = exit.OK, .pin_id = p.id },
            .fail => return keep,
        }
    }
    const board = cx.boardId() orelse return .{ .state = .unsure, .note = "no board id configured: cannot look at the board", .code = exit.UNSURE };
    // the Pin has no date filter: page the board and match the exact title + text we would have sent
    const entries = pair.scan(cx, a, db) catch return keep;
    const e = pair.find(entries, row.name) orelse return .{ .state = .unsure, .note = "the pair is no longer in the source folder: settle it with --as posted|failed", .code = exit.UNSURE };
    const cap = text.build(a, .{ .hooks = e.j.hooks, .description = e.j.description, .hashtags = e.j.hashtags, .ai_notice = e.j.ai_notice }, .{ .desc_max = cx.cfg.post.desc_max, .title_max = cx.cfg.post.title_max, .tags_max = cx.cfg.post.tags_max, .notice_required = cx.cfg.post.ai_notice_required }) catch return keep;
    var bookmark: []const u8 = "";
    var pages: u32 = 0;
    while (pages < cx.cfg.limits.resolve_max_pages) : (pages += 1) {
        switch (look.boardPins(cx, a, tok, board, bookmark)) {
            .fail => return keep,
            .ok => |pg| {
                for (pg.items) |it| {
                    if (std.mem.eql(u8, it.description, cap.description) and std.mem.eql(u8, it.title, cap.title orelse "")) return .{ .state = .posted, .note = "found on the board (same title and text)", .code = exit.OK, .pin_id = it.id };
                }
                if (pg.bookmark.len == 0) break;
                bookmark = pg.bookmark;
            },
        }
    }
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
    if (row.state != .unsure and row.state != .sending) {
        out.say(cx, "'{s}' is {s}: nothing to resolve", .{ name, send.stateName(row.state) });
        return exit.OK;
    }
    var d: Decision = undefined;
    if (args.value(av, "--as")) |as| {
        if (std.mem.eql(u8, as, "posted")) d = .{ .state = .posted, .note = "a person confirmed it is on Pinterest", .code = exit.OK } else if (std.mem.eql(u8, as, "failed")) d = .{ .state = .failed, .note = "a person confirmed it is not on Pinterest", .code = exit.OK } else {
            out.warn(cx, "error: --as must be posted or failed", .{});
            return exit.USAGE;
        }
    } else {
        const tok: []const u8 = switch (auth.ensure(cx, a, cx.live)) {
            .ok => |t| t,
            .fail => |f| {
                out.warn(cx, "error: {s}", .{f.msg});
                return exit.USAGE;
            },
        };
        d = decide(cx, a, &db, row, tok);
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
    const url = if (d.state == .posted and d.pin_id.len > 0) pub_cmd.urlOf(a, cx.cfg.post.url_template, d.pin_id) else "";
    send.setState(cx, &db, row.id, d.state, d.note, d.pin_id, url) catch |e| {
        out.warn(cx, "blocked: {s}", .{if (e == error.Killed) "kill file is on" else @errorName(e)});
        return exit.BLOCKED;
    };
    log.log(cx, "info", "{s} resolved to {s}: {s}", .{ name, send.stateName(d.state), d.note });
    out.json(cx, a, .{ .name = name, .state = send.stateName(d.state), .note = d.note, .written = true });
    return exit.OK;
}
