// Token check, read-only. These tokens have no documented debug endpoint, so "valid" = the account answers a read. Expiry stays unknown (never guessed).
const std = @import("std");
const Ctx = @import("co-ctx.zig").Ctx;
const call = @import("ap-call.zig");
const js = @import("ap-json.zig");

pub const Who = struct { id: []const u8 = "", username: []const u8 = "" };

pub fn who(cx: *const Ctx, a: std.mem.Allocator, tok: []const u8, ig: []const u8) call.Out(Who) {
    const oomf: call.Out(Who) = .{ .fail = .{ .info = .{ .class = .failed, .msg = "out of memory" } } };
    if (!call.idOk(ig)) return .{ .fail = .{ .info = .{ .class = .failed, .msg = "Instagram user id must be digits" } } };
    const path = std.fmt.allocPrint(a, "{s}?fields=id,username", .{ig}) catch return oomf;
    const url = call.graphUrl(cx, a, path) catch return oomf;
    switch (call.call(cx, a, .{ .url = url, .token = tok })) {
        .fail => |f| return .{ .fail = f },
        .ok => |ok| {
            const v = js.parse(a, ok.body);
            return .{ .ok = .{ .id = js.str(v, "id"), .username = js.str(v, "username") } };
        },
    }
}
