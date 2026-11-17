// Media step 2: POST the video to upload_url as multipart/form-data. Every upload parameter as a form field (given order), the file last as `file`.
// NO Authorization header (the signed fields are the auth). The file streams from disk through co-net (peak RAM = one chunk).
const std = @import("std");
const Ctx = @import("co-ctx.zig").Ctx;
const call = @import("ap-call.zig");
const media = @import("ap-media.zig");

// header + fields + file-part head (pre) and the closing boundary (post). A name or value with CR/LF/quote is refused: it could split the body.
pub fn build(a: std.mem.Allocator, boundary: []const u8, params: []const media.Param) error{ BadField, OutOfMemory }!struct { pre: []const u8, post: []const u8 } {
    var o: std.ArrayList(u8) = .empty;
    for (params) |p| {
        if (std.mem.indexOfAny(u8, p.k, "\r\n\"") != null or std.mem.indexOfAny(u8, p.v, "\r\n") != null or p.k.len == 0) return error.BadField;
        try o.print(a, "--{s}\r\nContent-Disposition: form-data; name=\"{s}\"\r\n\r\n{s}\r\n", .{ boundary, p.k, p.v });
    }
    try o.print(a, "--{s}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"video.mp4\"\r\nContent-Type: video/mp4\r\n\r\n", .{boundary});
    const post = try std.fmt.allocPrint(a, "\r\n--{s}--\r\n", .{boundary});
    return .{ .pre = o.items, .post = post };
}

pub fn upload(cx: *const Ctx, a: std.mem.Allocator, s: media.Session, file: []const u8, size: u64) call.Out(void) {
    var rnd: [12]u8 = undefined;
    cx.io.random(&rnd);
    const boundary = std.fmt.allocPrint(a, "----pinshor{s}", .{std.fmt.bytesToHex(rnd, .lower)}) catch return .{ .fail = .{ .info = .{ .class = .failed, .msg = "out of memory" } } };
    const parts = build(a, boundary, s.params) catch |e| return .{ .fail = .{ .info = .{ .class = .failed, .msg = if (e == error.BadField) "upload parameter has a bad character" else "out of memory" } } };
    const ct = std.fmt.allocPrint(a, "multipart/form-data; boundary={s}", .{boundary}) catch return .{ .fail = .{ .info = .{ .class = .failed, .msg = "out of memory" } } };
    const r = call.call(cx, a, .{
        .method = "POST",
        .url = s.upload_url,
        .auth = .none,
        .ctype = ct,
        .timeout_s = cx.cfg.net.upload_timeout_s,
        .body_file = .{ .path = file, .offset = 0, .len = size, .chunk = @as(usize, cx.cfg.net.chunk_kb) * 1024, .pre = parts.pre, .post = parts.post },
    });
    switch (r) {
        .fail => |f| return .{ .fail = f },
        .ok => return .{ .ok = {} },
    }
}

test "multipart: fields in order, file last, CRLF and quotes refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ps = [_]media.Param{ .{ .k = "key", .v = "uploads/1" }, .{ .k = "policy", .v = "AbC==" } };
    const p = try build(a, "BB", &ps);
    const ik = std.mem.indexOf(u8, p.pre, "name=\"key\"").?;
    const ip = std.mem.indexOf(u8, p.pre, "name=\"policy\"").?;
    const ifile = std.mem.indexOf(u8, p.pre, "name=\"file\"").?;
    try std.testing.expect(ik < ip and ip < ifile);
    try std.testing.expect(std.mem.endsWith(u8, p.pre, "Content-Type: video/mp4\r\n\r\n"));
    try std.testing.expectEqualStrings("\r\n--BB--\r\n", p.post);
    const bad = [_]media.Param{.{ .k = "k", .v = "a\r\nb" }};
    try std.testing.expectError(error.BadField, build(a, "BB", &bad));
    const bad2 = [_]media.Param{.{ .k = "k\"x", .v = "v" }};
    try std.testing.expectError(error.BadField, build(a, "BB", &bad2));
}
