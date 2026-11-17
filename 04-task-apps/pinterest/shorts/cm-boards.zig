// boards: list the account's boards with id and privacy, so the owner can fill the board ids in the secrets folder. Read-only.
const std = @import("std");
const Ctx = @import("co-ctx.zig").Ctx;
const exit = @import("co-exit.zig");
const out = @import("co-out.zig");
const auth = @import("ap-auth.zig");
const board = @import("ap-board.zig");

pub fn run(cx: *Ctx, av: []const []const u8) u8 {
    _ = av;
    var arena = std.heap.ArenaAllocator.init(cx.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const tok: []const u8 = switch (auth.ensure(cx, a, false)) {
        .ok => |t| t,
        .fail => |f| {
            out.warn(cx, "error: {s}", .{f.msg});
            return exit.USAGE;
        },
    };
    switch (board.boards(cx, a, tok)) {
        .fail => |f| {
            out.warn(cx, "error: cannot list boards: {s} (http {d})", .{ f.info.msg, f.http });
            return if (f.info.class == .blocked) exit.BLOCKED else exit.FAILED;
        },
        .ok => |bs| {
            for (bs) |b| out.say(cx, "{s}  {s}  {s}", .{ b.id, b.privacy, b.name });
            if (bs.len == 0) out.say(cx, "no boards found: create a secret board in Pinterest first", .{});
            out.json(cx, a, .{ .boards = bs });
            return exit.OK;
        },
    }
}
