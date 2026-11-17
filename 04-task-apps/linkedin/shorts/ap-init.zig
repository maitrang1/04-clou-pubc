// Upload step 1: POST /rest/videos?action=initializeUpload -> video URN, upload token, and the byte ranges + signed URLs to PUT. The server's ranges rule; the docs' "4 MB" text is only a hint.
const std = @import("std");
const Ctx = @import("co-ctx.zig").Ctx;
const call = @import("ap-call.zig");
const js = @import("ap-json.zig");

pub const Part = struct { first: u64, last: u64, url: []const u8 };
pub const Session = struct { video: []const u8, token: []const u8, expires_ms: i64, parts: []const Part };

const Req = struct { initializeUploadRequest: struct { owner: []const u8, fileSizeBytes: u64, uploadCaptions: bool = false, uploadThumbnail: bool = false } };

fn oomf() call.Out(Session) {
    return .{ .fail = .{ .info = .{ .class = .failed, .msg = "out of memory" } } };
}
fn badf(msg: []const u8, body: []const u8) call.Out(Session) {
    return .{ .fail = .{ .info = .{ .class = .failed, .msg = msg }, .body = body } };
}

// the reply may or may not wrap itself in "value": accept both
pub fn parse(a: std.mem.Allocator, body: []const u8) ?Session {
    const root = js.parse(a, body) orelse return null;
    const v = js.obj(root, "value") orelse root;
    const video = js.str(v, "video");
    const ins = js.obj(v, "uploadInstructions") orelse return null;
    if (ins != .array or ins.array.items.len == 0 or video.len == 0) return null;
    var parts: std.ArrayList(Part) = .empty;
    for (ins.array.items) |it| {
        const url = js.str(it, "uploadUrl");
        const first = js.int(it, "firstByte");
        const last = js.int(it, "lastByte");
        if (url.len == 0 or first < 0 or last < first) return null;
        parts.append(a, .{ .first = @intCast(first), .last = @intCast(last), .url = url }) catch return null;
    }
    return .{ .video = video, .token = js.str(v, "uploadToken"), .expires_ms = js.int(v, "uploadUrlsExpireAt"), .parts = parts.items };
}

// ranges must tile the file exactly: sorted, no gap, no overlap, end at size-1
pub fn tiles(parts: []const Part, size: u64) bool {
    var next: u64 = 0;
    for (parts) |p| {
        if (p.first != next) return false;
        next = p.last + 1;
    }
    return size > 0 and next == size;
}

pub fn start(cx: *const Ctx, a: std.mem.Allocator, tok: []const u8, person: []const u8, size: u64) call.Out(Session) {
    if (!call.idOk(person)) return badf("person id has odd characters", "");
    const owner = std.fmt.allocPrint(a, "urn:li:person:{s}", .{person}) catch return oomf();
    const body = std.json.Stringify.valueAlloc(a, Req{ .initializeUploadRequest = .{ .owner = owner, .fileSizeBytes = size } }, .{}) catch return oomf();
    const url = call.restUrl(cx, a, "videos?action=initializeUpload") catch return oomf();
    switch (call.call(cx, a, .{ .method = "POST", .url = url, .token = tok, .json = body, .label = "POST /rest/videos?action=initializeUpload" })) {
        .fail => |f| return .{ .fail = f },
        .ok => |ok| {
            const s = parse(a, ok.body) orelse return badf("initializeUpload reply has no video/uploadInstructions", ok.body);
            if (!call.urnOk(s.video, "video")) return badf("initializeUpload returned a video id with odd characters", "");
            if (!tiles(s.parts, size)) return badf("upload ranges do not cover the file exactly", "");
            return .{ .ok = s };
        },
    }
}

test "reply parses with and without the value wrapper; ranges must tile" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const w = "{\"value\":{\"uploadUrlsExpireAt\":1633234498985,\"video\":\"urn:li:video:C5505AQH-oV1qvnFtKA\",\"uploadInstructions\":[{\"uploadUrl\":\"https://x/1\",\"firstByte\":0,\"lastByte\":4194303},{\"uploadUrl\":\"https://x/2\",\"firstByte\":4194304,\"lastByte\":5000000}],\"uploadToken\":\"\"}}";
    const s = parse(a, w).?;
    try std.testing.expectEqual(@as(usize, 2), s.parts.len);
    try std.testing.expectEqualStrings("", s.token);
    try std.testing.expect(tiles(s.parts, 5000001));
    try std.testing.expect(!tiles(s.parts, 5000000));
    const bare = parse(a, "{\"video\":\"urn:li:video:A\",\"uploadInstructions\":[{\"uploadUrl\":\"https://x\",\"firstByte\":0,\"lastByte\":9}],\"uploadToken\":\"T\"}").?;
    try std.testing.expectEqualStrings("T", bare.token);
    try std.testing.expect(parse(a, "{\"value\":{\"video\":\"urn:li:video:A\",\"uploadInstructions\":[]}}") == null);
    try std.testing.expect(parse(a, "nope") == null);
    const gap = [_]Part{ .{ .first = 0, .last = 9, .url = "u" }, .{ .first = 11, .last = 20, .url = "u" } };
    try std.testing.expect(!tiles(&gap, 21));
}
