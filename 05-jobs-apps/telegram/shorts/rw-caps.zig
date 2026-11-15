// =====================================================================
// Des: The limits - the local calendar day (tz_offset_hours), the daily cap, the random gap between sends, the circuit breaker and the flood wait (Telegram 429), all counted from the ledger
// Flo: now > local day > read ledger counters > decide go / wait / blocked with a plain reason
// Cre: 2026-11-16                          - | Mod: 2026-11-16
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: Ledger, config limits, now (ms)
// Out: Verdict (go or blocked with a reason) and counters; breaker/flood state written to the ledger kv
// Run: not run directly - imported by cm-publish, cm-status, cm-doctor
// =====================================================================
const std = @import("std");
const util = @import("co-util.zig");
const cfg_mod = @import("co-cfg.zig");
const send = @import("rw-send.zig");

// local calendar day number (days since 1970-01-01 at tz_offset_hours); Telegram has no quota day, so the cap follows the owner's day
pub fn localDay(ms: i64, tz_h: i32) i64 {
    const s = @divFloor(ms, 1000) + @as(i64, tz_h) * 3600;
    return @divFloor(s, 86400);
}

// go | wait (the random gap: nothing to do right now) | blocked (a limit or the breaker: a message for a person)
pub const Verdict = union(enum) { go, wait: []const u8, blocked: []const u8 };

// ---- breaker ----
pub fn breakerOpen(l: send.Ledger, c: cfg_mod.Breaker, now: i64) send.Err!bool {
    if ((try l.kvInt("breaker_hard")) != 0) return true;
    const fails = try l.kvInt("breaker_fails");
    if (fails < c.fails) return false;
    return now - (try l.kvInt("breaker_opened")) < @as(i64, c.cool_h) * 3600 * 1000;
}

pub fn breakerFail(l: send.Ledger, now: i64) send.Err!void {
    try l.kvSetInt("breaker_fails", (try l.kvInt("breaker_fails")) + 1);
    try l.kvSetInt("breaker_opened", now);
}

pub fn breakerOk(l: send.Ledger) send.Err!void {
    try l.kvSetInt("breaker_fails", 0);
}

// open at once and stay open until a person resets it (forbidden, rejected video)
pub fn breakerHard(l: send.Ledger, why: []const u8) send.Err!void {
    try l.kvSetInt("breaker_hard", 1);
    try l.kvSet("breaker_why", why);
}

pub fn breakerReset(l: send.Ledger) send.Err!void {
    try l.kvSetInt("breaker_hard", 0);
    try l.kvSetInt("breaker_fails", 0);
}

// ---- flood wait (Telegram 429 retry_after): nothing is sent until this moment, kept across restarts ----
pub fn floodSet(l: send.Ledger, until_ms: i64) send.Err!void {
    try l.kvSetInt("blocked_until", until_ms);
}

pub fn floodUntil(l: send.Ledger, now: i64) send.Err!i64 {
    const u = try l.kvInt("blocked_until");
    return if (u > now) u else 0;
}

// seconds still to wait for the random gap (0 = go). The gap is drawn fresh each run in gap_min..gap_max.
pub fn gapWaitS(l: send.Ledger, now: i64, drawn_s: u64) send.Err!i64 {
    const last = try l.lastStarted();
    if (last == 0) return 0;
    const need: i64 = @intCast(drawn_s);
    const passed = @divFloor(now - last, 1000);
    return if (passed >= need) 0 else need - passed;
}

// one verdict for "may I start a send now" (breaker, flood, cap, gap); order = most blocking first
pub fn mayStart(a: std.mem.Allocator, l: send.Ledger, cfg: cfg_mod.Config, now: i64, drawn_gap_s: u64) send.Err!Verdict {
    const today = localDay(now, cfg.tz_offset_hours);
    if (try breakerOpen(l, cfg.breaker, now)) return .{ .blocked = "breaker open: stop, a person must look (shorts status)" };
    const fl = try floodUntil(l, now);
    if (fl > 0) return .{ .blocked = try std.fmt.allocPrint(a, "Telegram flood wait: {d}s left (it asked us to slow down)", .{@divFloor(fl - now, 1000) + 1}) };
    const used = try l.countDay(today);
    if (used >= cfg.limits.daily_cap) return .{ .blocked = try std.fmt.allocPrint(a, "daily cap reached ({d} of {d} today, local day)", .{ used, cfg.limits.daily_cap }) };
    const wait = try gapWaitS(l, now, drawn_gap_s);
    if (wait > 0) return .{ .wait = try std.fmt.allocPrint(a, "gap: wait {d}s before the next send", .{wait}) };
    return .go;
}

