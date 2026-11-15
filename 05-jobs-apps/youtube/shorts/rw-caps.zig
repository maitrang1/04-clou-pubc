// =====================================================================
// Des: The limits - the Pacific-time day (with US daylight saving), the daily cap, the random gap between sends, the circuit breaker and the stop-for-the-day flag, all counted from the ledger
// Flo: now > Pacific day > read ledger counters > decide go / wait / blocked with a plain reason
// Cre: 2026-11-15                          - | Mod: 2026-11-15
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: Ledger, config limits, now (ms)
// Out: Verdict (go or blocked with a reason) and counters; breaker/stop state written to the ledger kv
// Run: not run directly - imported by cm-publish, cm-status, cm-doctor
// =====================================================================
const std = @import("std");
const util = @import("co-util.zig");
const cfg_mod = @import("co-cfg.zig");
const send = @import("rw-send.zig");

// 0 = Sunday
fn dow(days: i64) i64 {
    return @mod(days + 4, 7);
}

// first Sunday on or after a date
fn firstSunday(y: i64, m: u8) i64 {
    const d = util.daysFromCivil(y, m, 1);
    return d + @mod(7 - dow(d), 7);
}

// seconds to add to UTC for Pacific time: -8h standard, -7h from the 2nd Sunday of March 02:00 to the 1st Sunday of November 02:00
pub fn ptOffsetS(utc_s: i64) i64 {
    const days = @divFloor(utc_s, 86400);
    const y = util.civilFromDays(days).y;
    const start = (firstSunday(y, 3) + 7) * 86400 + 10 * 3600; // 02:00 PST = 10:00 UTC
    const end = firstSunday(y, 11) * 86400 + 9 * 3600; // 02:00 PDT = 09:00 UTC
    return if (utc_s >= start and utc_s < end) -7 * 3600 else -8 * 3600;
}

