// =====================================================================
// Des: Joins what the folder says (pairs) with what the ledger says (rows) into one status per video, and picks the next one to send - oldest first, never a held or review video without approval
// Flo: pair status + ledger row + review flag > Kind > next publishable (new non-review, or approved)
// Cre: 2026-11-15                          - | Mod: 2026-11-15
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: pair Items, Ledger
// Out: Kind per item; the next Item to publish or null
// Run: not run directly - imported by cm-scan, cm-status, cm-publish, cm-approve, cm-resolve
// =====================================================================
const std = @import("std");
const pair = @import("rw-pair.zig");
const send = @import("rw-send.zig");

pub const Kind = enum { ready, held, approved, sending, posted, failed, unsure, invalid, rejected, stale, old };

pub fn kindOf(it: pair.Item, row: ?send.Row) Kind {
    switch (it.status) {
        .invalid => return .invalid,
        .rejected => return .rejected,
        .stale => return .stale,
        .old => if (row == null) return .old,
        .ready => {},
    }
    if (row) |r| return switch (r.state) {
        .held => .held,
        .ready => .approved,
        .sending => .sending,
        .posted => .posted,
        .failed => .failed,
        .unsure => .unsure,
    };
    return if (it.pair.review) .held else .ready;
}

pub fn label(k: Kind) []const u8 {
    return switch (k) {
        .ready => "ready",
        .held => "held",
        .approved => "approved",
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

// oldest first (items are sorted): a new non-review video, or one a person approved
pub fn next(a: std.mem.Allocator, l: send.Ledger, items: []const pair.Item) send.Err!?Picked {
    for (items) |it| {
        if (it.status != .ready) continue;
        const row = try l.find(a, it.pkey);
        const k = kindOf(it, row);
        if (k == .ready or k == .approved) return .{ .item = it, .row = row };
    }
    return null;
}

pub fn byName(items: []const pair.Item, name: []const u8) ?pair.Item {
    for (items) |it| if (std.mem.eql(u8, it.name, name)) return it;
    return null;
}

fn item(name: []const u8, st: pair.Status, review: bool, key: []const u8) pair.Item {
    return .{ .name = name, .status = st, .pair = .{ .review = review }, .pkey = key };
}

test "kinds: review video is held until approved; approved is publishable; terminal states stay" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const l = try send.Ledger.openPath(try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/p.db", .{&tmp.sub_path}));
    defer l.close();
    const items = [_]pair.Item{
        item("rev", .ready, true, "k-rev"),
        item("plain", .ready, false, "k-plain"),
        item("bad", .invalid, false, "k-bad"),
        item("done", .ready, false, "k-done"),
    };
    try std.testing.expect(kindOf(items[0], null) == .held);
    try std.testing.expect(kindOf(items[1], null) == .ready);
    try std.testing.expect(kindOf(items[2], null) == .invalid);
    // the plain one comes first (the review video is held)
    try std.testing.expectEqualStrings("plain", (try next(a, l, &items)).?.item.name);
    _ = try l.insertNew("done", "k-done", .posted, "", 1);
    _ = try l.insertNew("plain", "k-plain", .posted, "", 1);
    try std.testing.expect((try next(a, l, &items)) == null);
    // approve the review video: it becomes the next one
    _ = try l.insertNew("rev", "k-rev", .ready, "", 1);
    try std.testing.expectEqualStrings("rev", (try next(a, l, &items)).?.item.name);
    try l.setState("k-rev", .unsure, "x", 2);
    try std.testing.expect((try next(a, l, &items)) == null); // unsure is never picked
    try std.testing.expect(kindOf(items[0], try l.find(a, "k-rev")) == .unsure);
    try std.testing.expect(byName(&items, "done") != null and byName(&items, "zzz") == null);
}
// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