test "local day flips at local midnight" {
    const d = util.daysFromCivil;
    const base = d(2026, 7, 10) * 86400;
    // UTC+7: 16:59 UTC is 23:59 local (same day), 17:00 UTC is the next local day
    try std.testing.expectEqual(d(2026, 7, 10), localDay((base + 16 * 3600 + 59 * 60) * 1000, 7));
    try std.testing.expectEqual(d(2026, 7, 11), localDay((base + 17 * 3600) * 1000, 7));
    // UTC-8: 07:59 UTC is still the day before
    try std.testing.expectEqual(d(2026, 7, 9), localDay((base + 7 * 3600 + 59 * 60) * 1000, -8));
    try std.testing.expectEqual(d(2026, 7, 10), localDay((base + 8 * 3600) * 1000, -8));
}

fn tmpL(a: std.mem.Allocator, tmp: *std.testing.TmpDir) !send.Ledger {
    return send.Ledger.openPath(try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/c.db", .{&tmp.sub_path}));
}

test "cap counts today's sends, survives reopen, gap blocks then frees" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var cfg: cfg_mod.Config = .{};
    cfg.limits.daily_cap = 2;
    const t0: i64 = util.daysFromCivil(2026, 7, 10) * 86400 * 1000 + 12 * 3600 * 1000;
    {
        const l = try tmpL(a, &tmp);
        defer l.close();
        try std.testing.expect((try mayStart(a, l, cfg, t0, 600)) == .go);
        try std.testing.expect(try l.insertNew("a", "k1", .ready, "", t0));
        try l.begin("k1", t0, localDay(t0, 7), 1, "", "test");
        const v = try mayStart(a, l, cfg, t0 + 60_000, 600);
        try std.testing.expect(v == .wait and std.mem.indexOf(u8, v.wait, "gap") != null);
        try std.testing.expect((try mayStart(a, l, cfg, t0 + 601_000, 600)) == .go);
        try std.testing.expect(try l.insertNew("b", "k2", .ready, "", t0));
        try l.begin("k2", t0 + 700_000, localDay(t0, 7), 1, "", "test");
    }
    // reopen: the cap still holds
    const l = try tmpL(a, &tmp);
    defer l.close();
    const v = try mayStart(a, l, cfg, t0 + 2_000_000, 1);
    try std.testing.expect(v == .blocked and std.mem.indexOf(u8, v.blocked, "daily cap") != null);
    // next local day: free again
    try std.testing.expect((try mayStart(a, l, cfg, t0 + 24 * 3600 * 1000, 1)) == .go);
}

test "breaker opens after N fails, cools down, hard trip needs a reset; the flood wait holds until its moment and survives a reopen" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const c: cfg_mod.Breaker = .{ .fails = 2, .cool_h = 1 };
    const now: i64 = 1_800_000_000_000;
    {
        const l = try tmpL(a, &tmp);
        defer l.close();
        try std.testing.expect(!(try breakerOpen(l, c, now)));
        try breakerFail(l, now);
        try std.testing.expect(!(try breakerOpen(l, c, now)));
        try breakerFail(l, now);
        try std.testing.expect(try breakerOpen(l, c, now + 1000));
        try std.testing.expect(!(try breakerOpen(l, c, now + 3_600_001)));
        try breakerOk(l);
        try breakerHard(l, "forbidden");
        try std.testing.expect(try breakerOpen(l, c, now + 10 * 3_600_000));
        try breakerReset(l);
        try std.testing.expect(!(try breakerOpen(l, c, now + 10 * 3_600_000)));
        try floodSet(l, now + 90_000);
    }
    const l = try tmpL(a, &tmp); // reopened: the flood wait is still there
    defer l.close();
    const v = try mayStart(a, l, .{}, now + 1000, 0);
    try std.testing.expect(v == .blocked and std.mem.indexOf(u8, v.blocked, "flood wait") != null);
    try std.testing.expect((try mayStart(a, l, .{}, now + 91_000, 0)) == .go);
}
// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
