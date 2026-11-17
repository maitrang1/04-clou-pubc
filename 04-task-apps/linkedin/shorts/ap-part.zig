// Upload step 2: PUT one byte range of the file to its signed URL, streamed from disk. NO Authorization header (the URL is the credential), the URL is never logged. The ETag header is the part's id for finalize.
const std = @import("std");
const Ctx = @import("co-ctx.zig").Ctx;
const call = @import("ap-call.zig");
const init_api = @import("ap-init.zig");

pub fn put(cx: *const Ctx, a: std.mem.Allocator, p: init_api.Part, file: []const u8, size: u64) call.Out([]const u8) {
    if (p.last >= size or p.last < p.first) return .{ .fail = .{ .info = .{ .class = .failed, .msg = "part range is outside the file" } } };
    const hs = [_]std.http.Header{.{ .name = "Content-Type", .value = "application/octet-stream" }};
    const r = call.call(cx, a, .{
        .method = "PUT",
        .url = p.url,
        .token = "",
        .rest = false,
        .headers = &hs,
        .timeout_s = cx.cfg.net.upload_timeout_s,
        .label = "PUT upload-part",
        .body_file = .{ .path = file, .offset = p.first, .len = p.last - p.first + 1, .chunk = 256 * 1024 },
    });
    switch (r) {
        .fail => |f| {
            // a 401 here is an expired signed URL, not a dead token
            if (f.http == 401) return .{ .fail = .{ .info = .{ .class = .new_init, .msg = "upload URL expired" }, .http = 401, .sent = f.sent } };
            return .{ .fail = f };
        },
        .ok => |ok| {
            const et = call.header(ok, "etag");
            if (et.len == 0) return .{ .fail = .{ .info = .{ .class = .retry, .msg = "part uploaded but no ETag came back" }, .http = ok.status, .sent = true } };
            return .{ .ok = et };
        },
    }
}
