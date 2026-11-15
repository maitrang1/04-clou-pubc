// Step 5 (resolve + after publish): recent media of the account (time-paged, since=<unix>) and one media's permalink / AI flag. Field names that Meta rejects fall back to ids only.
const std = @import("std");
const Ctx = @import("co-ctx.zig").Ctx;
const call = @import("ap-call.zig");
const js = @import("ap-json.zig");

pub const Item = struct { id: []const u8, caption: []const u8 = "", permalink: []const u8 = "", product: []const u8 = "", timestamp: []const u8 = "" };

fn read(a: std.mem.Allocator, body: []const u8) ?[]const Item {
    const root = js.parse(a, body) orelse return null;
    const data = js.obj(root, "data") orelse return &.{};
    if (data != .array) return &.{};
    var out: std.ArrayList(Item) = .empty;
    for (data.array.items) |it| out.append(a, .{ .id = js.str(it, "id"), .caption = js.str(it, "caption"), .permalink = js.str(it, "permalink"), .product = js.str(it, "media_product_type"), .timestamp = js.str(it, "timestamp") }) catch return null;
    return out.items;
}

pub fn list(cx: *const Ctx, a: std.mem.Allocator, tok: []const u8, ig: []const u8, since_s: i64) call.Out([]const Item) {
    const oomf: call.Out([]const Item) = .{ .fail = .{ .info = .{ .class = .failed, .msg = "out of memory" } } };
    if (!call.idOk(ig)) return .{ .fail = .{ .info = .{ .class = .failed, .msg = "Instagram user id must be digits" } } };
    const fields = [_][]const u8{ "id,caption,permalink,media_product_type,timestamp", "id" };
    var last: call.Fail = .{ .info = .{ .class = .failed, .msg = "list failed" } };
    for (fields) |fl| {
        const path = std.fmt.allocPrint(a, "{s}/media?fields={s}&since={d}&limit=50", .{ ig, fl, @max(0, since_s) }) catch return oomf;
        const url = call.graphUrl(cx, a, path) catch return oomf;
        switch (call.call(cx, a, .{ .url = url, .token = tok })) {
            .fail => |f| {
                last = f;
                if (f.info.class != .failed) return .{ .fail = f }; // only a rejected field name falls back
            },
            .ok => |ok| return .{ .ok = read(a, ok.body) orelse return .{ .fail = .{ .info = .{ .class = .retry, .msg = "media list unreadable" }, .body = ok.body } } },
        }
    }
    return .{ .fail = last };
}

pub const Info = struct { permalink: []const u8 = "", ai: ?bool = null };

// best effort after a post: permalink + is_ai_generated read-back. Any failure = empty info, never an error.
pub fn info(cx: *const Ctx, a: std.mem.Allocator, tok: []const u8, media_id: []const u8) Info {
    if (!call.idOk(media_id)) return .{};
    var out = Info{};
    const p1 = std.fmt.allocPrint(a, "{s}?fields=permalink", .{media_id}) catch return out;
    if (call.graphUrl(cx, a, p1)) |u| switch (call.call(cx, a, .{ .url = u, .token = tok })) {
        .ok => |ok| out.permalink = js.str(js.parse(a, ok.body), "permalink"),
        .fail => {},
    } else |_| {}
    const p2 = std.fmt.allocPrint(a, "{s}?fields=is_ai_generated", .{media_id}) catch return out;
    if (call.graphUrl(cx, a, p2)) |u| switch (call.call(cx, a, .{ .url = u, .token = tok })) {
        .ok => |ok| {
            const v = js.parse(a, ok.body);
            if (js.obj(v, "is_ai_generated")) |x| if (x == .bool) {
                out.ai = x.bool;
            };
        },
        .fail => {},
    } else |_| {}
    return out;
}
