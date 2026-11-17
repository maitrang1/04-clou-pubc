// Reels step 2: POST upload_url, octet-stream, offset + file_size headers. ONE streamed POST from disk (never loaded whole); resume = new POST with offset.
const std = @import("std");
const Ctx = @import("co-ctx.zig").Ctx;
const call = @import("ap-call.zig");
const js = @import("ap-json.zig");

pub fn upload(cx: *const Ctx, a: std.mem.Allocator, tok: []const u8, upload_url: []const u8, file: []const u8, file_size: u64, offset: u64) call.Out(void) {
    if (offset > file_size) return .{ .fail = .{ .info = .{ .class = .failed, .msg = "offset past end of file" } } };
    const off_s = std.fmt.allocPrint(a, "{d}", .{offset}) catch return oom();
    const size_s = std.fmt.allocPrint(a, "{d}", .{file_size}) catch return oom();
    const hs = [_]std.http.Header{
        .{ .name = "Content-Type", .value = "application/octet-stream" },
        .{ .name = "offset", .value = off_s },
        .{ .name = "file_size", .value = size_s },
    };
    const r = call.call(cx, a, .{
        .method = "POST",
        .url = upload_url,
        .token = tok,
        .headers = &hs,
        .timeout_s = cx.cfg.net.upload_timeout_s,
        .body_file = .{ .path = file, .offset = offset, .len = file_size - offset, .chunk = @as(usize, cx.cfg.net.chunk_kb) * 1024 },
    });
    switch (r) {
        .fail => |f| return .{ .fail = f },
        .ok => |ok| {
            if (!js.boolean(js.parse(a, ok.body), "success")) return .{ .fail = .{ .info = .{ .class = .failed, .msg = "upload reply has no success:true" }, .body = ok.body, .sent = true } };
            return .{ .ok = {} };
        },
    }
}

fn oom() call.Out(void) {
    return .{ .fail = .{ .info = .{ .class = .failed, .msg = "out of memory" } } };
}
