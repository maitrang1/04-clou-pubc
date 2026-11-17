// Token checks and refresh. userinfo (OpenID) proves the token is alive and gives `sub`. Refresh only works for partner apps: it runs only when a refresh token is stored.
const std = @import("std");
const Ctx = @import("co-ctx.zig").Ctx;
const call = @import("ap-call.zig");
const js = @import("ap-json.zig");

pub const Who = struct { sub: []const u8 = "", name: []const u8 = "" };
pub const Fresh = struct { access_token: []const u8, expires_in_s: i64, refresh_token: []const u8 = "", refresh_expires_s: i64 = 0 };

// read-only: 200 = alive, 401 = dead. /v2/userinfo is not a versioned call (no Linkedin-Version header).
pub fn userinfo(cx: *const Ctx, a: std.mem.Allocator, tok: []const u8) call.Out(Who) {
    const url = call.v2Url(cx, a, "userinfo") catch return .{ .fail = .{ .info = .{ .class = .failed, .msg = "out of memory" } } };
    switch (call.call(cx, a, .{ .url = url, .token = tok, .rest = false, .label = "GET /v2/userinfo" })) {
        .fail => |f| return .{ .fail = f },
        .ok => |ok| {
            const root = js.parse(a, ok.body) orelse return .{ .fail = .{ .info = .{ .class = .retry, .msg = "userinfo reply unreadable" } } };
            return .{ .ok = .{ .sub = js.str(root, "sub"), .name = js.str(root, "name") } };
        },
    }
}

fn pct(a: std.mem.Allocator, s: []const u8) ![]u8 {
    var o: std.ArrayList(u8) = .empty;
    for (s) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') try o.append(a, c) else try o.print(a, "%{X:0>2}", .{c});
    }
    return o.items;
}

pub fn refresh(cx: *const Ctx, a: std.mem.Allocator, refresh_token: []const u8, client_id: []const u8, client_secret: []const u8) call.Out(Fresh) {
    const oomf: call.Out(Fresh) = .{ .fail = .{ .info = .{ .class = .failed, .msg = "out of memory" } } };
    const form = std.fmt.allocPrint(a, "grant_type=refresh_token&refresh_token={s}&client_id={s}&client_secret={s}", .{ pct(a, refresh_token) catch return oomf, pct(a, client_id) catch return oomf, pct(a, client_secret) catch return oomf }) catch return oomf;
    const url = call.oauthUrl(cx, a, "accessToken") catch return oomf;
    switch (call.call(cx, a, .{ .method = "POST", .url = url, .rest = false, .json = form, .content_type = "application/x-www-form-urlencoded", .label = "POST /oauth/v2/accessToken (refresh)" })) {
        .fail => |f| return .{ .fail = f },
        .ok => |ok| {
            const root = js.parse(a, ok.body) orelse return .{ .fail = .{ .info = .{ .class = .retry, .msg = "refresh reply unreadable" } } };
            const at = js.str(root, "access_token");
            if (at.len == 0) return .{ .fail = .{ .info = .{ .class = .failed, .msg = "refresh reply has no access_token" } } };
            return .{ .ok = .{ .access_token = at, .expires_in_s = js.int(root, "expires_in"), .refresh_token = js.str(root, "refresh_token"), .refresh_expires_s = js.int(root, "refresh_token_expires_in") } };
        },
    }
}

test "percent-encoding for the form body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("a%26b%3Dc%20d", try pct(arena.allocator(), "a&b=c d"));
}
