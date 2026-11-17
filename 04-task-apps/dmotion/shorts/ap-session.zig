// Upload step 1: POST /files/upload_sessions (no body) -> upload_url (used as returned, still through the host allow-list) + progress_url.
const std = @import("std");
const Ctx = @import("co-ctx.zig").Ctx;
const call = @import("ap-call.zig");
const js = @import("ap-json.zig");

pub const Session = struct { upload_url: []const u8, progress_url: []const u8 = "" };

pub fn start(cx: *const Ctx, a: std.mem.Allocator, tok: []const u8) call.Out(Session) {
    const url = call.apiUrl(cx, a, "files/upload_sessions") catch return oom();
    switch (call.call(cx, a, .{ .method = "POST", .url = url, .token = tok })) {
        .fail => |f| return .{ .fail = f },
        .ok => |ok| {
            const v = js.parse(a, ok.body);
            const up = js.str(v, "upload_url");
            if (up.len == 0) return .{ .fail = .{ .info = .{ .class = .failed, .msg = "session reply has no upload_url" }, .body = ok.body } };
            return .{ .ok = .{ .upload_url = up, .progress_url = js.str(v, "progress_url") } };
        },
    }
}

fn oom() call.Out(Session) {
    return .{ .fail = .{ .info = .{ .class = .failed, .msg = "out of memory" } } };
}
