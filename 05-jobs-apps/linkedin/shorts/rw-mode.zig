// The post-mode gate, in ONE place, checked right before the create-post request every time (§0.1 of the build guide).
// stage = never post · approve = only pairs a person approved · auto = only with terms.ack_auto_post. Every mode also needs device.publisher.
const std = @import("std");
const Ctx = @import("co-ctx.zig").Ctx;
const cfgm = @import("co-cfg.zig");

pub const Gate = enum { stage_only, go, not_approved, no_ack, no_publisher };

pub fn gate(cx: *const Ctx, approved: bool) Gate {
    if (!cx.cfg.device.publisher) return .no_publisher;
    const m = cfgm.modeOf(cx.cfg.post.mode) orelse return .stage_only; // an unknown word never posts
    return switch (m) {
        .stage => .stage_only,
        .approve => if (approved) .go else .not_approved,
        .auto => if (cx.cfg.terms.ack_auto_post) .go else .no_ack,
    };
}

pub fn why(g: Gate) []const u8 {
    return switch (g) {
        .go => "go",
        .stage_only => "post.mode is stage: the video is uploaded and ready, no post is created",
        .not_approved => "post.mode is approve: a person has not approved this video (approve --video NAME --live)",
        .no_ack => "post.mode is auto but terms.ack_auto_post is false",
        .no_publisher => "device.publisher is false: this device may not publish",
    };
}

test "stage never posts; approve needs the approval; auto needs the ack; every mode needs the publisher flag" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var cx = @import("co-ctx.zig").testCtx(arena.allocator(), &env, "/h");
    // default device.publisher is false
    try std.testing.expectEqual(Gate.no_publisher, gate(&cx, true));
    cx.cfg.device.publisher = true;
    try std.testing.expectEqual(Gate.stage_only, gate(&cx, true));
    cx.cfg.post.mode = "approve";
    try std.testing.expectEqual(Gate.not_approved, gate(&cx, false));
    try std.testing.expectEqual(Gate.go, gate(&cx, true));
    cx.cfg.post.mode = "auto";
    try std.testing.expectEqual(Gate.no_ack, gate(&cx, true));
    cx.cfg.terms.ack_auto_post = true;
    try std.testing.expectEqual(Gate.go, gate(&cx, false));
    cx.cfg.post.mode = "garbage";
    try std.testing.expectEqual(Gate.stage_only, gate(&cx, true));
    cx.cfg.post.mode = "auto";
    cx.cfg.device.publisher = false;
    try std.testing.expectEqual(Gate.no_publisher, gate(&cx, true));
}
