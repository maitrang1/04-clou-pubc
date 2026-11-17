// Slot rule: which ready video goes out now. The slot is the day part a video was made in (source.slot_hours, e.g. "8,14,20"); the newest slot wins, the oldest video inside it goes first. An empty current slot = the pick steps back to the slot before (yesterday too), down to source.max_age_h.
const std = @import("std");

const CF = .{ .slots_max = @as(usize, 8), .hour_ms = @as(i64, 3600 * 1000), .day_ms = @as(i64, 24 * 3600 * 1000) };

// "8,14,20" > ascending hours 0-23; null when not 1..8 strictly ascending numbers
pub fn parse(buf: *[CF.slots_max]u8, text: []const u8) ?[]const u8 {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, text, ',');
    while (it.next()) |tok| {
        const h = std.fmt.parseInt(u8, std.mem.trim(u8, tok, " "), 10) catch return null;
        if (h > 23 or n >= CF.slots_max) return null;
        if (n > 0 and h <= buf[n - 1]) return null;
        buf[n] = h;
        n += 1;
    }
    return if (n == 0) null else buf[0..n];
}

// start (ms epoch) of the slot that holds `ms`; before the first slot of a day = the last slot of the day before. Bad hours = 0
pub fn slotStart(ms: i64, tz_h: i32, hours_text: []const u8) i64 {
    var buf: [CF.slots_max]u8 = undefined;
    const slots = parse(&buf, hours_text) orelse return 0;
    const tz = @as(i64, tz_h) * CF.hour_ms;
    const local = ms + tz;
    var day = @divFloor(local, CF.day_ms);
    const into = local - day * CF.day_ms;
    var slot: i64 = -1;
    for (slots) |s| {
        if (@as(i64, s) * CF.hour_ms <= into) slot = s;
    }
    if (slot < 0) {
        day -= 1;
        slot = slots[slots.len - 1];
    }
    return day * CF.day_ms + slot * CF.hour_ms - tz;
}

// one candidate: when it was made and a tie-break name
pub const Cand = struct { made_ms: i64, name: []const u8 };

// true when x goes before y: newer slot first, then older video, then name
pub fn before(tz_h: i32, hours_text: []const u8, x: Cand, y: Cand) bool {
    const sx = slotStart(x.made_ms, tz_h, hours_text);
    const sy = slotStart(y.made_ms, tz_h, hours_text);
    if (sx != sy) return sx > sy;
    if (x.made_ms != y.made_ms) return x.made_ms < y.made_ms;
    return std.mem.lessThan(u8, x.name, y.name);
}

// too old to publish; 0 = no limit
pub fn tooOld(now_ms: i64, made_ms: i64, max_age_h: u32) bool {
    return max_age_h > 0 and now_ms - made_ms > @as(i64, max_age_h) * CF.hour_ms;
}

fn at(day: i64, h: i64, m: i64) i64 { // local (+7) clock > ms epoch; day 0 = 2026-11-16
    const base: i64 = 1794762000000; // 2026-11-16 00:00 at +07
    return base + day * CF.day_ms + h * CF.hour_ms + m * 60 * 1000;
}

test "parse: ascending hours only" {
    var b: [CF.slots_max]u8 = undefined;
    try std.testing.expectEqualSlices(u8, &.{ 9, 15, 21 }, parse(&b, "9, 15,21").?);
    try std.testing.expect(parse(&b, "15,9") == null);
    try std.testing.expect(parse(&b, "9,9") == null);
    try std.testing.expect(parse(&b, "24") == null);
    try std.testing.expect(parse(&b, "") == null);
    try std.testing.expect(parse(&b, "a") == null);
}

test "slotStart: 09h 15h 21h, night belongs to the 21h slot of the day before" {
    const h = "9,15,21";
    try std.testing.expectEqual(at(0, 9, 0), slotStart(at(0, 9, 5), 7, h));
    try std.testing.expectEqual(at(0, 9, 0), slotStart(at(0, 14, 59), 7, h));
    try std.testing.expectEqual(at(0, 15, 0), slotStart(at(0, 15, 0), 7, h));
    try std.testing.expectEqual(at(0, 21, 0), slotStart(at(0, 23, 59), 7, h));
    try std.testing.expectEqual(at(-1, 21, 0), slotStart(at(0, 3, 0), 7, h));
    try std.testing.expectEqual(@as(i64, 0), slotStart(at(0, 3, 0), 7, "x"));
}

test "before: newest slot first, oldest inside the slot, name last" {
    const h = "9,15,21";
    const old_slot = Cand{ .made_ms = at(0, 10, 0), .name = "a" };
    const new_early = Cand{ .made_ms = at(0, 15, 5), .name = "b" };
    const new_late = Cand{ .made_ms = at(0, 16, 30), .name = "c" };
    try std.testing.expect(before(7, h, new_early, old_slot));
    try std.testing.expect(before(7, h, new_early, new_late));
    try std.testing.expect(!before(7, h, new_late, new_early));
    const tie = Cand{ .made_ms = new_early.made_ms, .name = "a" };
    try std.testing.expect(before(7, h, tie, new_early));
}

test "tooOld: limit in hours, 0 = off" {
    try std.testing.expect(!tooOld(at(0, 12, 0), at(-1, 13, 0), 48));
    try std.testing.expect(tooOld(at(1, 12, 0), at(-1, 11, 0), 48));
    try std.testing.expect(!tooOld(at(9, 0, 0), at(-9, 0, 0), 0));
}
