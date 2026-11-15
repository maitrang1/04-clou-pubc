// Step 1: POST /{user}/threads, form-encoded: media_type=VIDEO, video_url, text, topic_tag, reply_control, is_made_with_ai=true -> container id. Nothing is public yet.
const std = @import("std");
const Ctx = @import("co-ctx.zig").Ctx;
const call = @import("ap-call.zig");
const js = @import("ap-json.zig");
const util = @import("co-util.zig");

pub const In = struct { video_url: []const u8, text: []const u8, topic_tag: ?[]const u8 = null, reply_control: []const u8 };

fn oomf() call.Out([]const u8) {
    return .{ .fail = .{ .info = .{ .class = .failed, .msg = "out of memory" } } };
}

// the exact form body (no token): shared with the dry-run print and the tests
pub fn formBody(a: std.mem.Allocator, in: In) ![]u8 {
    var o: std.ArrayList(u8) = .empty;
    errdefer o.deinit(a);
    const fields = [_]struct { k: []const u8, v: []const u8 }{
        .{ .k = "media_type", .v = "VIDEO" },
        .{ .k = "video_url", .v = in.video_url },
        .{ .k = "text", .v = in.text },
        .{ .k = "reply_control", .v = in.reply_control },
        .{ .k = "is_made_with_ai", .v = "true" }, // on the CREATE call, never on threads_publish
    };
    for (fields) |f| {
        if (o.items.len > 0) try o.append(a, '&');
        const e = try util.pct(a, f.v);
        defer a.free(e);
        try o.print(a, "{s}={s}", .{ f.k, e });
    }
    if (in.topic_tag) |t| {
        const e = try util.pct(a, t);
        defer a.free(e);
        try o.print(a, "&topic_tag={s}", .{e});
    }
    return o.toOwnedSlice(a);
}

pub fn create(cx: *const Ctx, a: std.mem.Allocator, tok: []const u8, uid: []const u8, in: In) call.Out([]const u8) {
    if (!call.idOk(uid)) return .{ .fail = .{ .info = .{ .class = .failed, .msg = "user id must be digits" } } };
    const body = formBody(a, in) catch return oomf();
    const path = std.fmt.allocPrint(a, "{s}/threads", .{uid}) catch return oomf();
    const url = call.graphUrl(cx, a, path) catch return oomf();
    switch (call.call(cx, a, .{ .method = "POST", .url = url, .token = tok, .form = body })) {
        .fail => |f| return .{ .fail = f },
        .ok => |ok| {
            const id = js.str(js.parse(a, ok.body), "id");
            if (!call.idOk(id)) return .{ .fail = .{ .info = .{ .class = .failed, .msg = "create reply has no container id" }, .body = ok.body } };
            return .{ .ok = id };
        },
    }
}

test "form body: AI flag on create, topic tag only when given, text encoded" {
    const a = std.testing.allocator;
    const b = try formBody(a, .{ .video_url = "https://h.example/v/ab.mp4", .text = "Hi & bye é", .topic_tag = "cars", .reply_control = "everyone" });
    defer a.free(b);
    try std.testing.expect(std.mem.indexOf(u8, b, "media_type=VIDEO") != null);
    try std.testing.expect(std.mem.indexOf(u8, b, "is_made_with_ai=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, b, "video_url=https%3A%2F%2Fh.example%2Fv%2Fab.mp4") != null);
    try std.testing.expect(std.mem.indexOf(u8, b, "text=Hi%20%26%20bye%20%C3%A9") != null);
    try std.testing.expect(std.mem.indexOf(u8, b, "topic_tag=cars") != null);
    try std.testing.expect(std.mem.indexOf(u8, b, "access_token") == null);
    const b2 = try formBody(a, .{ .video_url = "u", .text = "t", .reply_control = "everyone" });
    defer a.free(b2);
    try std.testing.expect(std.mem.indexOf(u8, b2, "topic_tag") == null);
}
