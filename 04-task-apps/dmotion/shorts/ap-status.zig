// GET /videos/{id}?fields=...: encoding state, publish flag, source facts (width/height/checksum), access_error. Tolerant: every field optional.
const std = @import("std");
const Ctx = @import("co-ctx.zig").Ctx;
const call = @import("ap-call.zig");
const js = @import("ap-json.zig");
const err = @import("ap-error.zig");

pub const Status = struct {
    video_id: []const u8 = "",
    title: []const u8 = "",
    encoding: []const u8 = "", // waiting_for_upload | uploaded | encoding | encoded | error
    progress: i64 = 0,
    is_published: bool = false,
    video_url: []const u8 = "",
    created_at: []const u8 = "",
    visibility: []const u8 = "",
    checksum: []const u8 = "",
    width: i64 = 0,
    height: i64 = 0,
    access_error: []const u8 = "",
};
pub const Verdict = enum { waiting, encoding, encoded, failed, flagged, unknown };

const fields = "video_id,title,is_published,processing,video_url,created_at,visibility,source";

pub fn parseOne(a: std.mem.Allocator, v: ?std.json.Value) Status {
    const pr = js.obj(v, "processing");
    const src = js.obj(v, "source");
    return .{
        .video_id = js.str(v, "video_id"),
        .title = js.str(v, "title"),
        .encoding = js.str(pr, "encoding_status"),
        .progress = js.int(pr, "encoding_progress"),
        .is_published = js.boolean(v, "is_published"),
        .video_url = js.str(v, "video_url"),
        .created_at = js.str(v, "created_at"),
        .visibility = js.str(v, "visibility"),
        .checksum = js.str(src, "checksum"),
        .width = js.int(src, "width"),
        .height = js.int(src, "height"),
        .access_error = blk: {
            _ = a;
            const x = js.obj(v, "access_error") orelse break :blk "";
            break :blk if (x == .string) x.string else js.str(x, "code");
        },
    };
}

pub fn parse(a: std.mem.Allocator, body: []const u8) ?Status {
    const root = js.parse(a, body) orelse return null;
    if (root != .object) return null;
    return parseOne(a, root);
}

pub fn verdict(a: std.mem.Allocator, s: Status) Verdict {
    const eq = std.mem.eql;
    if (s.access_error.len > 0) if (err.accessClass(a, s.access_error)) |c| switch (c) {
        .breaker => return .flagged,
        .failed => return .failed,
        else => {},
    };
    if (eq(u8, s.encoding, "error")) return .failed;
    if (eq(u8, s.encoding, "encoded")) return .encoded;
    if (eq(u8, s.encoding, "encoding")) return .encoding;
    if (eq(u8, s.encoding, "uploaded") or eq(u8, s.encoding, "waiting_for_upload")) return .waiting;
    return .unknown;
}

pub fn get(cx: *const Ctx, a: std.mem.Allocator, tok: []const u8, video_id: []const u8) call.Out(Status) {
    if (!call.idOk(video_id)) return .{ .fail = .{ .info = .{ .class = .failed, .msg = "video id has odd characters" } } };
    const path = std.fmt.allocPrint(a, "videos/{s}?fields={s}", .{ video_id, fields }) catch return .{ .fail = .{ .info = .{ .class = .failed, .msg = "out of memory" } } };
    const url = call.apiUrl(cx, a, path) catch return .{ .fail = .{ .info = .{ .class = .failed, .msg = "out of memory" } } };
    switch (call.call(cx, a, .{ .url = url, .token = tok })) {
        .fail => |f| return .{ .fail = f },
        .ok => |ok| {
            const s = parse(a, ok.body) orelse return .{ .fail = .{ .info = .{ .class = .retry, .msg = "status reply unreadable" }, .body = ok.body } };
            return .{ .ok = s };
        },
    }
}

test "states and access errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s1 = parse(a, "{\"video_id\":\"x1\",\"title\":\"T\",\"is_published\":true,\"processing\":{\"encoding_status\":\"encoded\",\"encoding_progress\":100},\"source\":{\"width\":1080,\"height\":1920,\"checksum\":\"ab\"}}").?;
    try std.testing.expectEqual(Verdict.encoded, verdict(a, s1));
    try std.testing.expectEqual(@as(i64, 1920), s1.height);
    try std.testing.expectEqualStrings("ab", s1.checksum);
    try std.testing.expectEqual(Verdict.encoding, verdict(a, parse(a, "{\"processing\":{\"encoding_status\":\"encoding\"}}").?));
    try std.testing.expectEqual(Verdict.waiting, verdict(a, parse(a, "{\"processing\":{\"encoding_status\":\"uploaded\"}}").?));
    try std.testing.expectEqual(Verdict.failed, verdict(a, parse(a, "{\"processing\":{\"encoding_status\":\"error\"}}").?));
    try std.testing.expectEqual(Verdict.flagged, verdict(a, parse(a, "{\"access_error\":\"DM005\"}").?));
    try std.testing.expectEqual(Verdict.failed, verdict(a, parse(a, "{\"access_error\":{\"code\":\"DM011\"}}").?));
    try std.testing.expectEqual(Verdict.unknown, verdict(a, parse(a, "{}").?));
    try std.testing.expect(parse(a, "not json") == null);
}
