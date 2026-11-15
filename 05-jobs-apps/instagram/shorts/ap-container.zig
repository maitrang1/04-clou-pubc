// Step 1: POST {ig-user}/media (media_type=REELS, upload_type=resumable) -> container id + uri (used exactly as returned). No video_url: nothing is hosted publicly.
const std = @import("std");
const Ctx = @import("co-ctx.zig").Ctx;
const call = @import("ap-call.zig");
const js = @import("ap-json.zig");

pub const Session = struct { cont_id: []const u8, uri: []const u8 };
pub const Body = struct { media_type: []const u8 = "REELS", upload_type: []const u8 = "resumable", caption: []const u8, share_to_feed: bool, thumb_offset: u32, is_ai_generated: bool = true };

pub fn create(cx: *const Ctx, a: std.mem.Allocator, tok: []const u8, ig: []const u8, caption: []const u8) call.Out(Session) {
    if (!call.idOk(ig)) return .{ .fail = .{ .info = .{ .class = .failed, .msg = "Instagram user id must be digits" } } };
    const body = std.json.Stringify.valueAlloc(a, Body{ .caption = caption, .share_to_feed = cx.cfg.post.share_to_feed, .thumb_offset = cx.cfg.post.thumb_offset_ms }, .{}) catch return oom();
    const path = std.fmt.allocPrint(a, "{s}/media", .{ig}) catch return oom();
    const url = call.graphUrl(cx, a, path) catch return oom();
    switch (call.call(cx, a, .{ .method = "POST", .url = url, .token = tok, .json = body })) {
        .fail => |f| return .{ .fail = f },
        .ok => |ok| {
            const v = js.parse(a, ok.body);
            const cid = js.str(v, "id");
            const uri = js.str(v, "uri");
            if (!call.idOk(cid) or uri.len == 0) return .{ .fail = .{ .info = .{ .class = .failed, .msg = "container reply has no id/uri" }, .body = ok.body } };
            return .{ .ok = .{ .cont_id = cid, .uri = uri } };
        },
    }
}

fn oom() call.Out(Session) {
    return .{ .fail = .{ .info = .{ .class = .failed, .msg = "out of memory" } } };
}
