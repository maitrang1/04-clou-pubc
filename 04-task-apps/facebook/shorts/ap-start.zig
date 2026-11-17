// Reels step 1: POST {page}/video_reels {"upload_phase":"start"} -> video_id + upload_url (used exactly as returned).
const std = @import("std");
const Ctx = @import("co-ctx.zig").Ctx;
const call = @import("ap-call.zig");
const js = @import("ap-json.zig");

pub const Session = struct { video_id: []const u8, upload_url: []const u8 };

pub fn start(cx: *const Ctx, a: std.mem.Allocator, tok: []const u8, page: []const u8) call.Out(Session) {
    if (!call.idOk(page)) return .{ .fail = .{ .info = .{ .class = .failed, .msg = "page id must be digits" } } };
    const path = std.fmt.allocPrint(a, "{s}/video_reels", .{page}) catch return oom();
    const url = call.graphUrl(cx, a, path) catch return oom();
    const r = call.call(cx, a, .{ .method = "POST", .url = url, .token = tok, .json = "{\"upload_phase\":\"start\"}" });
    switch (r) {
        .fail => |f| return .{ .fail = f },
        .ok => |ok| {
            const v = js.parse(a, ok.body);
            const vid = js.str(v, "video_id");
            const up = js.str(v, "upload_url");
            if (!call.idOk(vid) or up.len == 0) return .{ .fail = .{ .info = .{ .class = .failed, .msg = "start reply has no video_id/upload_url" }, .body = ok.body } };
            return .{ .ok = .{ .video_id = vid, .upload_url = up } };
        },
    }
}

fn oom() call.Out(Session) {
    return .{ .fail = .{ .info = .{ .class = .failed, .msg = "out of memory" } } };
}
