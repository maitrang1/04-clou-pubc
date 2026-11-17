// Upload step 4: GET /rest/videos/{urn} -> status WAITING_UPLOAD | PROCESSING | PROCESSING_FAILED | AVAILABLE. Unknown words read as `unknown` (never guessed).
const std = @import("std");
const Ctx = @import("co-ctx.zig").Ctx;
const call = @import("ap-call.zig");
const js = @import("ap-json.zig");

pub const Verdict = enum { waiting, processing, failed, available, unknown };
pub const Status = struct { verdict: Verdict = .unknown, word: []const u8 = "", reason: []const u8 = "" };

pub fn verdictOf(w: []const u8) Verdict {
    if (std.mem.eql(u8, w, "AVAILABLE")) return .available;
    if (std.mem.eql(u8, w, "PROCESSING")) return .processing;
    if (std.mem.eql(u8, w, "WAITING_UPLOAD")) return .waiting;
    if (std.mem.eql(u8, w, "PROCESSING_FAILED")) return .failed;
    return .unknown;
}

pub fn parse(a: std.mem.Allocator, body: []const u8) ?Status {
    const root = js.parse(a, body) orelse return null;
    const w = js.str(root, "status");
    if (w.len == 0) return null;
    return .{ .verdict = verdictOf(w), .word = w, .reason = js.str(root, "processingFailureReason") };
}

pub fn get(cx: *const Ctx, a: std.mem.Allocator, tok: []const u8, video: []const u8) call.Out(Status) {
    if (!call.urnOk(video, "video")) return .{ .fail = .{ .info = .{ .class = .failed, .msg = "video urn has odd characters" } } };
    const enc = call.urnEnc(a, video) catch return .{ .fail = .{ .info = .{ .class = .failed, .msg = "out of memory" } } };
    const path = std.fmt.allocPrint(a, "videos/{s}", .{enc}) catch return .{ .fail = .{ .info = .{ .class = .failed, .msg = "out of memory" } } };
    const url = call.restUrl(cx, a, path) catch return .{ .fail = .{ .info = .{ .class = .failed, .msg = "out of memory" } } };
    switch (call.call(cx, a, .{ .url = url, .token = tok, .label = "GET /rest/videos/{urn}" })) {
        .fail => |f| return .{ .fail = f },
        .ok => |ok| {
            const s = parse(a, ok.body) orelse return .{ .fail = .{ .info = .{ .class = .retry, .msg = "video status reply unreadable" }, .body = ok.body } };
            return .{ .ok = s };
        },
    }
}

test "status words map to verdicts, unknown stays unknown" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqual(Verdict.available, parse(a, "{\"id\":\"urn:li:video:A\",\"status\":\"AVAILABLE\",\"duration\":9000}").?.verdict);
    try std.testing.expectEqual(Verdict.processing, parse(a, "{\"status\":\"PROCESSING\"}").?.verdict);
    try std.testing.expectEqual(Verdict.waiting, parse(a, "{\"status\":\"WAITING_UPLOAD\"}").?.verdict);
    const f = parse(a, "{\"status\":\"PROCESSING_FAILED\",\"processingFailureReason\":\"bad codec\"}").?;
    try std.testing.expectEqual(Verdict.failed, f.verdict);
    try std.testing.expectEqualStrings("bad codec", f.reason);
    try std.testing.expectEqual(Verdict.unknown, parse(a, "{\"status\":\"BRAND_NEW\"}").?.verdict);
    try std.testing.expect(parse(a, "{}") == null);
    try std.testing.expect(parse(a, "x") == null);
}
