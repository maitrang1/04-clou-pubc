// Reels step 3: GET {video-id}?fields=status. Parses both spellings (complete/completed) and tolerates missing fields.
const std = @import("std");
const Ctx = @import("co-ctx.zig").Ctx;
const call = @import("ap-call.zig");
const js = @import("ap-json.zig");

pub const Status = struct {
    video_status: []const u8 = "",
    up_status: []const u8 = "",
    bytes: u64 = 0,
    src_size: u64 = 0,
    proc_status: []const u8 = "",
    proc_err: []const u8 = "",
    pub_status: []const u8 = "",
    publish_status: []const u8 = "",
    pub_err: []const u8 = "",
};
pub const Verdict = enum { uploading, uploaded, processing, published, draft, failed, expired, unknown };

pub fn done(s: []const u8) bool {
    return std.mem.eql(u8, s, "complete") or std.mem.eql(u8, s, "completed");
}

pub fn parse(a: std.mem.Allocator, body: []const u8) ?Status {
    const root = js.parse(a, body) orelse return null;
    const st = js.obj(root, "status") orelse return null;
    const up = js.obj(st, "uploading_phase");
    const pr = js.obj(st, "processing_phase");
    const pu = js.obj(st, "publishing_phase");
    return .{
        .video_status = js.str(st, "video_status"),
        .up_status = js.str(up, "status"),
        .bytes = @intCast(@max(js.int(up, "bytes_transfered"), @max(0, js.int(up, "bytes_transferred")))), // docs say transfered, Facebook sends transferred: read both
        .src_size = @intCast(@max(0, js.int(up, "source_file_size"))),
        .proc_status = js.str(pr, "status"),
        .proc_err = js.str(js.obj(pr, "error"), "message"),
        .pub_status = js.str(pu, "status"),
        .publish_status = js.str(pu, "publish_status"),
        .pub_err = js.str(js.obj(pu, "error"), "message"),
    };
}

pub fn verdict(s: Status) Verdict {
    const eq = std.mem.eql;
    if (eq(u8, s.video_status, "expired")) return .expired;
    if (eq(u8, s.video_status, "error") or eq(u8, s.video_status, "upload_failed") or eq(u8, s.up_status, "error") or eq(u8, s.proc_status, "error") or eq(u8, s.pub_status, "error") or eq(u8, s.publish_status, "error")) return .failed;
    if (done(s.pub_status) and eq(u8, s.publish_status, "published")) return .published;
    if (done(s.pub_status) and eq(u8, s.publish_status, "draft")) return .draft;
    if (eq(u8, s.video_status, "processing") or eq(u8, s.proc_status, "in_progress")) return .processing;
    if (eq(u8, s.video_status, "upload_complete") or (done(s.up_status) and s.pub_status.len == 0)) return .uploaded;
    if (eq(u8, s.video_status, "uploading") or eq(u8, s.up_status, "in_progress")) return .uploading;
    if (eq(u8, s.video_status, "ready") and s.pub_status.len == 0) return .published; // ready with no publishing phase reported: treat as live
    if (eq(u8, s.video_status, "ready")) return .processing; // ready but publishing not finished yet
    if (done(s.up_status)) return .uploaded;
    return .unknown;
}

pub fn get(cx: *const Ctx, a: std.mem.Allocator, tok: []const u8, video_id: []const u8) call.Out(Status) {
    if (!call.idOk(video_id)) return .{ .fail = .{ .info = .{ .class = .failed, .msg = "video id must be digits" } } };
    const path = std.fmt.allocPrint(a, "{s}?fields=status", .{video_id}) catch return .{ .fail = .{ .info = .{ .class = .failed, .msg = "out of memory" } } };
    const url = call.graphUrl(cx, a, path) catch return .{ .fail = .{ .info = .{ .class = .failed, .msg = "out of memory" } } };
    switch (call.call(cx, a, .{ .url = url, .token = tok })) {
        .fail => |f| return .{ .fail = f },
        .ok => |ok| {
            const s = parse(a, ok.body) orelse return .{ .fail = .{ .info = .{ .class = .retry, .msg = "status reply unreadable" }, .body = ok.body } };
            return .{ .ok = s };
        },
    }
}

test "both spellings parse, verdicts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s1 = parse(a, "{\"status\":{\"video_status\":\"ready\",\"uploading_phase\":{\"status\":\"complete\",\"bytes_transfered\":10},\"processing_phase\":{\"status\":\"complete\"},\"publishing_phase\":{\"status\":\"complete\",\"publish_status\":\"published\"}}}").?;
    try std.testing.expectEqual(Verdict.published, verdict(s1));
    try std.testing.expectEqual(@as(u64, 10), s1.bytes);
    const s2 = parse(a, "{\"status\":{\"video_status\":\"ready\",\"publishing_phase\":{\"status\":\"completed\",\"publish_status\":\"draft\"}}}").?;
    try std.testing.expectEqual(Verdict.draft, verdict(s2));
    const s3 = parse(a, "{\"status\":{\"video_status\":\"error\",\"processing_phase\":{\"status\":\"error\",\"error\":{\"message\":\"bad\"}}}}").?;
    try std.testing.expectEqual(Verdict.failed, verdict(s3));
    try std.testing.expectEqualStrings("bad", s3.proc_err);
    const s4 = parse(a, "{\"status\":{\"video_status\":\"upload_complete\"}}").?;
    try std.testing.expectEqual(Verdict.uploaded, verdict(s4));
    try std.testing.expectEqual(Verdict.processing, verdict(parse(a, "{\"status\":{\"video_status\":\"processing\"}}").?));
    try std.testing.expectEqual(Verdict.uploading, verdict(parse(a, "{\"status\":{\"video_status\":\"uploading\",\"uploading_phase\":{\"status\":\"in_progress\"}}}").?));
    try std.testing.expectEqual(Verdict.expired, verdict(parse(a, "{\"status\":{\"video_status\":\"expired\"}}").?));
    // ready but not yet published: still processing, never "published"
    try std.testing.expectEqual(Verdict.processing, verdict(parse(a, "{\"status\":{\"video_status\":\"ready\",\"publishing_phase\":{\"status\":\"not_started\"}}}").?));
    // the real spelling seen live on 2026-11-16
    try std.testing.expectEqual(@as(u64, 71830147), parse(a, "{\"status\":{\"video_status\":\"uploading\",\"uploading_phase\":{\"status\":\"in_progress\",\"bytes_transferred\":71830147}}}").?.bytes);
    try std.testing.expect(parse(a, "not json") == null);
    try std.testing.expectEqual(Verdict.unknown, verdict(parse(a, "{\"status\":{}}").?));
}
