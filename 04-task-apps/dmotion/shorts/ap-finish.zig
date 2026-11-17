// Reels step 4: POST {page}/video_reels upload_phase=finish. The point of no return: once the request left, an unclear answer = unsure.
const std = @import("std");
const Ctx = @import("co-ctx.zig").Ctx;
const call = @import("ap-call.zig");
const js = @import("ap-json.zig");

pub const Done = struct { post_id: []const u8 = "" };
pub const Body = struct { upload_phase: []const u8 = "finish", video_id: []const u8, video_state: []const u8, description: []const u8, title: ?[]const u8 = null, is_ai_generated: bool = true };

pub fn finish(cx: *const Ctx, a: std.mem.Allocator, tok: []const u8, page: []const u8, video_id: []const u8, public: bool, description: []const u8, title: ?[]const u8) call.Out(Done) {
    if (!call.idOk(page) or !call.idOk(video_id)) return .{ .fail = .{ .info = .{ .class = .failed, .msg = "ids must be digits" } } };
    const body = std.json.Stringify.valueAlloc(a, Body{ .video_id = video_id, .video_state = if (public) "PUBLISHED" else "DRAFT", .description = description, .title = title }, .{ .emit_null_optional_fields = false }) catch return .{ .fail = .{ .info = .{ .class = .failed, .msg = "out of memory" } } };
    const path = std.fmt.allocPrint(a, "{s}/video_reels", .{page}) catch return .{ .fail = .{ .info = .{ .class = .failed, .msg = "out of memory" } } };
    const url = call.graphUrl(cx, a, path) catch return .{ .fail = .{ .info = .{ .class = .failed, .msg = "out of memory" } } };
    switch (call.call(cx, a, .{ .method = "POST", .url = url, .token = tok, .json = body })) {
        .fail => |f| return .{ .fail = f },
        .ok => |ok| {
            const v = js.parse(a, ok.body);
            // an answer we cannot read after the request left is unclear, not failed
            if (!js.boolean(v, "success")) return .{ .fail = .{ .info = .{ .class = .retry, .msg = "finish reply has no success:true" }, .body = ok.body, .sent = true } };
            return .{ .ok = .{ .post_id = js.str(v, "post_id") } };
        },
    }
}
