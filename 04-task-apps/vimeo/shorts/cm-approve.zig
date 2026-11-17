// =====================================================================
// Des: The approve and hold commands - a person's decision on a video: approve lets a review video (or a failed one) be sent, hold parks it; an unsure video needs the explicit --resend; dry run unless --live
// Flo: kill? > lock > ledger > find the video > allowed move? > write the row (live) or say what would change
// Cre: 2026-11-15                          - | Mod: 2026-11-15
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: approve|hold --video NAME [--live] [--resend]
// Out: one line; exit 0 ok · 2 usage · 3 blocked or not allowed
// Run: /home/mai_trang/04-clou-base/04-task-apps/vimeo/shorts/zig-out/bin/shorts approve --video NAME --live
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
const pair = @import("rw-pair.zig");
const pick = @import("rw-pick.zig");

fn refuse(cx: *const ctx_mod.Ctx, what: []const u8, why: []const u8) u8 {
    util.eprint(cx.io, "blocked: {s}\nwhy: {s}\nfix: shorts scan\n", .{ what, why });
    return exit.blocked;
}

pub fn run(cx: *const ctx_mod.Ctx, av: []const []const u8, approve: bool) u8 {
    var arena = std.heap.ArenaAllocator.init(cx.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const live = args.has(av, "--live");
    const name = args.value(av, "--video") orelse {
        util.eprint(cx.io, "error: --video NAME is required\nwhy: a decision is about one video\nfix: shorts {s} --video NAME\n", .{if (approve) "approve" else "hold"});
        return exit.usage;
    };
    if (live and kill.isOn(cx, a)) return refuse(cx, "kill file is on", "every write is refused");
    const lk = lock.take(cx, a) catch return refuse(cx, "another run is active", "the run lock is held");
    defer lk.release();
    const l = send.Ledger.open(cx, a) catch return refuse(cx, "the ledger cannot be opened", "check the data folder");
    defer l.close();
    const items = pair.scan(cx, a) catch {
        util.eprint(cx.io, "error: source.dir is empty or unreadable\nwhy: cannot find the video\nfix: set source.dir in the config\n", .{});
        return exit.usage;
    };
    const it = pick.byName(items, name) orelse {
        util.eprint(cx.io, "error: no video named {s}\nwhy: not in source.dir\nfix: shorts scan\n", .{name});
        return exit.usage;
    };
    if (it.status != .ready) return refuse(cx, "that video cannot be sent", it.reason);
    const row = l.find(a, it.pkey) catch return refuse(cx, "the ledger cannot be read", "check the data folder");
    const now = cx.nowMs();
    const want: send.State = if (approve) .ready else .held;
    if (row) |r| {
        if (r.state == want) {
            util.print(cx.io, "nothing to do: {s} is already {s}\n", .{ name, if (approve) "approved" else "held" });
            return exit.nothing;
        }
        switch (r.state) {
            .sending, .posted => return refuse(cx, "that video is already sent or being sent", "approve and hold do not apply"),
            .unsure => {
                if (!approve) return refuse(cx, "an unsure video cannot be held", "run: shorts resolve --video NAME");
                if (!args.has(av, "--resend")) return refuse(cx, "that video is unsure: it may already be on Vimeo", "run shorts resolve first; to send it again anyway add --resend (a duplicate is possible)");
            },
            .failed => {
                if (!approve) return refuse(cx, "a failed video cannot be held", "approve it to queue it again");
                // bytes may have gone before it failed: it could already be on Vimeo
                if (r.upload_link.len > 0 and !args.has(av, "--resend")) return refuse(cx, "that video failed after its upload started: it may be on Vimeo", "run shorts resolve first; to send it again anyway add --resend (a duplicate is possible)");
            },
            .held, .ready => {},
        }
    }
    if (!live) {
        util.print(cx.io, "dry run: would set {s} to {s}. Add --live to write.\n", .{ name, want.name() });
        return exit.ok;
    }
    if (row == null) {
        _ = l.insertNew(it.name, it.pkey, want, "", now) catch return refuse(cx, "the ledger cannot be written", "check the data folder");
    } else {
        l.setState(it.pkey, want, if (approve) "approved by a person" else "held by a person", now) catch return refuse(cx, "the ledger cannot be written", "check the data folder");
    }
    log.line(cx, "INFO", "{s} {s}", .{ if (approve) "approve" else "hold", name });
    util.print(cx.io, "{s}: {s} is now {s}\n", .{ if (approve) "approved" else "held", name, want.name() });
    return exit.ok;
}
// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