// Pacific calendar day number (days since 1970-01-01 in Pacific time)
pub fn ptDay(ms: i64) i64 {
    const s = @divFloor(ms, 1000);
    return @divFloor(s + ptOffsetS(s), 86400);
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

// ---- stop for the day (quota / channel limit) ----
pub fn stopSet(l: send.Ledger, day: i64, why: []const u8) send.Err!void {
    try l.kvSetInt("stop_day", day);
    try l.kvSet("stop_why", why);
}

pub fn stopped(l: send.Ledger, today: i64) send.Err!bool {
    return (try l.kvInt("stop_day")) >= today and (try l.kvInt("stop_day")) != 0;
}

// seconds still to wait for the random gap (0 = go). The gap is drawn fresh each run in gap_min..gap_max.
pub fn gapWaitS(l: send.Ledger, now: i64, drawn_s: u64) send.Err!i64 {
    const last = try l.lastStarted();
    if (last == 0) return 0;
    const need: i64 = @intCast(drawn_s);
    const passed = @divFloor(now - last, 1000);
    return if (passed >= need) 0 else need - passed;
}

// one verdict for "may I start a send now" (cap, stop, breaker, gap); order = most blocking first
pub fn mayStart(a: std.mem.Allocator, l: send.Ledger, cfg: cfg_mod.Config, now: i64, drawn_gap_s: u64) send.Err!Verdict {
    const today = ptDay(now);
    if (try breakerOpen(l, cfg.breaker, now)) return .{ .blocked = "breaker open: stop, a person must look (shorts status)" };
    if (try stopped(l, today)) {
        const why = (try l.kvGet(a, "stop_why")) orelse "limit reached";
        return .{ .blocked = try std.fmt.allocPrint(a, "stopped until the next Pacific midnight: {s}", .{why}) };
    }
    const used = try l.countDay(today);
    if (used >= cfg.limits.daily_cap) return .{ .blocked = try std.fmt.allocPrint(a, "daily cap reached ({d} of {d} today, Pacific day)", .{ used, cfg.limits.daily_cap }) };
    const wait = try gapWaitS(l, now, drawn_gap_s);
    if (wait > 0) return .{ .wait = try std.fmt.allocPrint(a, "gap: wait {d}s before the next send", .{wait}) };
    return .go;
}

test "pacific offset around the 2026 and 2025 transitions" {
    const d = util.daysFromCivil;
    // 2026: DST starts Sun Mar 8 at 10:00 UTC, ends Sun Nov 1 at 09:00 UTC
    const s0 = d(2026, 3, 8) * 86400 + 10 * 3600;
    try std.testing.expectEqual(@as(i64, -8 * 3600), ptOffsetS(s0 - 1));
    try std.testing.expectEqual(@as(i64, -7 * 3600), ptOffsetS(s0));
    const e0 = d(2026, 11, 1) * 86400 + 9 * 3600;
    try std.testing.expectEqual(@as(i64, -7 * 3600), ptOffsetS(e0 - 1));
    try std.testing.expectEqual(@as(i64, -8 * 3600), ptOffsetS(e0));
    // 2025: Mar 9 and Nov 2
    try std.testing.expectEqual(@as(i64, -7 * 3600), ptOffsetS(d(2025, 3, 9) * 86400 + 10 * 3600));
    try std.testing.expectEqual(@as(i64, -8 * 3600), ptOffsetS(d(2025, 11, 2) * 86400 + 9 * 3600));
    try std.testing.expectEqual(@as(i64, -7 * 3600), ptOffsetS(d(2026, 7, 4) * 86400));
    try std.testing.expectEqual(@as(i64, -8 * 3600), ptOffsetS(d(2026, 1, 15) * 86400));
}

test "pacific day flips at pacific midnight, not UTC midnight" {
    const d = util.daysFromCivil;
    // July (PDT, -7): 06:59 UTC is still the previous Pacific day, 07:00 UTC is the new one
    const base = d(2026, 7, 10) * 86400;
    try std.testing.expectEqual(d(2026, 7, 9), ptDay((base + 6 * 3600 + 59 * 60) * 1000));
    try std.testing.expectEqual(d(2026, 7, 10), ptDay((base + 7 * 3600) * 1000));
    // January (PST, -8)
    const jb = d(2026, 1, 10) * 86400;
    try std.testing.expectEqual(d(2026, 1, 9), ptDay((jb + 7 * 3600 + 59 * 60) * 1000));
    try std.testing.expectEqual(d(2026, 1, 10), ptDay((jb + 8 * 3600) * 1000));
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
        try l.begin("k1", t0, ptDay(t0), 1, "");
        const v = try mayStart(a, l, cfg, t0 + 60_000, 600);
        try std.testing.expect(v == .wait and std.mem.indexOf(u8, v.wait, "gap") != null);
        try std.testing.expect((try mayStart(a, l, cfg, t0 + 601_000, 600)) == .go);
        try std.testing.expect(try l.insertNew("b", "k2", .ready, "", t0));
        try l.begin("k2", t0 + 700_000, ptDay(t0), 1, "");
    }
    // reopen: the cap still holds
    const l = try tmpL(a, &tmp);
    defer l.close();
    const v = try mayStart(a, l, cfg, t0 + 2_000_000, 1);
    try std.testing.expect(v == .blocked and std.mem.indexOf(u8, v.blocked, "daily cap") != null);
    // next Pacific day: free again
    try std.testing.expect((try mayStart(a, l, cfg, t0 + 24 * 3600 * 1000, 1)) == .go);
}

test "breaker opens after N fails, cools down, hard trip needs a reset; stop holds until next day" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const l = try tmpL(a, &tmp);
    defer l.close();
    const c: cfg_mod.Breaker = .{ .fails = 2, .cool_h = 1 };
    const now: i64 = 1_800_000_000_000;
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
    try stopSet(l, ptDay(now), "quotaExceeded");
    try std.testing.expect(try stopped(l, ptDay(now)));
    try std.testing.expect(!(try stopped(l, ptDay(now) + 1)));
    const v = try mayStart(a, l, .{}, now, 0);
    try std.testing.expect(v == .blocked and std.mem.indexOf(u8, v.blocked, "quotaExceeded") != null);
}
// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
