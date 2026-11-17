// Read-only helpers: the account behind the token (GET /user_account) and the boards (GET /boards). For doctor and the boards command.
const std = @import("std");
const Ctx = @import("co-ctx.zig").Ctx;
const call = @import("ap-call.zig");
const js = @import("ap-json.zig");

pub const Board = struct { id: []const u8, name: []const u8, privacy: []const u8 };

pub fn userName(cx: *const Ctx, a: std.mem.Allocator, tok: []const u8) call.Out([]const u8) {
    const oomf: call.Out([]const u8) = .{ .fail = .{ .info = .{ .class = .failed, .msg = "out of memory" } } };
    const url = call.apiUrl(cx, a, "user_account") catch return oomf;
    switch (call.call(cx, a, .{ .url = url, .auth = .{ .bearer = tok } })) {
        .fail => |f| return .{ .fail = f },
        .ok => |ok| return .{ .ok = js.str(js.parse(a, ok.body), "username") },
    }
}

pub fn boards(cx: *const Ctx, a: std.mem.Allocator, tok: []const u8) call.Out([]const Board) {
    const oomf: call.Out([]const Board) = .{ .fail = .{ .info = .{ .class = .failed, .msg = "out of memory" } } };
    const url = call.apiUrl(cx, a, "boards?privacy=PUBLIC_AND_SECRET&page_size=250") catch return oomf;
    switch (call.call(cx, a, .{ .url = url, .auth = .{ .bearer = tok } })) {
        .fail => |f| return .{ .fail = f },
        .ok => |ok| {
            const root = js.parse(a, ok.body) orelse return .{ .fail = .{ .info = .{ .class = .retry, .msg = "boards reply unreadable" }, .body = ok.body } };
            var out: std.ArrayList(Board) = .empty;
            if (js.obj(root, "items")) |it| if (it == .array) for (it.array.items) |x| out.append(a, .{ .id = js.str(x, "id"), .name = js.str(x, "name"), .privacy = js.str(x, "privacy") }) catch return oomf;
            return .{ .ok = out.items };
        },
    }
}
