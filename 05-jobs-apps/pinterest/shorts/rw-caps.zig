// Caps, gap, breaker, quota blocks. All state lives in the ledger (meta table), so it survives restarts. A ledger that cannot be read stops the run (a cap that fails open is no cap).
const std = @import("std");
const sq = @import("rw-sqlite.zig");
const send = @import("rw-send.zig");
const Ctx = @import("co-ctx.zig").Ctx;
const net = @import("co-net.zig");

const CF = .{ .day_ms = 24 * 3600 * 1000, .h_ms = 3600 * 1000 };

pub const Block = struct { why: []const u8 };

// first reason the run must not send now, or null
pub fn blocked(cx: *const Ctx, db: *sq.Db, a: std.mem.Allocator) send.Err!?Block {
    const now = cx.nowMs();
    if (try send.metaInt(db, "brk_hard") != 0) return .{ .why = "breaker open: Pinterest refused the action (HTTP 403). A person must look, then run: config --reset-breaker --live" };
    const until = try send.metaInt(db, "brk_until");
    if (until > now) return .{ .why = try std.fmt.allocPrint(a, "breaker open for {d} more min after repeated failures", .{@divTrunc(until - now, 60_000) + 1}) };
    const bu = try send.metaInt(db, "blk_until");
    if (bu > now) {
        const w = (try send.metaGet(db, a, "blk_why")) orelse "quota";
        return .{ .why = try std.fmt.allocPrint(a, "stopped by Pinterest limit ({s}) for {d} more min", .{ w, @divTrunc(bu - now, 60_000) + 1 }) };
    }
    const n = try send.countSince(db, now - CF.day_ms);
    if (n >= cx.cfg.limits.daily_cap) return .{ .why = try std.fmt.allocPrint(a, "daily cap reached: {d} of {d} in the last 24 h", .{ n, cx.cfg.limits.daily_cap }) };
    const used = try reqUsed(cx, db);
    if (used >= cx.cfg.limits.req_budget_day) return .{ .why = try std.fmt.allocPrint(a, "request budget for today used: {d} of {d} calls", .{ used, cx.cfg.limits.req_budget_day }) };
    const gap = try send.metaInt(db, "next_ok");
    if (gap > now) return .{ .why = try std.fmt.allocPrint(a, "min gap between sends: wait {d} s", .{@divTrunc(gap - now, 1000) + 1}) };
    return null;
}

pub fn recordOk(db: *sq.Db) send.Err!void {
    try send.metaSetInt(db, "brk_fails", 0);
}

// one more failure; at the limit the breaker opens for cool_h hours
pub fn recordFail(cx: *const Ctx, db: *sq.Db) send.Err!void {
    const n = try send.metaInt(db, "brk_fails") + 1;
    try send.metaSetInt(db, "brk_fails", n);
    if (n >= cx.cfg.breaker.fails) {
        try send.metaSetInt(db, "brk_until", cx.nowMs() + @as(i64, cx.cfg.breaker.cool_h) * CF.h_ms);
        try send.metaSetInt(db, "brk_fails", 0);
    }
}

pub fn hardStop(db: *sq.Db) send.Err!void {
    try send.metaSetInt(db, "brk_hard", 1);
}

pub fn resetBreaker(db: *sq.Db) send.Err!void {
    try send.metaSetInt(db, "brk_hard", 0);
    try send.metaSetInt(db, "brk_until", 0);
    try send.metaSetInt(db, "brk_fails", 0);
    try send.metaSetInt(db, "blk_until", 0);
}

// Pinterest said stop (429, usage near the limit)
pub fn blockFor(db: *sq.Db, now: i64, ms: i64, why: []const u8) send.Err!void {
    try send.metaSetInt(db, "blk_until", now + ms);
    try send.metaSet(db, "blk_why", why);
}
pub fn quotaBlockMs(cx: *const Ctx) i64 {
    return @as(i64, cx.cfg.limits.quota_block_h) * CF.h_ms;
}

// random min..max gap after a finish, stored so a restart keeps it
pub fn setGap(cx: *const Ctx, db: *sq.Db) send.Err!void {
    const lo: u64 = cx.cfg.limits.gap_min_s;
    const hi: u64 = cx.cfg.limits.gap_max_s;
    var r: [8]u8 = undefined;
    cx.io.random(&r);
    const x = std.mem.readInt(u64, &r, .little);
    const s: u64 = if (hi > lo) lo + x % (hi - lo + 1) else lo;
    try send.metaSetInt(db, "next_ok", cx.nowMs() + @as(i64, @intCast(s)) * 1000);
}

pub const Usage = struct { pct: u32 = 0, regain_min: u32 = 0 };

// first number of a header value like "100, 100;w=1, 1000;w=60"
fn firstNum(v: []const u8) ?i64 {
    var end: usize = 0;
    while (end < v.len and std.ascii.isDigit(v[end])) end += 1;
    if (end == 0 or end > 12) return null;
    return std.fmt.parseInt(i64, v[0..end], 10) catch null;
}

