// =====================================================================
// Des: The limits - the rolling 24 hour cap, the random gap between sends, the rolling 30 day budget guard, the circuit breaker, the stop-until window (rate limit, spending limit) and the rate headers seen last, all counted from the ledger
// Flo: now > read ledger counters > decide go / wait / blocked with a plain reason; a cap that cannot be counted stops the run
// Cre: 2026-11-16                          - | Mod: 2026-11-16
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: Ledger, config limits and cost, now (ms), the cost of the next send
// Out: Verdict (go, wait or blocked with a reason) and counters; breaker, stop and rate state written to the ledger kv
// Run: not run directly - imported by cm-publish, cm-status, cm-doctor
// =====================================================================
const std = @import("std");
const cfg_mod = @import("co-cfg.zig");
const send = @import("rw-send.zig");

pub const day_ms: i64 = 24 * 3600 * 1000;
pub const budget_days: i64 = 30;

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

// open at once and stay open until a person resets it (account trouble, credits, a refused post)
pub fn breakerHard(l: send.Ledger, why: []const u8) send.Err!void {
    try l.kvSetInt("breaker_hard", 1);
    try l.kvSet("breaker_why", why);
}

pub fn breakerReset(l: send.Ledger) send.Err!void {
    try l.kvSetInt("breaker_hard", 0);
    try l.kvSetInt("breaker_fails", 0);
}

// ---- stop until a time (rate limit window, spending limit) ----
pub fn stopSet(l: send.Ledger, until_ms: i64, why: []const u8) send.Err!void {
    try l.kvSetInt("stop_until", until_ms);
    try l.kvSet("stop_why", why);
}

pub fn stopped(l: send.Ledger, now: i64) send.Err!bool {
    const u = try l.kvInt("stop_until");
    return u != 0 and now < u;
}

// ---- rate headers seen last (x-rate-limit-remaining / -reset) ----
pub fn rateSave(l: send.Ledger, remaining: i64, reset_s: i64) send.Err!void {
    try l.kvSetInt("rate_remaining", remaining);
    try l.kvSetInt("rate_reset_ms", reset_s * 1000);
}

// true = the last answer said "almost out" and its window is still open
pub fn rateLow(l: send.Ledger, margin: u32, now: i64) send.Err!bool {
    const reset = try l.kvInt("rate_reset_ms");
    if (reset == 0 or now >= reset) return false;
    if ((try l.kvInt("rate_seen")) == 0) return false;
    return (try l.kvInt("rate_remaining")) <= @as(i64, margin);
}

pub fn rateNote(l: send.Ledger, remaining: i64, reset_s: i64) send.Err!void {
    try l.kvSetInt("rate_seen", 1);
    try rateSave(l, remaining, reset_s);
}

// seconds still to wait for the random gap (0 = go). The gap is drawn fresh each run in gap_min..gap_max.
pub fn gapWaitS(l: send.Ledger, now: i64, drawn_s: u64) send.Err!i64 {
    const last = try l.lastStarted();
    if (last == 0) return 0;
    const need: i64 = @intCast(drawn_s);
    const passed = @divFloor(now - last, 1000);
    return if (passed >= need) 0 else need - passed;
}

pub fn usd(e6: i64) f64 {
    return @as(f64, @floatFromInt(e6)) / 1_000_000.0;
}

pub fn toE6(v: f64) i64 {
    return @intFromFloat(@round(v * 1_000_000.0));
}

// estimated cost of one send in millionths of a dollar: post (with or without a URL) + upload
pub fn sendCostE6(c: cfg_mod.Cost, has_url: bool) i64 {
    return toE6((if (has_url) c.post_url_usd else c.post_usd) + c.media_usd);
}

// one verdict for "may I start a send now" (breaker, stop, rate, cap, budget, gap); order = most blocking first
pub fn mayStart(a: std.mem.Allocator, l: send.Ledger, cfg: cfg_mod.Config, now: i64, drawn_gap_s: u64, next_cost_e6: i64) send.Err!Verdict {
    if (try breakerOpen(l, cfg.breaker, now)) return .{ .blocked = "breaker open: stop, a person must look (shorts status)" };
    if (try stopped(l, now)) {
        const why = (try l.kvGet(a, "stop_why")) orelse "limit reached";
        return .{ .blocked = try std.fmt.allocPrint(a, "stopped for now: {s}", .{why}) };
    }
    if (try rateLow(l, cfg.limits.rate_margin, now)) return .{ .blocked = "X rate limit nearly used up (x-rate-limit-remaining); wait for its window to reset" };
    const used = try l.countSince(now - day_ms);
    if (used >= cfg.limits.daily_cap) return .{ .blocked = try std.fmt.allocPrint(a, "daily cap reached ({d} of {d} in the last 24 hours)", .{ used, cfg.limits.daily_cap }) };
    const spent = try l.spendSince(now - budget_days * day_ms);
    const cap_e6 = toE6(cfg.limits.budget_usd);
    if (spent + next_cost_e6 > cap_e6) return .{ .blocked = try std.fmt.allocPrint(a, "budget reached (about ${d:.3} spent in 30 days + ${d:.3} next, limit ${d:.2}): this is an estimate, not the invoice", .{ usd(spent), usd(next_cost_e6), cfg.limits.budget_usd }) };
    const wait = try gapWaitS(l, now, drawn_gap_s);
    if (wait > 0) return .{ .wait = try std.fmt.allocPrint(a, "gap: wait {d}s before the next send", .{wait}) };
    return .go;
}

