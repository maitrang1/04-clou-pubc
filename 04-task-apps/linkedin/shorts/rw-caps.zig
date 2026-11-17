// Caps, gap, breaker, quota blocks. All state lives in the ledger (meta table), so it survives restarts. A ledger that cannot be read stops the run (a cap that fails open is no cap).
const std = @import("std");
const sq = @import("rw-sqlite.zig");
const send = @import("rw-send.zig");
const Ctx = @import("co-ctx.zig").Ctx;

const CF = .{ .day_ms = 24 * 3600 * 1000, .h_ms = 3600 * 1000 };

pub const Block = struct { why: []const u8 };

// first reason the run must not send now, or null
pub fn blocked(cx: *const Ctx, db: *sq.Db, a: std.mem.Allocator) send.Err!?Block {
    const now = cx.nowMs();
    if (try send.metaInt(db, "tok_dead") != 0) return .{ .why = "token rejected by LinkedIn (401): re-login, store the new token, then run: token --live" };
    const until = try send.metaInt(db, "brk_until");
    if (until > now) return .{ .why = try std.fmt.allocPrint(a, "breaker open for {d} more min after repeated failures", .{@divTrunc(until - now, 60_000) + 1}) };
    const bu = try send.metaInt(db, "blk_until");
    if (bu > now) {
        const w = (try send.metaGet(db, a, "blk_why")) orelse "quota";
        return .{ .why = try std.fmt.allocPrint(a, "stopped by a LinkedIn limit ({s}) for {d} more min", .{ w, @divTrunc(bu - now, 60_000) + 1 }) };
    }
    const n = try send.countSince(db, now - CF.day_ms);
    if (n >= cx.cfg.limits.daily_cap) return .{ .why = try std.fmt.allocPrint(a, "daily cap reached: {d} of {d} in the last 24 h", .{ n, cx.cfg.limits.daily_cap }) };
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


// the token answered 401: no run sends until a person re-logins and `token --live` sees it alive
pub fn tokenDead(db: *sq.Db, dead: bool) send.Err!void {
    try send.metaSetInt(db, "tok_dead", if (dead) 1 else 0);
}
pub fn resetBreaker(db: *sq.Db) send.Err!void {
    try send.metaSetInt(db, "brk_until", 0);
    try send.metaSetInt(db, "brk_fails", 0);
    try send.metaSetInt(db, "blk_until", 0);
}

// LinkedIn said stop (429)
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
    // quota block (429): stays for quota_block_h, then clears
    try blockFor(&t.db, cx.nowMs(), quotaBlockMs(&cx), "http 429");
    try std.testing.expect(std.mem.indexOf(u8, (try blocked(&cx, &t.db, a)).?.why, "429") != null);
    cx.fake_now_ms += 25 * 3600 * 1000;
    try std.testing.expect((try blocked(&cx, &t.db, a)) == null);
    // a 401 stops every run until a person clears it
    try tokenDead(&t.db, true);
    try std.testing.expect(std.mem.indexOf(u8, (try blocked(&cx, &t.db, a)).?.why, "token rejected") != null);
    try tokenDead(&t.db, false);
    try std.testing.expect((try blocked(&cx, &t.db, a)) == null);
    // reset clears breaker and stop by hand
    try blockFor(&t.db, cx.nowMs(), quotaBlockMs(&cx), "http 429");
    try recordFail(&cx, &t.db);
    try recordFail(&cx, &t.db);
    try recordFail(&cx, &t.db);
    try std.testing.expect((try blocked(&cx, &t.db, a)) != null);
    try resetBreaker(&t.db);
    try std.testing.expect((try blocked(&cx, &t.db, a)) == null);
}
