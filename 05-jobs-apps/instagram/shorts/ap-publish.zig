// Step 4: POST {ig-user}/media_publish creation_id=<container>. The point of no return: once the request left, an unclear answer = unsure.
const std = @import("std");
const Ctx = @import("co-ctx.zig").Ctx;
const call = @import("ap-call.zig");
const js = @import("ap-json.zig");

pub const Done = struct { media_id: []const u8 = "", issue: []const u8 = "" };
pub const Body = struct { creation_id: []const u8 };

pub fn publish(cx: *const Ctx, a: std.mem.Allocator, tok: []const u8, ig: []const u8, cont_id: []const u8) call.Out(Done) {
    const oomf: call.Out(Done) = .{ .fail = .{ .info = .{ .class = .failed, .msg = "out of memory" } } };
    if (!call.idOk(ig) or !call.idOk(cont_id)) return .{ .fail = .{ .info = .{ .class = .failed, .msg = "ids must be digits" } } };
    const body = std.json.Stringify.valueAlloc(a, Body{ .creation_id = cont_id }, .{}) catch return oomf;
    const path = std.fmt.allocPrint(a, "{s}/media_publish", .{ig}) catch return oomf;
    const url = call.graphUrl(cx, a, path) catch return oomf;
    switch (call.call(cx, a, .{ .method = "POST", .url = url, .token = tok, .json = body })) {
        .fail => |f| return .{ .fail = f },
        .ok => |ok| {
            const v = js.parse(a, ok.body);
            const id = js.str(v, "id");
            // an answer we cannot read after the request left is unclear, not failed
            if (!call.idOk(id)) return .{ .fail = .{ .info = .{ .class = .retry, .msg = "media_publish reply has no media id" }, .body = ok.body, .sent = true } };
            // partial success: the media IS published (CAPTION_NOT_ATTACHED, USER_TAGGING_FAILURE)
            return .{ .ok = .{ .media_id = id, .issue = js.str(v, "config_issue") } };
        },
    }
}
