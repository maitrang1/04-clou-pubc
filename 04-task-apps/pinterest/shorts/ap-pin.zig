// Pin step 4: POST /pins with media_source video_id. THE point of no return: once the request left, an unclear answer = unsure.
// The AI label (ai_disclosures) rides on every create; there is no switch.
const std = @import("std");
const Ctx = @import("co-ctx.zig").Ctx;
const call = @import("ap-call.zig");
const js = @import("ap-json.zig");

pub const Cover = union(enum) { key_frame: u32, data: struct { b64: []const u8, content_type: []const u8 } };
pub const In = struct { board_id: []const u8, section_id: ?[]const u8 = null, title: ?[]const u8 = null, description: []const u8, alt_text: ?[]const u8 = null, link: ?[]const u8 = null, ai_values: []const []const u8, media_id: []const u8, cover: Cover };
pub const Created = struct { id: []const u8 };

const MediaSrc = struct { source_type: []const u8 = "video_id", media_id: []const u8, cover_image_key_frame_time: ?u32 = null, cover_image_data: ?[]const u8 = null, cover_image_content_type: ?[]const u8 = null };
const Ai = struct { values: []const []const u8 };
const Body = struct { board_id: []const u8, board_section_id: ?[]const u8 = null, title: ?[]const u8 = null, description: []const u8, alt_text: ?[]const u8 = null, link: ?[]const u8 = null, ai_disclosures: Ai, media_source: MediaSrc };

pub fn body(a: std.mem.Allocator, in: In) ![]u8 {
    var ms = MediaSrc{ .media_id = in.media_id };
    switch (in.cover) {
        .key_frame => |s| ms.cover_image_key_frame_time = s,
        .data => |d| {
            ms.cover_image_data = d.b64;
            ms.cover_image_content_type = d.content_type;
        },
    }
    return std.json.Stringify.valueAlloc(a, Body{ .board_id = in.board_id, .board_section_id = in.section_id, .title = in.title, .description = in.description, .alt_text = in.alt_text, .link = in.link, .ai_disclosures = .{ .values = in.ai_values }, .media_source = ms }, .{ .emit_null_optional_fields = false });
}

pub fn create(cx: *const Ctx, a: std.mem.Allocator, tok: []const u8, in: In) call.Out(Created) {
    const oomf: call.Out(Created) = .{ .fail = .{ .info = .{ .class = .failed, .msg = "out of memory" } } };
    if (!call.idOk(in.board_id) or !call.idOk(in.media_id)) return .{ .fail = .{ .info = .{ .class = .failed, .msg = "board and media ids must be digits" } } };
    const b = body(a, in) catch return oomf;
    const url = call.apiUrl(cx, a, "pins") catch return oomf;
    switch (call.call(cx, a, .{ .method = "POST", .url = url, .auth = .{ .bearer = tok }, .body = b })) {
        .fail => |f| return .{ .fail = f },
        .ok => |ok| {
            const v = js.parse(a, ok.body);
            var id = js.str(v, "id");
            if (id.len == 0) {
                const n = js.int(v, "id");
                if (n > 0) id = std.fmt.allocPrint(a, "{d}", .{n}) catch return oomf;
            }
            // a 2xx without an id after the request left is unclear, not failed
            if (!call.idOk(id)) return .{ .fail = .{ .info = .{ .class = .retry, .msg = "create reply has no pin id" }, .body = ok.body, .sent = true } };
            return .{ .ok = .{ .id = id } };
        },
    }
}

test "body carries the AI label, cover choice, optional fields only when set" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const b = try body(a, .{ .board_id = "11", .title = "T", .description = "D", .ai_values = &.{"AI_MODIFIED"}, .media_id = "22", .cover = .{ .key_frame = 1 } });
    try std.testing.expect(std.mem.indexOf(u8, b, "\"ai_disclosures\":{\"values\":[\"AI_MODIFIED\"]}") != null);
    try std.testing.expect(std.mem.indexOf(u8, b, "\"source_type\":\"video_id\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, b, "\"cover_image_key_frame_time\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, b, "link") == null);
    try std.testing.expect(std.mem.indexOf(u8, b, "cover_image_data") == null);
    const c = try body(a, .{ .board_id = "11", .description = "D", .link = "https://x.y/z", .ai_values = &.{"AI_MODIFIED"}, .media_id = "22", .cover = .{ .data = .{ .b64 = "QUJD", .content_type = "image/jpeg" } } });
    try std.testing.expect(std.mem.indexOf(u8, c, "\"cover_image_data\":\"QUJD\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, c, "\"link\":\"https://x.y/z\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, c, "key_frame") == null);
}
