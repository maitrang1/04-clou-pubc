// =====================================================================
// Des: The status command - counts by state, today's sends against the cap (Pacific day), the breaker and the daily stop, the age of the last sign-in, and the list of held videos; changes nothing
// Flo: open ledger > read counts, day counter, kv flags > scan folder for held ones > print
// Cre: 2026-11-15                          - | Mod: 2026-11-15
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: status [--json]
// Out: lines or one JSON object; exit 0 (3 when the ledger cannot be read)
// Run: /home/mai_trang/04-clou-base/05-jobs-apps/vimeo/shorts/zig-out/bin/shorts status
// =====================================================================
const std = @import("std");
const ctx_mod = @import("co-ctx.zig");
const util = @import("co-util.zig");
const exit = @import("co-exit.zig");
const send = @import("rw-send.zig");
const caps = @import("rw-caps.zig");
const pair = @import("rw-pair.zig");
const pick = @import("rw-pick.zig");
const kill = @import("co-kill.zig");

pub fn run(cx: *const ctx_mod.Ctx, _: []const []const u8, json: bool) u8 {
    var arena = std.heap.ArenaAllocator.init(cx.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const l = send.Ledger.open(cx, a) catch {
        util.eprint(cx.io, "error: the ledger cannot be opened\nwhy: {s}/{s}\nfix: shorts doctor\n", .{ cx.data_dir, cx.cfg.db_file });
        return exit.blocked;
    };
    defer l.close();
    const now = cx.nowMs();
    const day = caps.ptDay(now);
    const counts = l.counts() catch [_]u32{0} ** 6;
    const used = l.countDay(day) catch 0;
    const open = caps.breakerOpen(l, cx.cfg.breaker, now) catch true;
    const hard = (l.kvInt("breaker_hard") catch 0) != 0;
    const stopped = caps.stopped(l, day) catch true;
    const tok_ms = l.kvInt("token_ok") catch 0;
    const tok_days: i64 = if (tok_ms == 0) -1 else @divFloor(now - tok_ms, 86_400_000);
    const killed = kill.isOn(cx, a);
    var held: std.ArrayList([]const u8) = .empty;
    if (pair.scan(cx, a)) |items| {
        for (items) |it| {
            const row = l.find(a, it.pkey) catch null;
            if (pick.kindOf(it, row) == .held) held.append(a, it.name) catch {};
        }
    } else |_| {}
    const stale_tok = tok_days < 0 or tok_days >= cx.cfg.token_warn_days;
    if (json) {
        const J = struct { ready: u32, held: u32, sending: u32, posted: u32, failed: u32, unsure: u32, today: u32, cap: u32, breaker_open: bool, breaker_hard: bool, stopped_today: bool, kill_file: bool, token_days_since_ok: i64, held_names: []const []const u8 };
        const s = util.jsonStr(a, J{ .ready = counts[0], .held = counts[1], .sending = counts[2], .posted = counts[3], .failed = counts[4], .unsure = counts[5], .today = used, .cap = cx.cfg.limits.daily_cap, .breaker_open = open, .breaker_hard = hard, .stopped_today = stopped, .kill_file = killed, .token_days_since_ok = tok_days, .held_names = held.items }) catch return exit.failed;
        util.printAll(cx.io, s);
        util.printAll(cx.io, "\n");
        return exit.ok;
    }
    util.print(cx.io, "ledger: {d} ready · {d} held · {d} sending · {d} posted · {d} failed · {d} unsure\n", .{ counts[0], counts[1], counts[2], counts[3], counts[4], counts[5] });
    util.print(cx.io, "today (Pacific day): {d} of {d} sends\n", .{ used, cx.cfg.limits.daily_cap });
    util.print(cx.io, "breaker: {s}{s} · daily stop: {s} · kill file: {s}\n", .{ if (open) "OPEN" else "closed", if (hard) " (needs a person: shorts config --reset-breaker --live)" else "", if (stopped) "yes, until the next Pacific midnight" else "no", if (killed) "ON" else "off" });
    if (tok_days < 0) util.print(cx.io, "sign-in: never checked here (run: shorts token)\n", .{}) else util.print(cx.io, "sign-in: last worked {d} days ago{s}\n", .{ tok_days, if (stale_tok) " (WARNING: older than token_warn_days; run: shorts token)" else "" });
    if (held.items.len > 0) {
        util.print(cx.io, "held for a person ({d}):", .{held.items.len});
        for (held.items) |h| util.print(cx.io, " {s}", .{h});
        util.print(cx.io, "\n", .{});
    }
    if (counts[5] > 0) util.print(cx.io, "NOTE: {d} unsure video(s): run shorts resolve --video NAME\n", .{counts[5]});
    return exit.ok;
}
// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
