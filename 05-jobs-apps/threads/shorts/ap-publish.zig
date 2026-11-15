// Step 3, the point of no return: POST /{user}/threads_publish creation_id=<container>. Once the request left, an unclear answer = unsure. is_made_with_ai is NOT sent here (it belongs to create).
const std = @import("std");
const Ctx = @import("co-ctx.zig").Ctx;
const call = @import("ap-call.zig");
const js = @import("ap-json.zig");

pub fn publish(cx: *const Ctx, a: std.mem.Allocator, tok: []const u8, uid: []const u8, container: []const u8, enable_race: bool) call.Out([]const u8) {
    const oomf: call.Out([]const u8) = .{ .fail = .{ .info = .{ .class = .failed, .msg = "out of memory" } } };
    if (!call.idOk(uid) or !call.idOk(container)) return .{ .fail = .{ .info = .{ .class = .failed, .msg = "ids must be digits" } } };
    const body = std.fmt.allocPrint(a, "creation_id={s}", .{container}) catch return oomf;
    const path = std.fmt.allocPrint(a, "{s}/threads_publish", .{uid}) catch return oomf;
    const url = call.graphUrl(cx, a, path) catch return oomf;
    switch (call.call(cx, a, .{ .method = "POST", .url = url, .token = tok, .form = body, .enable_race = enable_race })) {
        .fail => |f| return .{ .fail = f },
        .ok => |ok| {
            const id = js.str(js.parse(a, ok.body), "id");
            // an answer we cannot read after the request left is unclear, not failed
            if (!call.idOk(id)) return .{ .fail = .{ .info = .{ .class = .retry, .msg = "publish reply has no post id" }, .body = ok.body, .sent = true } };
            return .{ .ok = id };
        },
    }
}
