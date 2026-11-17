// Token + profile checks and the 60-day refresh. Read-only except `refresh` (the caller writes the new token). The documented token calls carry the token in the query; the log never shows it.
const std = @import("std");
const Ctx = @import("co-ctx.zig").Ctx;
const call = @import("ap-call.zig");
const js = @import("ap-json.zig");
const util = @import("co-util.zig");

pub const Me = struct { id: []const u8 = "", username: []const u8 = "" };
pub const Info = struct { is_valid: bool = false, expires_at: i64 = 0, issued_at: i64 = 0, data_access_expires_at: i64 = 0, scopes: []const []const u8 = &.{}, user_id: []const u8 = "", err_code: i64 = 0, err_msg: []const u8 = "" };
pub const Fresh = struct { token: []const u8, expires_in_s: i64 = 0 };

fn oomf(comptime T: type) call.Out(T) {
    return .{ .fail = .{ .info = .{ .class = .failed, .msg = "out of memory" } } };
}

// GET /me?fields=id,username: who this token is
pub fn me(cx: *const Ctx, a: std.mem.Allocator, tok: []const u8) call.Out(Me) {
    const url = call.graphUrl(cx, a, "me?fields=id,username") catch return oomf(Me);
    switch (call.call(cx, a, .{ .url = url, .token = tok })) {
        .fail => |f| return .{ .fail = f },
        .ok => |ok| {
            const v = js.parse(a, ok.body);
            const id = js.str(v, "id");
            if (!call.idOk(id)) return .{ .fail = .{ .info = .{ .class = .failed, .msg = "/me reply has no numeric id" }, .body = ok.body } };
            return .{ .ok = .{ .id = id, .username = js.str(v, "username") } };
        },
    }
}

// debug_token: input_token = the token to inspect, access_token = an app token (TH|id|secret) or a tester's user token
pub fn debugToken(cx: *const Ctx, a: std.mem.Allocator, input: []const u8, caller: []const u8) call.Out(Info) {
    const enc = util.pct(a, input) catch return oomf(Info);
    const path = std.fmt.allocPrint(a, "debug_token?input_token={s}", .{enc}) catch return oomf(Info);
    const url = call.graphUrl(cx, a, path) catch return oomf(Info);
    switch (call.call(cx, a, .{ .url = url, .token = caller })) {
        .fail => |f| return .{ .fail = f },
        .ok => |ok| {
            const root = js.parse(a, ok.body) orelse return .{ .fail = .{ .info = .{ .class = .retry, .msg = "debug_token reply unreadable" } } };
            const d = js.obj(root, "data");
            var sc: std.ArrayList([]const u8) = .empty;
            if (js.obj(d, "scopes")) |s| if (s == .array) for (s.array.items) |x| if (x == .string) sc.append(a, x.string) catch return oomf(Info);
            const e = js.obj(d, "error");
            return .{ .ok = .{ .is_valid = js.boolean(d, "is_valid"), .expires_at = js.int(d, "expires_at"), .issued_at = js.int(d, "issued_at"), .data_access_expires_at = js.int(d, "data_access_expires_at"), .scopes = sc.items, .user_id = js.str(d, "user_id"), .err_code = js.int(e, "code"), .err_msg = js.str(e, "message") } };
        },
    }
}

// GET refresh_access_token?grant_type=th_refresh_token: allowed when the token is >= 24 h old and not expired. New token valid 60 days.
pub fn refresh(cx: *const Ctx, a: std.mem.Allocator, tok: []const u8) call.Out(Fresh) {
    const url = call.rootUrl(cx, a, "refresh_access_token?grant_type=th_refresh_token") catch return oomf(Fresh);
    switch (call.call(cx, a, .{ .url = url, .token = tok })) {
        .fail => |f| return .{ .fail = f },
        .ok => |ok| {
            const v = js.parse(a, ok.body);
            const t = js.str(v, "access_token");
            if (t.len < 8) return .{ .fail = .{ .info = .{ .class = .failed, .msg = "refresh reply has no access_token" }, .body = "" } };
            return .{ .ok = .{ .token = t, .expires_in_s = js.int(v, "expires_in") } };
        },
    }
}
