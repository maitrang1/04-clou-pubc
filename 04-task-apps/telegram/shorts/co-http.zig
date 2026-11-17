// =====================================================================
// Des: One HTTPS call - guards the url (allow-list, public pinned IP) and runs the request with the right timeout; the Bot API token is inside the url path, so the caller must never log the url
// Flo: parse url with the guard > pin ip > co-net call > Resp
// Cre: 2026-11-16                          - | Mod: 2026-11-16
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: Ctx, method, url, headers, body
// Out: Resp (arena-owned) | error (guard or net)
// Run: not run directly - imported by the ap-* clients
// =====================================================================
const std = @import("std");
const Io = std.Io;
const ctx_mod = @import("co-ctx.zig");
const guard = @import("co-guard.zig");
const net = @import("co-net.zig");

pub const Err = guard.GuardErr || net.Err;

pub const Req = struct {
    method: []const u8 = "GET",
    url: []const u8,
    headers: []const std.http.Header = &.{},
    body: net.Body = .none,
    timeout_s: u32 = 0, // 0 = net.timeout_s
    sent: ?*std.atomic.Value(u64) = null,
};

pub fn send(cx: *const ctx_mod.Ctx, a: std.mem.Allocator, r: Req) Err!net.Resp {
    const t = try guard.parseUrl(a, r.url, .{ .allow_hosts = cx.cfg.net.allow_hosts, .mock = cx.mock });
    const ip = try guard.pin(cx.io, cx.resolver, t);
    var hs: std.ArrayList(std.http.Header) = .empty;
    hs.appendSlice(a, r.headers) catch return net.Err.OutOfMemory;
    return net.call(cx.io, a, t, ip, .{
        .ua = cx.cfg.net.user_agent,
        .timeout_s = if (r.timeout_s != 0) r.timeout_s else cx.cfg.net.timeout_s,
        .cap_bytes = @as(usize, cx.cfg.net.body_cap_kb) * 1024,
        .headers = hs.items,
        .method = r.method,
        .body = r.body,
        .sent = r.sent,
    });
}

// a url on a host outside the allow-list is refused before any byte leaves
test "send refuses a host that is not allowed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var env = std.process.Environ.Map.init(arena.allocator());
    var cx = ctx_mod.testCtx(arena.allocator(), &env, ".");
    cx.mock = false;
    try std.testing.expectError(guard.GuardErr.NotAllowed, send(&cx, arena.allocator(), .{ .url = "https://evil.example.com/bot1:T/getMe" }));
    try std.testing.expectError(guard.GuardErr.Scheme, send(&cx, arena.allocator(), .{ .url = "http://api.telegram.org/bot1:T/getMe" }));
}
// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
