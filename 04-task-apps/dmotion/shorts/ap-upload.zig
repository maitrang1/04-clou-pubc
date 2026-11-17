// Upload step 2: ONE multipart POST to upload_url, field `file`, streamed from disk (never loaded whole). No Authorization header goes to this host. The answer's `url` is the file_url for create.
const std = @import("std");
const Ctx = @import("co-ctx.zig").Ctx;
const call = @import("ap-call.zig");
const js = @import("ap-json.zig");

// multipart pieces around the file; filename is neutral (config net.upload_name), never the producer's name
pub fn parts(a: std.mem.Allocator, boundary: []const u8, filename: []const u8) !struct { head: []u8, tail: []u8 } {
    const head = try std.fmt.allocPrint(a, "--{s}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"{s}\"\r\nContent-Type: video/mp4\r\n\r\n", .{ boundary, filename });
    const tail = try std.fmt.allocPrint(a, "\r\n--{s}--\r\n", .{boundary});
    return .{ .head = head, .tail = tail };
}

pub fn upload(cx: *const Ctx, a: std.mem.Allocator, upload_url: []const u8, file: []const u8, file_size: u64) call.Out([]const u8) {
    const oomf: call.Out([]const u8) = .{ .fail = .{ .info = .{ .class = .failed, .msg = "out of memory" } } };
    var rnd: [12]u8 = undefined;
    cx.io.random(&rnd);
    const hex = std.fmt.bytesToHex(rnd, .lower);
    const boundary = std.fmt.allocPrint(a, "----dmotshorts{s}", .{hex}) catch return oomf;
    const p = parts(a, boundary, cx.cfg.net.upload_name) catch return oomf;
    const ct = std.fmt.allocPrint(a, "multipart/form-data; boundary={s}", .{boundary}) catch return oomf;
    const hs = [_]std.http.Header{.{ .name = "Content-Type", .value = ct }};
    const r = call.call(cx, a, .{
        .method = "POST",
        .url = upload_url,
        .headers = &hs,
        .timeout_s = cx.cfg.net.upload_timeout_s,
        .body_file = .{ .path = file, .offset = 0, .len = file_size, .chunk = @as(usize, cx.cfg.net.chunk_kb) * 1024 },
        .body_head = p.head,
        .body_tail = p.tail,
    });
    switch (r) {
        .fail => |f| return .{ .fail = f },
        .ok => |ok| {
            const v = js.parse(a, ok.body);
            const u = js.str(v, "url");
            // the reference page shows {filename,status} instead of {url,...}: without a url there is nothing to create from
            if (u.len == 0) return .{ .fail = .{ .info = .{ .class = .failed, .msg = "upload reply has no url" }, .body = ok.body, .sent = true } };
            return .{ .ok = u };
        },
    }
}

test "multipart head and tail" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const p = try parts(arena.allocator(), "BB", "short.mp4");
    try std.testing.expect(std.mem.startsWith(u8, p.head, "--BB\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, p.head, "name=\"file\"; filename=\"short.mp4\"") != null);
    try std.testing.expectEqualStrings("\r\n--BB--\r\n", p.tail);
}
