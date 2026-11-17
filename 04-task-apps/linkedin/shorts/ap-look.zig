// Look up a post we already have a URN for (resolve only): GET /rest/posts/{urn}?viewContext=AUTHOR. There is NO search of own posts with the open scope (q=author needs r_member_social, closed).
const std = @import("std");
const Ctx = @import("co-ctx.zig").Ctx;
const call = @import("ap-call.zig");
const js = @import("ap-json.zig");
const post_api = @import("ap-post.zig");

pub const Found = struct { state: []const u8, published_at: i64 };

pub fn get(cx: *const Ctx, a: std.mem.Allocator, tok: []const u8, urn: []const u8) call.Out(Found) {
    const oomf: call.Out(Found) = .{ .fail = .{ .info = .{ .class = .failed, .msg = "out of memory" } } };
    if (!post_api.postUrnOk(urn)) return .{ .fail = .{ .info = .{ .class = .failed, .msg = "post urn must look like urn:li:share:... or urn:li:ugcPost:..." } } };
    const enc = call.urnEnc(a, urn) catch return oomf;
    const path = std.fmt.allocPrint(a, "posts/{s}?viewContext=AUTHOR", .{enc}) catch return oomf;
    const url = call.restUrl(cx, a, path) catch return oomf;
    switch (call.call(cx, a, .{ .url = url, .token = tok, .label = "GET /rest/posts/{urn}" })) {
        .fail => |f| return .{ .fail = f },
        .ok => |ok| {
            const root = js.parse(a, ok.body) orelse return .{ .fail = .{ .info = .{ .class = .retry, .msg = "post reply unreadable" }, .body = ok.body } };
            return .{ .ok = .{ .state = js.str(root, "lifecycleState"), .published_at = js.int(root, "publishedAt") } };
        },
    }
}