// worst use from x-ratelimit-limit / -remaining / -reset (case-blind): percent used, and minutes to wait when it is spent
pub fn usage(a: std.mem.Allocator, headers: []const u8) Usage {
    _ = a;
    var u = Usage{};
    const lim = firstNum(net.headerValue(headers, "x-ratelimit-limit")) orelse return u;
    const rem = firstNum(net.headerValue(headers, "x-ratelimit-remaining")) orelse return u;
    if (lim <= 0 or rem > lim) return u;
    u.pct = @intCast(@divTrunc((lim - rem) * 100, lim));
    if (rem == 0) {
        const rs = firstNum(net.headerValue(headers, "x-ratelimit-reset")) orelse 0;
        u.regain_min = @intCast(@min(@divTrunc(rs + 59, 60), 100000));
    }
    return u;
}

// ---- day request budget (Trial tier: 1000 calls/day for all requests): counted in the ledger, survives restarts ----
fn dayNo(cx: *const Ctx) i64 {
    return @divTrunc(cx.nowMs() + @as(i64, cx.cfg.tz_offset_hours) * CF.h_ms, CF.day_ms);
}
pub fn reqUsed(cx: *const Ctx, db: *sq.Db) send.Err!i64 {
    if (try send.metaInt(db, "req_day") != dayNo(cx)) return 0;
    return send.metaInt(db, "req_n");
}
pub fn addCalls(cx: *const Ctx, db: *sq.Db, n: u32) send.Err!void {
    const used = try reqUsed(cx, db);
    try send.metaSetInt(db, "req_day", dayNo(cx));
    try send.metaSetInt(db, "req_n", used + n);
}

test "usage headers: percent used, reset only when spent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const u = usage(a, "Content-Type: x\nx-ratelimit-limit: 100, 100;w=1, 1000;w=60\nX-RateLimit-Remaining: 9\nx-ratelimit-reset: 30\n");
    try std.testing.expectEqual(@as(u32, 91), u.pct);
    try std.testing.expectEqual(@as(u32, 0), u.regain_min);
    const v = usage(a, "x-ratelimit-limit: 10\nx-ratelimit-remaining: 0\nx-ratelimit-reset: 125\n");
    try std.testing.expectEqual(@as(u32, 100), v.pct);
    try std.testing.expectEqual(@as(u32, 3), v.regain_min);
    try std.testing.expectEqual(@as(u32, 0), usage(a, "x-ratelimit-limit: junk\n").pct);
    try std.testing.expectEqual(@as(u32, 0), usage(a, "").pct);
    try std.testing.expectEqual(@as(u32, 0), usage(a, "x-ratelimit-limit: 5\nx-ratelimit-remaining: 9\n").pct);
}

test "cap rolls over 24h, gap, breaker, quota, hard stop, reset" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var t = try send.testDb(a, &env, &tmp.sub_path);
    defer t.db.close();
    var cx = t.cx;
    cx.cfg.limits.daily_cap = 2;
    try std.testing.expect((try blocked(&cx, &t.db, a)) == null);
    // two finishes in the window -> cap
    var i: u8 = 0;
    while (i < 2) : (i += 1) {
        const k = try std.fmt.allocPrint(a, "k{d}", .{i});
        const id = try send.begin(&cx, &t.db, a, k, k, "1", false);
        try send.finishAt(&cx, &t.db, id);
    }
    try std.testing.expect(std.mem.indexOf(u8, (try blocked(&cx, &t.db, a)).?.why, "daily cap") != null);
    // 24h + 1s later the window is empty again (survives a "restart": same db file, new handle)
    cx.fake_now_ms += 24 * 3600 * 1000 + 1000;
    try std.testing.expect((try blocked(&cx, &t.db, a)) == null);
    // gap
    try setGap(&cx, &t.db);
    try std.testing.expect(std.mem.indexOf(u8, (try blocked(&cx, &t.db, a)).?.why, "gap") != null);
    cx.fake_now_ms += 31 * 60 * 1000;
    try std.testing.expect((try blocked(&cx, &t.db, a)) == null);
    // request budget
    try addCalls(&cx, &t.db, cx.cfg.limits.req_budget_day);
    try std.testing.expect(std.mem.indexOf(u8, (try blocked(&cx, &t.db, a)).?.why, "request budget") != null);
    cx.fake_now_ms += 24 * 3600 * 1000;
    try std.testing.expect((try blocked(&cx, &t.db, a)) == null);
    // breaker: 3 fails open it, ok resets the count
    try recordFail(&cx, &t.db);
    try recordFail(&cx, &t.db);
    try recordOk(&t.db);
    try recordFail(&cx, &t.db);
    try recordFail(&cx, &t.db);
    try std.testing.expect((try blocked(&cx, &t.db, a)) == null);
    try recordFail(&cx, &t.db);
    try std.testing.expect(std.mem.indexOf(u8, (try blocked(&cx, &t.db, a)).?.why, "breaker") != null);
    cx.fake_now_ms += 6 * 3600 * 1000 + 1000;
    try std.testing.expect((try blocked(&cx, &t.db, a)) == null);
    // quota block
    try blockFor(&t.db, cx.nowMs(), quotaBlockMs(&cx), "HTTP 429");
    try std.testing.expect(std.mem.indexOf(u8, (try blocked(&cx, &t.db, a)).?.why, "429") != null);
    // 403: hard, time does not clear it
    try hardStop(&t.db);
    cx.fake_now_ms += 100 * 24 * 3600 * 1000;
    try std.testing.expect(std.mem.indexOf(u8, (try blocked(&cx, &t.db, a)).?.why, "403") != null);
    try resetBreaker(&t.db);
    try std.testing.expect((try blocked(&cx, &t.db, a)) == null);
}
