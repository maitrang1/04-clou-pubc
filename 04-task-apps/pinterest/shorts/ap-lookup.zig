// Pin lookup (resolve only, read-only): GET /pins/{id}, or page a board's Pins (no date filter exists) to find a send whose answer was lost.
const std = @import("std");
const Ctx = @import("co-ctx.zig").Ctx;
const call = @import("ap-call.zig");
const js = @import("ap-json.zig");

pub const Pin = struct { id: []const u8 = "", board_id: []const u8 = "", title: []const u8 = "", description: []const u8 = "", created_at: []const u8 = "" };
pub const Page = struct { items: []const Pin, bookmark: []const u8 = "" };

fn pinOf(v: std.json.Value) Pin {
    return .{ .id = js.str(v, "id"), .board_id = js.str(v, "board_id"), .title = js.str(v, "title"), .description = js.str(v, "description"), .created_at = js.str(v, "created_at") };
}

pub fn getPin(cx: *const Ctx, a: std.mem.Allocator, tok: []const u8, pin_id: []const u8) call.Out(Pin) {
    const oomf: call.Out(Pin) = .{ .fail = .{ .info = .{ .class = .failed, .msg = "out of memory" } } };
    if (!call.idOk(pin_id)) return .{ .fail = .{ .info = .{ .class = .failed, .msg = "pin id must be digits" } } };
    const url = call.apiUrl(cx, a, std.fmt.allocPrint(a, "pins/{s}", .{pin_id}) catch return oomf) catch return oomf;
    switch (call.call(cx, a, .{ .url = url, .auth = .{ .bearer = tok } })) {
        .fail => |f| return .{ .fail = f },
        .ok => |ok| {
            const v = js.parse(a, ok.body) orelse return .{ .fail = .{ .info = .{ .class = .retry, .msg = "pin reply unreadable" }, .body = ok.body } };
            return .{ .ok = pinOf(v) };
        },
    }
}

pub fn boardPins(cx: *const Ctx, a: std.mem.Allocator, tok: []const u8, board_id: []const u8, bookmark: []const u8) call.Out(Page) {
    const oomf: call.Out(Page) = .{ .fail = .{ .info = .{ .class = .failed, .msg = "out of memory" } } };
    if (!call.idOk(board_id)) return .{ .fail = .{ .info = .{ .class = .failed, .msg = "board id must be digits" } } };
    const bm = if (bookmark.len > 0) std.fmt.allocPrint(a, "&bookmark={s}", .{@import("co-util.zig").pct(a, bookmark) catch return oomf}) catch return oomf else "";
    const path = std.fmt.allocPrint(a, "boards/{s}/pins?page_size=100{s}", .{ board_id, bm }) catch return oomf;
    const url = call.apiUrl(cx, a, path) catch return oomf;
    switch (call.call(cx, a, .{ .url = url, .auth = .{ .bearer = tok } })) {
        .fail => |f| return .{ .fail = f },
        .ok => |ok| {
            const root = js.parse(a, ok.body) orelse return .{ .fail = .{ .info = .{ .class = .retry, .msg = "pin list reply unreadable" }, .body = ok.body } };
            var out: std.ArrayList(Pin) = .empty;
            if (js.obj(root, "items")) |it| if (it == .array) for (it.array.items) |x| out.append(a, pinOf(x)) catch return oomf;
            return .{ .ok = .{ .items = out.items, .bookmark = js.str(root, "bookmark") } };
        },
    }
}
