// =====================================================================
// Des: Joins what the folder says (pairs) with what the ledger says (rows) into one status per video, and picks the next one to send - new videos first (oldest first), then failed ones that never started an upload, a few times
// Flo: pair status + ledger row > Kind > next publishable (new, queued, or a failed one still allowed a retry)
// Cre: 2026-11-15                          - | Mod: 2026-11-20
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: pair Items, Ledger, limits.retry_max
// Out: Kind per item; the next Item to publish or null
// Run: not run directly - imported by cm-scan, cm-status, cm-publish, cm-resolve
// =====================================================================
const std = @import("std");
const pair = @import("rw-pair.zig");
const send = @import("rw-send.zig");

pub const Kind = enum { ready, sending, posted, failed, unsure, invalid, rejected, stale, old };

pub fn kindOf(it: pair.Item, row: ?send.Row) Kind {
    switch (it.status) {
        .invalid => return .invalid,
        .rejected => return .rejected,
        .stale => return .stale,
        .old => if (row == null) return .old,
        .ready => {},
    }
    if (row) |r| return switch (r.state) {
        .ready => .ready,
        .sending => .sending,
        .posted => .posted,
        .failed => .failed,
        .unsure => .unsure,
    };
    return .ready;
}

pub fn label(k: Kind) []const u8 {
    return switch (k) {
        .ready => "ready",
        .sending => "sending",
        .posted => "posted",
        .failed => "failed",
        .unsure => "unsure",
        .invalid => "invalid",
        .rejected => "rejected",
        .stale => "stale",
        .old => "old",
    };
}

pub const Picked = struct { item: pair.Item, row: ?send.Row };

fn retryKey(a: std.mem.Allocator, pkey: []const u8) std.mem.Allocator.Error![]u8 {
    return std.fmt.allocPrint(a, "retry:{s}", .{pkey});
}

// a failed video whose upload never started may go again, up to retry_max times (an upload that started needs `resolve`)
pub fn canRetry(a: std.mem.Allocator, l: send.Ledger, row: send.Row, retry_max: u32) bool {
    if (row.state != .failed or row.session_uri.len > 0) return false;
    const key = retryKey(a, row.pkey) catch return false;
    const used = l.kvInt(key) catch return false;
    return used < retry_max;
}

// counts one retry (called when a failed video is sent again)
pub fn noteRetry(a: std.mem.Allocator, l: send.Ledger, row: send.Row) void {
    const key = retryKey(a, row.pkey) catch return;
    const used = l.kvInt(key) catch 0;
    l.kvSetInt(key, used + 1) catch {};
}

// new and queued videos first (oldest first), then retryable failed ones
pub fn next(a: std.mem.Allocator, l: send.Ledger, items: []const pair.Item, retry_max: u32) send.Err!?Picked {
    var again: ?Picked = null;
    for (items) |it| {
        if (it.status != .ready) continue;
        const row = try l.find(a, it.pkey);
        const k = kindOf(it, row);
        if (k == .ready) return .{ .item = it, .row = row };
        if (again == null and k == .failed and canRetry(a, l, row.?, retry_max)) again = .{ .item = it, .row = row };
    }
    return again;
}

pub fn byName(items: []const pair.Item, name: []const u8) ?pair.Item {
    for (items) |it| if (std.mem.eql(u8, it.name, name)) return it;
    return null;
}

fn item(name: []const u8, st: pair.Status, key: []const u8) pair.Item {
    return .{ .name = name, .status = st, .pair = .{}, .pkey = key };
}

test "kinds: every valid video is ready; terminal states stay; failed retries are bounded and come last" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const l = try send.Ledger.openPath(try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/p.db", .{&tmp.sub_path}));
    defer l.close();
    const items = [_]pair.Item{
        item("bad", .invalid, "k-bad"),
        item("old1", .ready, "k-old1"),
        item("new1", .ready, "k-new1"),
    };
    try std.testing.expect(kindOf(items[0], null) == .invalid);
    try std.testing.expect(kindOf(items[1], null) == .ready);
    try std.testing.expectEqualStrings("old1", (try next(a, l, &items, 2)).?.item.name);
    // old1 failed before any upload: the fresh one goes first, then old1 is retried twice at most
    _ = try l.insertNew("old1", "k-old1", .failed, "", 1);
    try std.testing.expectEqualStrings("new1", (try next(a, l, &items, 2)).?.item.name);
    _ = try l.insertNew("new1", "k-new1", .posted, "", 1);
    const row = (try l.find(a, "k-old1")).?;
    try std.testing.expectEqualStrings("old1", (try next(a, l, &items, 2)).?.item.name);
    noteRetry(a, l, row);
    noteRetry(a, l, row);
    try std.testing.expect((try next(a, l, &items, 2)) == null);
    // an upload that started is never retried here
    try l.setSession("k-old1", "https://x/s", 5);
    try std.testing.expect((try next(a, l, &items, 9)) == null);
    try l.setState("k-old1", .unsure, "x", 6);
    try std.testing.expect((try next(a, l, &items, 9)) == null);
    try std.testing.expect(kindOf(items[1], try l.find(a, "k-old1")) == .unsure);
    try std.testing.expect(byName(&items, "new1") != null and byName(&items, "zzz") == null);
}
// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
// =====================================================================
