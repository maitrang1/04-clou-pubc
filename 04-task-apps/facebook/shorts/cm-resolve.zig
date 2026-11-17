// resolve: settle an `unsure` send by asking Facebook (status, then the Page's reel list). NEVER re-sends. A person can also answer: --as posted|failed.
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

const Decision = struct { state: send.State, note: []const u8, code: u8 };

fn decide(cx: *Ctx, a: std.mem.Allocator, row: send.Row, tok: []const u8, page: []const u8) Decision {
    const keep = Decision{ .state = .unsure, .note = "Facebook cannot confirm yet: wait a few minutes and run resolve again", .code = exit.UNSURE };
    if (row.video_id.len == 0) return .{ .state = .failed, .note = "no video id was ever issued: nothing could have been published", .code = exit.OK };
    switch (st_api.get(cx, a, tok, row.video_id)) {
        .fail => |f| return .{ .state = .unsure, .note = std.fmt.allocPrint(a, "could not ask Facebook ({s}): try again", .{f.info.msg}) catch "could not ask Facebook", .code = exit.UNSURE },
        .ok => |s| switch (st_api.verdict(s)) {
            .published => return .{ .state = .posted, .note = "Facebook shows it published", .code = exit.OK },
            .draft => return .{ .state = .posted, .note = "Facebook shows it saved as a DRAFT", .code = exit.OK },
            .failed, .expired => return .{ .state = .failed, .note = std.fmt.allocPrint(a, "Facebook says it failed: {s}{s}", .{ s.proc_err, s.pub_err }) catch "Facebook says it failed", .code = exit.OK },
            .uploaded, .processing, .uploading, .unknown => {
                if (row.finish_at == 0) return .{ .state = .failed, .note = "finish was never sent: nothing is published, safe to send again with --again", .code = exit.OK };
                const since = @divTrunc(row.created, 1000) - 3600;
                switch (list_api.list(cx, a, tok, page, since)) {
                    .ok => |items| {
                        for (items) |it| if (std.mem.eql(u8, it.id, row.video_id)) return .{ .state = .posted, .note = "found in the Page's reel list", .code = exit.OK };
                        return keep;
                    },
                    .fail => return keep,
                }
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
        if (std.mem.eql(u8, as, "posted")) d = .{ .state = .posted, .note = "a person confirmed it is on the Page", .code = exit.OK } else if (std.mem.eql(u8, as, "failed")) d = .{ .state = .failed, .note = "a person confirmed it is not on the Page", .code = exit.OK } else {
            out.warn(cx, "error: --as must be posted or failed", .{});
            return exit.USAGE;
        }
    } else {
        const tok = cx.pageToken() orelse {
            out.warn(cx, "error: no Page token (env var or file named in config)", .{});
            return exit.USAGE;
        };
        const page = cx.pageId() orelse {
            out.warn(cx, "error: no Page id (env var or file named in config)", .{});
            return exit.USAGE;
        };
        d = decide(cx, a, row, tok, page);
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
    const url = if (d.state == .posted and row.url.len == 0) std.fmt.allocPrint(a, "{s}/{s}", .{ std.mem.trimEnd(u8, cx.cfg.post.reel_url_base, "/"), row.video_id }) catch "" else "";
    send.setState(cx, &db, row.id, d.state, d.note, "", url) catch |e| {
        out.warn(cx, "blocked: {s}", .{if (e == error.Killed) "kill file is on" else @errorName(e)});
        return exit.BLOCKED;
    };
    log.log(cx, "info", "{s} resolved to {s}: {s}", .{ name, send.stateName(d.state), d.note });
    out.json(cx, a, .{ .name = name, .state = send.stateName(d.state), .note = d.note, .written = true });
    return exit.OK;
}
