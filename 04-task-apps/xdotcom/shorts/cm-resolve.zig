// =====================================================================
// Des: The resolve command - settles an unsure (or crashed) send by asking YouTube whether the video exists: ask the session, then the video id, then the channel's newest uploads by title and time; it never uploads again
// Flo: find the row > ask session > videos.list by id > uploads list match > posted (live) or still unsure
// Cre: 2026-11-15                          - | Mod: 2026-11-15
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: resolve --video NAME [--live]
// Out: one line; exit 0 settled · 5 still unsure · 2 usage · 3 blocked
// Run: /home/mai_trang/04-clou-base/04-task-apps/youtube/shorts/zig-out/bin/shorts resolve --video NAME --live
// =====================================================================
const std = @import("std");
const ctx_mod = @import("co-ctx.zig");
const util = @import("co-util.zig");
const args = @import("co-args.zig");
const exit = @import("co-exit.zig");
const kill = @import("co-kill.zig");
const lock = @import("co-lock.zig");
const log = @import("co-log.zig");
const send = @import("rw-send.zig");
const call = @import("ap-call.zig");
const upload = @import("ap-upload.zig");
const status = @import("ap-status.zig");
const list = @import("ap-list.zig");

// "2026-11-15T01:02:03Z" for a ms timestamp, minus a safety margin for clock skew
fn isoMinus(buf: []u8, ms: i64, margin_s: i64) []const u8 {
    const t = util.fmtTs(buf, ms - margin_s * 1000, 0);
    if (t.len < 19) return "";
    buf[10] = 'T';
    buf[19] = 'Z';
    return buf[0..20];
}

fn blocked(cx: *const ctx_mod.Ctx, what: []const u8, why: []const u8) u8 {
    util.eprint(cx.io, "blocked: {s}\nwhy: {s}\nfix: shorts doctor\n", .{ what, why });
    return exit.blocked;
}

pub fn run(cx: *const ctx_mod.Ctx, av: []const []const u8) u8 {
    var arena = std.heap.ArenaAllocator.init(cx.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const live = args.has(av, "--live");
    const name = args.value(av, "--video") orelse {
        util.eprint(cx.io, "error: --video NAME is required\nwhy: resolve settles one video\nfix: shorts resolve --video NAME\n", .{});
        return exit.usage;
    };
    if (live and kill.isOn(cx, a)) return blocked(cx, "kill file is on", "every write is refused");
    const lk = lock.take(cx, a) catch return blocked(cx, "another run is active", "the run lock is held");
    defer lk.release();
    const l = send.Ledger.open(cx, a) catch return blocked(cx, "the ledger cannot be opened", "check the data folder");
    defer l.close();
    const row = (l.findName(a, name) catch return blocked(cx, "the ledger cannot be read", "check the data folder")) orelse {
        util.eprint(cx.io, "error: no ledger row for {s}\nwhy: it was never sent from here\nfix: shorts scan\n", .{name});
        return exit.usage;
    };
    if (row.state == .posted) {
        util.print(cx.io, "nothing to do: {s} is already posted {s}\n", .{ name, row.url });
        return exit.nothing;
    }
    const open_send = row.state == .unsure or row.state == .sending or (row.state == .failed and row.session_uri.len > 0);
    if (!open_send) {
        util.eprint(cx.io, "nothing to do: {s} is {s}\nwhy: resolve settles only unsure, crashed, or failed-after-upload sends\nfix: shorts scan\n", .{ name, row.state.name() });
        return exit.nothing;
    }
    var tok = call.Tok.init(cx, a) catch |e| {
        util.eprint(cx.io, "error: sign-in failed ({s})\nwhy: cannot ask YouTube\nfix: shorts token\n", .{@errorName(e)});
        return exit.blocked;
    };
    l.kvSetInt("token_ok", cx.nowMs()) catch {};
    var found_id: []const u8 = "";
    var how: []const u8 = "";
    // 1. the upload session remembers a finished upload
    if (row.session_uri.len > 0) switch (upload.ask(&tok, row.session_uri, @intCast(row.bytes))) {
        .done => |id| {
            found_id = id;
            how = "the upload session reports it finished";
        },
        else => {},
    };
    // 2. a known video id
    if (found_id.len == 0 and row.video_id.len > 0) switch (status.video(&tok, row.video_id)) {
        .ok => |v| if (v.found) {
            found_id = row.video_id;
            how = "the video id exists";
        },
        else => {},
    };
    // 3. the channel's newest uploads: same title, published after the send began
    if (found_id.len == 0) switch (list.channel(&tok)) {
        .ok => |ch| if (ch.uploads.len > 0) switch (list.uploads(&tok, ch.uploads)) {
            .ok => |ups| {
                var bb: [32]u8 = undefined;
                const since = isoMinus(&bb, if (row.started > 0) row.started else row.created, 120);
                for (ups) |u| {
                    if (std.mem.eql(u8, u.title, row.title) and std.mem.order(u8, u.published_at, since) != .lt) {
                        found_id = u.video_id;
                        how = "same title in the channel's uploads, published after the send began";
                        break;
                    }
                }
            },
            else => {},
        },
        else => {},
    };
    if (found_id.len == 0) {
        util.print(cx.io, "still unsure: {s} was not found on the channel\nwhy: the send may not have reached YouTube, or it is not visible yet\nfix: check YouTube Studio by hand; to send again on purpose: shorts approve --video {s} --resend --live\n", .{ name, name });
        return exit.unsure;
    }
    const url = std.fmt.allocPrint(a, "{s}{s}", .{ cx.cfg.google.watch_url, found_id }) catch "";
    if (!live) {
        util.print(cx.io, "dry run: {s} IS on YouTube ({s}). Would mark it posted {s}. Add --live to write.\n", .{ name, how, url });
        return exit.ok;
    }
    l.setPosted(row.pkey, found_id, url, "settled by resolve", cx.nowMs()) catch return blocked(cx, "the ledger cannot be written", "check the data folder");
    log.line(cx, "INFO", "resolve {s}: posted as {s} ({s})", .{ name, found_id, how });
    util.print(cx.io, "settled: {s} is posted {s} ({s})\n", .{ name, url, how });
    return exit.ok;
}
// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
