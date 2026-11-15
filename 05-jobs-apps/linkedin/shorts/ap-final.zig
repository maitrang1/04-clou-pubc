// Upload step 3: POST /rest/videos?action=finalizeUpload with the ETags in part order. Reversible: a finalized video is still not a post.
const std = @import("std");
const Ctx = @import("co-ctx.zig").Ctx;
const call = @import("ap-call.zig");

const Req = struct { finalizeUploadRequest: struct { video: []const u8, uploadToken: []const u8, uploadedPartIds: []const []const u8 } };

pub fn finalize(cx: *const Ctx, a: std.mem.Allocator, tok: []const u8, video: []const u8, upload_token: []const u8, etags: []const []const u8) call.Out(void) {
    if (!call.urnOk(video, "video")) return .{ .fail = .{ .info = .{ .class = .failed, .msg = "video urn has odd characters" } } };
    const body = std.json.Stringify.valueAlloc(a, Req{ .finalizeUploadRequest = .{ .video = video, .uploadToken = upload_token, .uploadedPartIds = etags } }, .{}) catch return .{ .fail = .{ .info = .{ .class = .failed, .msg = "out of memory" } } };
    const url = call.restUrl(cx, a, "videos?action=finalizeUpload") catch return .{ .fail = .{ .info = .{ .class = .failed, .msg = "out of memory" } } };
    switch (call.call(cx, a, .{ .method = "POST", .url = url, .token = tok, .json = body, .label = "POST /rest/videos?action=finalizeUpload" })) {
        .fail => |f| return .{ .fail = f },
        .ok => return .{ .ok = {} },
    }
}
