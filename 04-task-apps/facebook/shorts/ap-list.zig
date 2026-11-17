// Reels step 5 (resolve only): GET {page}/video_reels, newest first, to find a send whose answer was lost.
const std = @import("std");
const Ctx = @import("co-ctx.zig").Ctx;
const call = @import("ap-call.zig");
const js = @import("ap-json.zig");

pub const Item = struct { id: []const u8, updated_time: []const u8, description: []const u8 };

pub fn list(cx: *const Ctx, a: std.mem.Allocator, tok: []const u8, page: []const u8, since_s: i64) call.Out([]const Item) {
    const oomf: call.Out([]const Item) = .{ .fail = .{ .info = .{ .class = .failed, .msg = "out of memory" } } };
    if (!call.idOk(page)) return .{ .fail = .{ .info = .{ .class = .failed, .msg = "page id must be digits" } } };
    const path = std.fmt.allocPrint(a, "{s}/video_reels?fields=id,updated_time,description&since={d}&limit=50", .{ page, @max(0, since_s) }) catch return oomf;
    const url = call.graphUrl(cx, a, path) catch return oomf;
    switch (call.call(cx, a, .{ .url = url, .token = tok })) {
        .fail => |f| return .{ .fail = f },
        .ok => |ok| {
            const root = js.parse(a, ok.body) orelse return .{ .fail = .{ .info = .{ .class = .retry, .msg = "list reply unreadable" }, .body = ok.body } };
            const data = js.obj(root, "data") orelse return .{ .ok = &.{} };
            if (data != .array) return .{ .ok = &.{} };
            var out: std.ArrayList(Item) = .empty;
            for (data.array.items) |it| out.append(a, .{ .id = js.str(it, "id"), .updated_time = js.str(it, "updated_time"), .description = js.str(it, "description") }) catch return oomf;
            return .{ .ok = out.items };
        },
    }
}
