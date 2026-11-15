// Publish step: POST /rest/posts with the video. THE point of no return: once the request left, an unclear answer = unsure. 201 + x-restli-id header = the post URN (the body is empty).
const std = @import("std");
const Ctx = @import("co-ctx.zig").Ctx;
const call = @import("ap-call.zig");

pub const Done = struct { urn: []const u8 };
const Dist = struct { feedDistribution: []const u8 = "MAIN_FEED", targetEntities: []const []const u8 = &.{}, thirdPartyDistributionChannels: []const []const u8 = &.{} };
const Media = struct { title: []const u8, id: []const u8 };
pub const Body = struct { author: []const u8, commentary: []const u8, visibility: []const u8, distribution: Dist = .{}, content: struct { media: Media }, lifecycleState: []const u8 = "PUBLISHED", isReshareDisabledByAuthor: bool = false };

pub fn postUrnOk(urn: []const u8) bool {
    return call.urnOk(urn, "share") or call.urnOk(urn, "ugcPost");
}

pub fn bodyJson(a: std.mem.Allocator, author: []const u8, commentary: []const u8, title: []const u8, video: []const u8, visibility: []const u8, reshare_off: bool) ![]u8 {
    return std.json.Stringify.valueAlloc(a, Body{ .author = author, .commentary = commentary, .visibility = visibility, .content = .{ .media = .{ .title = title, .id = video } }, .isReshareDisabledByAuthor = reshare_off }, .{});
}

pub fn create(cx: *const Ctx, a: std.mem.Allocator, tok: []const u8, person: []const u8, video: []const u8, commentary: []const u8, title: []const u8) call.Out(Done) {
    const oomf: call.Out(Done) = .{ .fail = .{ .info = .{ .class = .failed, .msg = "out of memory" } } };
    if (!call.idOk(person) or !call.urnOk(video, "video")) return .{ .fail = .{ .info = .{ .class = .failed, .msg = "person id or video urn has odd characters" } } };
    const author = std.fmt.allocPrint(a, "urn:li:person:{s}", .{person}) catch return oomf;
    const body = bodyJson(a, author, commentary, title, video, cx.cfg.post.visibility, cx.cfg.post.reshare_disabled) catch return oomf;
    const url = call.restUrl(cx, a, "posts") catch return oomf;
    switch (call.call(cx, a, .{ .method = "POST", .url = url, .token = tok, .json = body, .label = "POST /rest/posts" })) {
        .fail => |f| return .{ .fail = f },
        .ok => |ok| {
            const urn = call.header(ok, "x-restli-id");
            // a 2xx without the id: a post may exist, its URN is lost: unclear, not failed
            if (!postUrnOk(urn)) return .{ .fail = .{ .info = .{ .class = .retry, .msg = "post answered ok but gave no usable x-restli-id" }, .http = ok.status, .sent = true } };
            return .{ .ok = .{ .urn = urn } };
        },
    }
}

test "post body carries the video, the notice text and PUBLISHED" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const j = try bodyJson(arena.allocator(), "urn:li:person:P1", "hello \\# world", "T", "urn:li:video:V1", "PUBLIC", false);
    try std.testing.expect(std.mem.indexOf(u8, j, "\"lifecycleState\":\"PUBLISHED\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, j, "\"id\":\"urn:li:video:V1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, j, "\"feedDistribution\":\"MAIN_FEED\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, j, "\"author\":\"urn:li:person:P1\"") != null);
    try std.testing.expect(postUrnOk("urn:li:share:123"));
    try std.testing.expect(postUrnOk("urn:li:ugcPost:123"));
    try std.testing.expect(!postUrnOk(""));
    try std.testing.expect(!postUrnOk("urn:li:person:123"));
}
