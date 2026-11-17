// Token + Page checks, read-only. debug_token needs an app token in the header; its documented input_token query is the only token that ever rides in a URL (never logged: log redacts).
const std = @import("std");
const Ctx = @import("co-ctx.zig").Ctx;
const call = @import("ap-call.zig");
const js = @import("ap-json.zig");

pub const Info = struct { is_valid: bool = false, expires_at: i64 = 0, data_access_expires_at: i64 = 0, scopes: []const []const u8 = &.{}, err_code: i64 = 0, err_msg: []const u8 = "" };

fn pct(a: std.mem.Allocator, s: []const u8) ![]u8 {
    var o: std.ArrayList(u8) = .empty;
    for (s) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') try o.append(a, c) else try o.print(a, "%{X:0>2}", .{c});
    }
    return o.items;
}

pub fn debugToken(cx: *const Ctx, a: std.mem.Allocator, input: []const u8, app_token: []const u8) call.Out(Info) {
    const oomf: call.Out(Info) = .{ .fail = .{ .info = .{ .class = .failed, .msg = "out of memory" } } };
    const enc = pct(a, input) catch return oomf;
    const path = std.fmt.allocPrint(a, "debug_token?input_token={s}", .{enc}) catch return oomf;
    const url = call.graphUrl(cx, a, path) catch return oomf;
    switch (call.call(cx, a, .{ .url = url, .token = app_token })) {
        .fail => |f| return .{ .fail = f },
        .ok => |ok| {
            const root = js.parse(a, ok.body) orelse return .{ .fail = .{ .info = .{ .class = .retry, .msg = "debug_token reply unreadable" } } };
            const d = js.obj(root, "data");
            var sc: std.ArrayList([]const u8) = .empty;
            if (js.obj(d, "scopes")) |s| if (s == .array) for (s.array.items) |x| if (x == .string) sc.append(a, x.string) catch return oomf;
            const e = js.obj(d, "error");
            return .{ .ok = .{ .is_valid = js.boolean(d, "is_valid"), .expires_at = js.int(d, "expires_at"), .data_access_expires_at = js.int(d, "data_access_expires_at"), .scopes = sc.items, .err_code = js.int(e, "code"), .err_msg = js.str(e, "message") } };
        },
    }
}

// read-only: the Page answers to this token
pub fn pageName(cx: *const Ctx, a: std.mem.Allocator, tok: []const u8, page: []const u8) call.Out([]const u8) {
    const oomf: call.Out([]const u8) = .{ .fail = .{ .info = .{ .class = .failed, .msg = "out of memory" } } };
    if (!call.idOk(page)) return .{ .fail = .{ .info = .{ .class = .failed, .msg = "page id must be digits" } } };
    const path = std.fmt.allocPrint(a, "{s}?fields=id,name", .{page}) catch return oomf;
    const url = call.graphUrl(cx, a, path) catch return oomf;
    switch (call.call(cx, a, .{ .url = url, .token = tok })) {
        .fail => |f| return .{ .fail = f },
        .ok => |ok| return .{ .ok = js.str(js.parse(a, ok.body), "name") },
    }
}
