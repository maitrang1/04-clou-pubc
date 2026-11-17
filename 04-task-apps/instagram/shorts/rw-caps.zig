// Caps, gap, breaker, quota blocks. All state lives in the ledger (meta table), so it survives restarts. A ledger that cannot be read stops the run (a cap that fails open is no cap).
const std = @import("std");
const sq = @import("rw-sqlite.zig");
const send = @import("rw-send.zig");
const Ctx = @import("co-ctx.zig").Ctx;
const js = @import("ap-json.zig");

const CF = .{ .day_ms = 24 * 3600 * 1000, .h_ms = 3600 * 1000 };

pub const Block = struct { why: []const u8 };

// first reason the run must not send now, or null
pub fn blocked(cx: *const Ctx, db: *sq.Db, a: std.mem.Allocator) send.Err!?Block {
    const now = cx.nowMs();
    if (try send.metaInt(db, "brk_hard") != 0) return .{ .why = "breaker open: Instagram restricted the action or the account (spam restriction 2207051 / restricted account 2207050). A person must look, then run: config --reset-breaker --live" };
    const until = try send.metaInt(db, "brk_until");
    if (until > now) return .{ .why = try std.fmt.allocPrint(a, "breaker open for {d} more min after repeated failures", .{@divTrunc(until - now, 60_000) + 1}) };
    const bu = try send.metaInt(db, "blk_until");
    if (bu > now) {
        const w = (try send.metaGet(db, a, "blk_why")) orelse "quota";
        return .{ .why = try std.fmt.allocPrint(a, "stopped by Instagram limit ({s}) for {d} more min", .{ w, @divTrunc(bu - now, 60_000) + 1 }) };
    }
    const n = try send.countSince(db, now - CF.day_ms);
    if (n >= cx.cfg.limits.daily_cap) return .{ .why = try std.fmt.allocPrint(a, "daily cap reached: {d} of {d} publishes in the last 24 h", .{ n, cx.cfg.limits.daily_cap }) };
    const nc = try send.contSince(db, now - CF.day_ms);
    if (nc >= cx.cfg.limits.container_cap) return .{ .why = try std.fmt.allocPrint(a, "container cap reached: {d} of {d} containers in the last 24 h (Meta allows 400)", .{ nc, cx.cfg.limits.container_cap }) };
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

// Instagram said stop (quota codes, 429, usage near the limit)
pub fn blockFor(db: *sq.Db, now: i64, ms: i64, why: []const u8) send.Err!void {
    try send.metaSetInt(db, "blk_until", now + ms);
    try send.metaSet(db, "blk_why", why);
}
pub fn quotaBlockMs(cx: *const Ctx) i64 {
    return @as(i64, cx.cfg.limits.quota_block_h) * CF.h_ms;
}

// random min..max gap after a publish call, stored so a restart keeps it
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

fn pctOf(v: ?std.json.Value) u32 {
    var m: i64 = 0;
    m = @max(m, js.int(v, "call_count"));
    m = @max(m, js.int(v, "total_time"));
    m = @max(m, js.int(v, "total_cputime"));
    return @intCast(@min(@max(m, 0), 100000));
}

// worst percent over X-App-Usage and X-Business-Use-Case-Usage in the raw header blob
pub fn usage(a: std.mem.Allocator, headers: []const u8) Usage {
    var u = Usage{};
    var it = std.mem.splitScalar(u8, headers, '\n');
    while (it.next()) |l| {
        if (std.ascii.startsWithIgnoreCase(l, "x-app-usage:")) {
            u.pct = @max(u.pct, pctOf(js.parse(a, std.mem.trim(u8, l[12..], " \r"))));
        } else if (std.ascii.startsWithIgnoreCase(l, "x-business-use-case-usage:")) {
            const root = js.parse(a, std.mem.trim(u8, l[26..], " \r")) orelse continue;
            if (root != .object) continue;
            var oi = root.object.iterator();
            while (oi.next()) |kv| {
                if (kv.value_ptr.* != .array) continue;
                for (kv.value_ptr.array.items) |x| {
                    u.pct = @max(u.pct, pctOf(x));
                    u.regain_min = @max(u.regain_min, @as(u32, @intCast(@min(@max(js.int(x, "estimated_time_to_regain_access"), 0), 100000))));
                }
            }
        }
    }
    return u;
}

test "usage headers: app + business, worst wins" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const u = usage(a, "Content-Type: x\nX-App-Usage: {\"call_count\":12,\"total_time\":30,\"total_cputime\":5}\nX-Business-Use-Case-Usage: {\"555\":[{\"type\":\"pages\",\"call_count\":91,\"total_cputime\":2,\"total_time\":3,\"estimated_time_to_regain_access\":17}]}\n");
    try std.testing.expectEqual(@as(u32, 91), u.pct);
    try std.testing.expectEqual(@as(u32, 17), u.regain_min);
    try std.testing.expectEqual(@as(u32, 0), usage(a, "X-App-Usage: not json\n").pct);
    try std.testing.expectEqual(@as(u32, 0), usage(a, "").pct);
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
    // two publish calls in the window -> cap
    var i: u8 = 0;
    while (i < 2) : (i += 1) {
        const k = try std.fmt.allocPrint(a, "k{d}", .{i});
        const id = try send.begin(&cx, &t.db, a, k, k, "1", false);
        try send.pubAt(&cx, &t.db, id);
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
    // quota block
    try blockFor(&t.db, cx.nowMs(), quotaBlockMs(&cx), "code 613");
    try std.testing.expect(std.mem.indexOf(u8, (try blocked(&cx, &t.db, a)).?.why, "613") != null);
    // hard stop (2207051/2207050): time does not clear it
    try hardStop(&t.db);
    cx.fake_now_ms += 100 * 24 * 3600 * 1000;
    try std.testing.expect(std.mem.indexOf(u8, (try blocked(&cx, &t.db, a)).?.why, "2207051") != null);
    try resetBreaker(&t.db);
    try std.testing.expect((try blocked(&cx, &t.db, a)) == null);
}

test "container cap counts containers, not publishes, and rolls over" {
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
    cx.cfg.limits.container_cap = 2;
    _ = try send.begin(&cx, &t.db, a, "a", "ka", "1", false);
    try std.testing.expect((try blocked(&cx, &t.db, a)) == null);
    _ = try send.begin(&cx, &t.db, a, "b", "kb", "2", false); // two containers, zero publishes
    try std.testing.expect(std.mem.indexOf(u8, (try blocked(&cx, &t.db, a)).?.why, "container cap") != null);
    cx.fake_now_ms += 24 * 3600 * 1000 + 1000;
    try std.testing.expect((try blocked(&cx, &t.db, a)) == null);
}
