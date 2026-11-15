// Access token (client_credentials: key + secret -> token, no refresh token, no login) kept in memory for the run; plus the read-only /me check. The secret only rides in the token request body.
const std = @import("std");
const Ctx = @import("co-ctx.zig").Ctx;
const call = @import("ap-call.zig");
const js = @import("ap-json.zig");

// in-memory cache, never written to disk. page_allocator copy: lives for the process.
var cache_tok: ?[]const u8 = null;
var cache_exp_ms: i64 = 0;
pub var issued: u32 = 0; // tokens asked for in this process (tests + status)

pub fn reset() void {
    cache_tok = null;
    cache_exp_ms = 0;
    issued = 0;
}
// the server refused our token: forget it so the next token() asks for a new one
pub fn invalidate() void {
    cache_tok = null;
    cache_exp_ms = 0;
}

pub fn secondsLeft(cx: *const Ctx) i64 {
    if (cache_tok == null) return 0;
    return @max(0, @divTrunc(cache_exp_ms - cx.nowMs(), 1000));
}

fn blocked(msg: []const u8) call.Out([]const u8) {
    return .{ .fail = .{ .info = .{ .class = .blocked, .msg = msg } } };
}

pub fn token(cx: *const Ctx, a: std.mem.Allocator) call.Out([]const u8) {
    if (cache_tok) |t| if (cx.nowMs() < cache_exp_ms) return .{ .ok = t };
    const id = cx.clientId() orelse return blocked("no API key id: set the env var or the file named in config dmot.client_id_*");
    const sec = cx.clientSecret() orelse return blocked("no API secret: set the env var or the file named in config dmot.client_secret_*");
    const oomf: call.Out([]const u8) = .{ .fail = .{ .info = .{ .class = .failed, .msg = "out of memory" } } };
    const body = std.fmt.allocPrint(a, "grant_type=client_credentials&client_id={s}&client_secret={s}&scope={s}", .{
        call.pct(a, id) catch return oomf,
        call.pct(a, sec) catch return oomf,
        call.pct(a, cx.cfg.dmot.scope) catch return oomf,
    }) catch return oomf;
    issued += 1;
    switch (call.call(cx, a, .{ .method = "POST", .url = cx.cfg.dmot.token_url, .form = body })) {
        .fail => |f| {
            var ff = f;
            // a refused key must not look like a transient problem
            if (f.http == 400 or f.http == 401) ff.info.class = .blocked;
            return .{ .fail = ff };
        },
        .ok => |ok| {
            const v = js.parse(a, ok.body);
            const tok = js.str(v, "access_token");
            if (tok.len == 0) return .{ .fail = .{ .info = .{ .class = .retry, .msg = "token reply has no access_token" }, .body = ok.body } };
            const ttl = @max(js.int(v, "expires_in"), 60);
            const keep = std.heap.page_allocator.dupe(u8, tok) catch return oomf;
            cache_tok = keep;
            cache_exp_ms = cx.nowMs() + (ttl - 60) * 1000; // renew a minute early
            return .{ .ok = keep };
        },
    }
}

pub const Me = struct { profiles: []const []const u8 = &.{} };

// read-only: the profiles this token may use (needs scope account.read)
pub fn me(cx: *const Ctx, a: std.mem.Allocator, tok: []const u8) call.Out(Me) {
    const oomf: call.Out(Me) = .{ .fail = .{ .info = .{ .class = .failed, .msg = "out of memory" } } };
    const url = call.apiUrl(cx, a, "me?fields=user_id,username,profiles") catch return oomf;
    switch (call.call(cx, a, .{ .url = url, .token = tok })) {
        .fail => |f| return .{ .fail = f },
        .ok => |ok| {
            const root = js.parse(a, ok.body) orelse return .{ .fail = .{ .info = .{ .class = .retry, .msg = "me reply unreadable" }, .body = ok.body } };
            var out: std.ArrayList([]const u8) = .empty;
            if (js.obj(root, "profiles")) |ps| if (ps == .array) for (ps.array.items) |p| {
                const id = js.str(p, "profile_id");
                if (id.len > 0) out.append(a, id) catch return oomf;
            };
            return .{ .ok = .{ .profiles = out.items } };
        },
    }
}
