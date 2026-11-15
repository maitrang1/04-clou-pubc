// Reads about posts: one by id (confirm after publish) and the account's recent list (resolve and the lost-ledger probe). Needs only threads_basic. Read-only.
const std = @import("std");
const Ctx = @import("co-ctx.zig").Ctx;
const call = @import("ap-call.zig");
const js = @import("ap-json.zig");

pub const Item = struct { id: []const u8 = "", permalink: []const u8 = "", text: []const u8 = "", timestamp: []const u8 = "", media_type: []const u8 = "" };
const fields = "id,permalink,text,timestamp,media_type";

fn oomf(comptime T: type) call.Out(T) {
    return .{ .fail = .{ .info = .{ .class = .failed, .msg = "out of memory" } } };
}

pub fn itemOf(v: ?std.json.Value) Item {
    return .{ .id = js.str(v, "id"), .permalink = js.str(v, "permalink"), .text = js.str(v, "text"), .timestamp = js.str(v, "timestamp"), .media_type = js.str(v, "media_type") };
}

// GET /{media-id}?fields=...
pub fn media(cx: *const Ctx, a: std.mem.Allocator, tok: []const u8, media_id: []const u8) call.Out(Item) {
    if (!call.idOk(media_id)) return .{ .fail = .{ .info = .{ .class = .failed, .msg = "post id must be digits" } } };
    const path = std.fmt.allocPrint(a, "{s}?fields={s}", .{ media_id, fields }) catch return oomf(Item);
    const url = call.graphUrl(cx, a, path) catch return oomf(Item);
    switch (call.call(cx, a, .{ .url = url, .token = tok })) {
        .fail => |f| return .{ .fail = f },
        .ok => |ok| {
            const root = js.parse(a, ok.body) orelse return .{ .fail = .{ .info = .{ .class = .retry, .msg = "post reply unreadable" }, .body = ok.body } };
            return .{ .ok = itemOf(root) };
        },
    }
}

// GET /{user}/threads?fields=...&since=<unix s>&limit=N (newest first)
pub fn list(cx: *const Ctx, a: std.mem.Allocator, tok: []const u8, uid: []const u8, since_s: i64) call.Out([]const Item) {
    if (!call.idOk(uid)) return .{ .fail = .{ .info = .{ .class = .failed, .msg = "user id must be digits" } } };
    const path = std.fmt.allocPrint(a, "{s}/threads?fields={s}&since={d}&limit=50", .{ uid, fields, @max(0, since_s) }) catch return oomf([]const Item);
    const url = call.graphUrl(cx, a, path) catch return oomf([]const Item);
    switch (call.call(cx, a, .{ .url = url, .token = tok })) {
        .fail => |f| return .{ .fail = f },
        .ok => |ok| {
            const root = js.parse(a, ok.body) orelse return .{ .fail = .{ .info = .{ .class = .retry, .msg = "list reply unreadable" }, .body = ok.body } };
            const data = js.obj(root, "data") orelse return .{ .ok = &.{} };
            if (data != .array) return .{ .ok = &.{} };
            var out: std.ArrayList(Item) = .empty;
            for (data.array.items) |it| out.append(a, itemOf(it)) catch return oomf([]const Item);
            return .{ .ok = out.items };
        },
    }
}
