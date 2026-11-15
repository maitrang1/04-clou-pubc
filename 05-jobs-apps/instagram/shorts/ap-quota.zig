// Meta's own publishing allowance: GET {ig-user}/content_publishing_limit?fields=quota_usage,config&since=<unix>. The app never hard-codes 50 or 100: it reads quota_total.
const std = @import("std");
const Ctx = @import("co-ctx.zig").Ctx;
const call = @import("ap-call.zig");
const js = @import("ap-json.zig");

pub const Quota = struct { usage: u32 = 0, total: u32 = 0 };

pub fn parse(a: std.mem.Allocator, body: []const u8) ?Quota {
    const root = js.parse(a, body) orelse return null;
    const data = js.obj(root, "data") orelse return null;
    if (data != .array or data.array.items.len == 0) return null;
    const it = data.array.items[0];
    const total = js.int(js.obj(it, "config"), "quota_total");
    if (total <= 0) return null;
    return .{ .usage = @intCast(@min(@max(js.int(it, "quota_usage"), 0), 1_000_000)), .total = @intCast(@min(total, 1_000_000)) };
}

pub fn get(cx: *const Ctx, a: std.mem.Allocator, tok: []const u8, ig: []const u8) call.Out(Quota) {
    const oomf: call.Out(Quota) = .{ .fail = .{ .info = .{ .class = .failed, .msg = "out of memory" } } };
    if (!call.idOk(ig)) return .{ .fail = .{ .info = .{ .class = .failed, .msg = "Instagram user id must be digits" } } };
    const since = @divTrunc(cx.nowMs(), 1000) - 23 * 3600; // Meta: since must be no older than 24 h
    const path = std.fmt.allocPrint(a, "{s}/content_publishing_limit?fields=quota_usage,config&since={d}", .{ ig, @max(0, since) }) catch return oomf;
    const url = call.graphUrl(cx, a, path) catch return oomf;
    switch (call.call(cx, a, .{ .url = url, .token = tok })) {
        .fail => |f| return .{ .fail = f },
        .ok => |ok| return .{ .ok = parse(a, ok.body) orelse return .{ .fail = .{ .info = .{ .class = .retry, .msg = "publishing limit reply unreadable" }, .body = ok.body } } },
    }
}

test "quota reply: 50 and 100 both read from the reply" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const q = parse(a, "{\"data\":[{\"quota_usage\":2,\"config\":{\"quota_total\":50,\"quota_duration\":86400}}]}").?;
    try std.testing.expectEqual(@as(u32, 2), q.usage);
    try std.testing.expectEqual(@as(u32, 50), q.total);
    try std.testing.expectEqual(@as(u32, 100), parse(a, "{\"data\":[{\"quota_usage\":0,\"config\":{\"quota_total\":100}}]}").?.total);
    try std.testing.expect(parse(a, "{\"data\":[]}") == null);
    try std.testing.expect(parse(a, "{\"data\":[{\"quota_usage\":1}]}") == null);
}
