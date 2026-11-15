// =====================================================================
// Des: The 3-way decision for one file - given the near copy, the far copy and the copy both sides last agreed on, say what a sync, a pull or a push must do; it never says delete
// Flo: compare near and far > if they differ look at which side moved away from the agreed base > same / copy to near / copy to far / conflict
// Cre: 2026-11-15                          - | Mod: 2026-11-15
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: near bytes or null, far bytes or null, base bytes or null, command mode
// Out: Act (what is true) and Todo (what this command does about it)
// Run: not run directly - imported by sync-flow.zig
// Exe: n/a
// =====================================================================
const std = @import("std");

pub const Act = enum { same, to_near, to_far, conflict };
pub const Mode = enum { sync, pull, push };
pub const Todo = enum { none, write_near, write_far, resolve, skip_behind, skip_ahead };

fn eq(x: ?[]const u8, y: ?[]const u8) bool {
    return if (x != null and y != null) std.mem.eql(u8, x.?, y.?) else x == null and y == null;
}

// what is true about this file; a missing side is never a delete: the other side's copy comes back ----
pub fn decide(near: ?[]const u8, far: ?[]const u8, base: ?[]const u8) Act {
    if (near == null and far == null) return .same;
    if (eq(near, far)) return .same;
    if (near == null) return .to_near;
    if (far == null) return .to_far;
    const b = base orelse return .conflict;
    const near_moved = !std.mem.eql(u8, near.?, b);
    const far_moved = !std.mem.eql(u8, far.?, b);
    if (near_moved and far_moved) return .conflict;
    return if (far_moved) .to_near else .to_far;
}

// what this command does: pull = far wins, push = near wins, sync = both ways and a conflict is resolved (merge, else the newest edit wins) ----
pub fn todo(mode: Mode, act: Act) Todo {
    return switch (act) {
        .same => .none,
        .to_near => switch (mode) {
            .push => .skip_behind,
            else => .write_near,
        },
        .to_far => switch (mode) {
            .pull => .skip_ahead,
            else => .write_far,
        },
        .conflict => switch (mode) {
            .pull => .write_near,
            .push => .write_far,
            .sync => .resolve,
        },
    };
}

test "decide: every cell of the table; a missing side is never a delete" {
    const n: ?[]const u8 = "N";
    const f: ?[]const u8 = "F";
    const b: ?[]const u8 = "B";
    try std.testing.expectEqual(Act.same, decide(null, null, null));
    try std.testing.expectEqual(Act.same, decide(null, null, b));
    try std.testing.expectEqual(Act.same, decide(n, n, b));
    try std.testing.expectEqual(Act.same, decide(n, n, null));
    try std.testing.expectEqual(Act.to_near, decide(null, f, null));
    try std.testing.expectEqual(Act.to_near, decide(null, f, b));
    try std.testing.expectEqual(Act.to_far, decide(n, null, null));
    try std.testing.expectEqual(Act.to_far, decide(n, null, b));
    try std.testing.expectEqual(Act.to_near, decide(b, f, b));
    try std.testing.expectEqual(Act.to_far, decide(n, b, b));
    try std.testing.expectEqual(Act.conflict, decide(n, f, b));
    try std.testing.expectEqual(Act.conflict, decide(n, f, null));
}

test "todo: pull far wins, push near wins, sync resolves a conflict; nothing deletes" {
    const T = Todo;
    try std.testing.expectEqual(T.none, todo(.sync, .same));
    try std.testing.expectEqual(T.write_near, todo(.sync, .to_near));
    try std.testing.expectEqual(T.write_far, todo(.sync, .to_far));
    try std.testing.expectEqual(T.resolve, todo(.sync, .conflict));
    try std.testing.expectEqual(T.write_near, todo(.pull, .to_near));
    try std.testing.expectEqual(T.skip_ahead, todo(.pull, .to_far));
    try std.testing.expectEqual(T.write_near, todo(.pull, .conflict));
    try std.testing.expectEqual(T.skip_behind, todo(.push, .to_near));
    try std.testing.expectEqual(T.write_far, todo(.push, .to_far));
    try std.testing.expectEqual(T.write_far, todo(.push, .conflict));
}
// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