fn tmpL(a: std.mem.Allocator, tmp: *std.testing.TmpDir) !send.Ledger {
    return send.Ledger.openPath(try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/c.db", .{&tmp.sub_path}));
}

test "cap counts the last 24 hours, survives reopen, gap blocks then frees" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var cfg: cfg_mod.Config = .{};
    cfg.limits.daily_cap = 2;
    const t0: i64 = 1_800_000_000_000;
    {
        const l = try tmpL(a, &tmp);
        defer l.close();
        try std.testing.expect((try mayStart(a, l, cfg, t0, 600, 0)) == .go);
        try std.testing.expect(try l.insertNew("a", "k1", .ready, "", t0));
        try l.begin("k1", t0, 1, "");
        const v = try mayStart(a, l, cfg, t0 + 60_000, 600, 0);
        try std.testing.expect(v == .wait and std.mem.indexOf(u8, v.wait, "gap") != null);
        try std.testing.expect((try mayStart(a, l, cfg, t0 + 601_000, 600, 0)) == .go);
        try std.testing.expect(try l.insertNew("b", "k2", .ready, "", t0));
        try l.begin("k2", t0 + 700_000, 1, "");
    }
    // reopen: the cap still holds
    const l = try tmpL(a, &tmp);
    defer l.close();
    const v = try mayStart(a, l, cfg, t0 + 2_000_000, 1, 0);
    try std.testing.expect(v == .blocked and std.mem.indexOf(u8, v.blocked, "daily cap") != null);
    // a rolling window: 24 h after the first send it frees one slot, not both
    try std.testing.expect((try mayStart(a, l, cfg, t0 + day_ms + 1000, 1, 0)) == .go);
}

test "breaker opens after N fails, cools down, hard trip needs a reset; the stop window holds then ends" {
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
    try breakerHard(l, "credits");
    try std.testing.expect(try breakerOpen(l, c, now + 10 * 3_600_000));
    try breakerReset(l);
    try std.testing.expect(!(try breakerOpen(l, c, now + 10 * 3_600_000)));
    try stopSet(l, now + 900_000, "rate limit window");
    try std.testing.expect(try stopped(l, now));
    try std.testing.expect(!(try stopped(l, now + 900_001)));
    const v = try mayStart(a, l, .{}, now, 0, 0);
    try std.testing.expect(v == .blocked and std.mem.indexOf(u8, v.blocked, "rate limit window") != null);
}

test "rate headers: low remaining blocks only while its window is open" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const l = try tmpL(a, &tmp);
    defer l.close();
    const now: i64 = 1_800_000_000_000;
    try std.testing.expect(!(try rateLow(l, 5, now)));
    try rateNote(l, 3, @divFloor(now, 1000) + 600);
    try std.testing.expect(try rateLow(l, 5, now));
    try std.testing.expect(!(try rateLow(l, 5, now + 601_000)));
    try rateNote(l, 50, @divFloor(now, 1000) + 600);
    try std.testing.expect(!(try rateLow(l, 5, now)));
}

test "budget guard: a URL post costs 13 times more and the window counts only 30 days" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const l = try tmpL(a, &tmp);
    defer l.close();
    var cfg: cfg_mod.Config = .{};
    cfg.limits.budget_usd = 0.25;
    const now: i64 = 1_800_000_000_000;
    try std.testing.expectEqual(@as(i64, 15_000), sendCostE6(cfg.cost, false));
    try std.testing.expectEqual(@as(i64, 200_000), sendCostE6(cfg.cost, true));
    // a plain post fits, a URL post would still fit once, then not
    try std.testing.expect((try mayStart(a, l, cfg, now, 0, sendCostE6(cfg.cost, true))) == .go);
    try std.testing.expect(try l.insertNew("a", "k1", .ready, "", now));
    try l.begin("k1", now - 1000, 1, "");
    try l.setCost("k1", sendCostE6(cfg.cost, true));
    const v = try mayStart(a, l, cfg, now, 0, sendCostE6(cfg.cost, true));
    try std.testing.expect(v == .blocked and std.mem.indexOf(u8, v.blocked, "budget") != null);
    try std.testing.expect((try mayStart(a, l, cfg, now, 0, sendCostE6(cfg.cost, false))) == .go);
    // 31 days later the old spend has left the window
    try std.testing.expect((try mayStart(a, l, cfg, now + 31 * day_ms, 0, sendCostE6(cfg.cost, true))) == .go);
}
// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
