// Upload step 3: POST /profiles/{id}/videos. The point of no return: once the request left, an unclear answer = unsure (no idempotency key exists).
const std = @import("std");
const Ctx = @import("co-ctx.zig").Ctx;
const call = @import("ap-call.zig");
const js = @import("ap-json.zig");

pub const Created = struct { video_id: []const u8, url: []const u8 = "" };
pub const In = struct {
    title: []const u8,
    description: []const u8,
    hashtags: []const []const u8 = &.{},
    file_url: []const u8,
    public: bool = false,
    for_kids: bool = false,
    comments: bool = false,
    language: []const u8 = "",
    country: []const u8 = "",
    category: ?[]const u8 = null, // null = not sent (category_mode without)
};

const Src = struct { file_url: []const u8 };
// field names are Dailymotion's (v2 create-profile-video); optional ones are left out when null
const Body = struct {
    title: []const u8,
    description: []const u8,
    visibility: []const u8,
    is_for_kids: bool,
    is_ai_altered: bool = true, // AI label on every post, no switch
    is_explicit: bool = false,
    can_be_stitched: bool = false,
    has_paid_partnership: bool = false,
    is_exclusive_content: bool = false,
    enable_comments: ?bool = null,
    language: ?[]const u8 = null,
    country: ?[]const u8 = null,
    hashtags: []const []const u8 = &.{},
    category: ?[]const u8 = null,
    source: Src,
};

pub fn bodyJson(a: std.mem.Allocator, in: In) ![]u8 {
    const b = Body{
        .title = in.title,
        .description = in.description,
        .visibility = if (in.public) "public" else "private",
        .is_for_kids = in.for_kids,
        .enable_comments = if (in.for_kids) null else in.comments, // a kids video refuses comments (403)
        .language = if (in.language.len > 0) in.language else null,
        .country = if (in.country.len > 0) in.country else null,
        .hashtags = in.hashtags,
        .category = in.category,
        .source = .{ .file_url = in.file_url },
    };
    return std.json.Stringify.valueAlloc(a, b, .{ .emit_null_optional_fields = false });
}

fn lastSegment(s: []const u8) []const u8 {
    const t = std.mem.trimEnd(u8, s, "/");
    const i = std.mem.lastIndexOfScalar(u8, t, '/') orelse return t;
    return t[i + 1 ..];
}

pub fn create(cx: *const Ctx, a: std.mem.Allocator, tok: []const u8, profile: []const u8, in: In) call.Out(Created) {
    const oomf: call.Out(Created) = .{ .fail = .{ .info = .{ .class = .failed, .msg = "out of memory" } } };
    if (!call.idOk(profile)) return .{ .fail = .{ .info = .{ .class = .failed, .msg = "profile id has odd characters" } } };
    const body = bodyJson(a, in) catch return oomf;
    const path = std.fmt.allocPrint(a, "profiles/{s}/videos", .{profile}) catch return oomf;
    const url = call.apiUrl(cx, a, path) catch return oomf;
    switch (call.call(cx, a, .{ .method = "POST", .url = url, .token = tok, .json = body })) {
        .fail => |f| return .{ .fail = f },
        .ok => |ok| {
            const v = js.parse(a, ok.body);
            // the guide's example says video_id, its prose says id, the Location header carries it too
            var vid = js.str(v, "video_id");
            if (vid.len == 0) vid = js.str(v, "id");
            if (vid.len == 0) vid = lastSegment(ok.location);
            // an answer we cannot read after the request left is unclear, not failed
            if (!call.idOk(vid)) return .{ .fail = .{ .info = .{ .class = .retry, .msg = "create reply has no video id" }, .body = ok.body, .sent = true } };
            return .{ .ok = .{ .video_id = vid, .url = js.str(v, "video_url") } };
        },
    }
}

test "body: private by default, AI label on, kids flag explicit, optional fields left out" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const j = try bodyJson(a, .{ .title = "T", .description = "D", .file_url = "https://u/f" });
    try std.testing.expect(std.mem.indexOf(u8, j, "\"visibility\":\"private\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, j, "\"is_ai_altered\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, j, "\"is_for_kids\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, j, "\"enable_comments\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, j, "category") == null);
    try std.testing.expect(std.mem.indexOf(u8, j, "language") == null);
    try std.testing.expect(std.mem.indexOf(u8, j, "\"source\":{\"file_url\":\"https://u/f\"}") != null);
    const k = try bodyJson(a, .{ .title = "T", .description = "D", .file_url = "x", .for_kids = true, .comments = true, .public = true, .category = "auto", .language = "vi", .country = "VN" });
    try std.testing.expect(std.mem.indexOf(u8, k, "enable_comments") == null); // kids: never sent
    try std.testing.expect(std.mem.indexOf(u8, k, "\"visibility\":\"public\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, k, "\"category\":\"auto\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, k, "\"language\":\"vi\"") != null);
}

test "last segment of a Location" {
    try std.testing.expectEqualStrings("x9xyz456", lastSegment("https://api.dailymotion.com/v2/profiles/p/videos/x9xyz456"));
    try std.testing.expectEqualStrings("", lastSegment(""));
}
