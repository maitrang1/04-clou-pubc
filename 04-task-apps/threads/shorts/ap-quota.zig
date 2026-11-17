// GET /{user}/threads_publishing_limit?fields=quota_usage,config -> posts used in the rolling 24 h and the total Threads allows (250). Needs threads_basic + threads_content_publish.
const std = @import("std");
const Ctx = @import("co-ctx.zig").Ctx;
const call = @import("ap-call.zig");
const js = @import("ap-json.zig");

pub const Quota = struct { usage: i64 = 0, total: i64 = 250 };

pub fn get(cx: *const Ctx, a: std.mem.Allocator, tok: []const u8, uid: []const u8) call.Out(Quota) {
    const oomf: call.Out(Quota) = .{ .fail = .{ .info = .{ .class = .failed, .msg = "out of memory" } } };
    if (!call.idOk(uid)) return .{ .fail = .{ .info = .{ .class = .failed, .msg = "user id must be digits" } } };
    const path = std.fmt.allocPrint(a, "{s}/threads_publishing_limit?fields=quota_usage,config", .{uid}) catch return oomf;
    const url = call.graphUrl(cx, a, path) catch return oomf;
    switch (call.call(cx, a, .{ .url = url, .token = tok })) {
        .fail => |f| return .{ .fail = f },
        .ok => |ok| {
            const root = js.parse(a, ok.body) orelse return .{ .fail = .{ .info = .{ .class = .retry, .msg = "quota reply unreadable" }, .body = ok.body } };
            const data = js.obj(root, "data") orelse return .{ .fail = .{ .info = .{ .class = .failed, .msg = "quota reply has no data" }, .body = ok.body } };
            if (data != .array or data.array.items.len == 0) return .{ .fail = .{ .info = .{ .class = .failed, .msg = "quota reply has no data" }, .body = ok.body } };
            const d0 = data.array.items[0];
            if (js.obj(d0, "quota_usage") == null) return .{ .fail = .{ .info = .{ .class = .retry, .msg = "quota reply has no quota_usage" }, .body = ok.body } }; // a renamed field must block, not read as 0
            var q = Quota{ .usage = js.int(d0, "quota_usage") };
            const t = js.int(js.obj(d0, "config"), "quota_total");
            if (t > 0) q.total = t;
            return .{ .ok = q };
        },
    }
}
