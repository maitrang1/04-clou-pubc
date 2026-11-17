// =====================================================================
// Des: The token command - checks that the stored refresh token still gets an access token (yes or no) and remembers the time for the status warning; never prints a token
// Flo: read secrets > POST refresh > ok / dead / network > write token_ok time
// Cre: 2026-11-15                          - | Mod: 2026-11-15
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: token
// Out: one line; exit 0 works · 3 dead or missing · 1 network
// Run: /home/mai_trang/04-clou-base/04-task-apps/vimeo/shorts/zig-out/bin/shorts token
// =====================================================================
const std = @import("std");
const ctx_mod = @import("co-ctx.zig");
const util = @import("co-util.zig");
const exit = @import("co-exit.zig");
const send = @import("rw-send.zig");
const auth = @import("ap-auth.zig");

pub fn run(cx: *const ctx_mod.Ctx, _: []const []const u8) u8 {
    var arena = std.heap.ArenaAllocator.init(cx.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    _ = auth.accessToken(cx, a) catch |e| {
        switch (e) {
            error.NoClientId => util.eprint(cx.io, "token: NO\nwhy: no client id (env {s} or file {s})\nfix: do \"Create your Google client id\" in 10-HOW-TO\n", .{ cx.cfg.google.client_id_env, cx.cfg.google.client_id_file }),
            error.NoRefreshToken => util.eprint(cx.io, "token: NO\nwhy: not logged in\nfix: shorts login --live\n", .{}),
            error.InvalidGrant => util.eprint(cx.io, "token: DEAD\nwhy: Google says invalid_grant (revoked, or Testing-mode 7-day limit)\nfix: set the consent screen to In production, then: shorts login --live --force\n", .{}),
            else => {
                util.eprint(cx.io, "token: UNKNOWN\nwhy: {s}\nfix: try again\n", .{@errorName(e)});
                return exit.failed;
            },
        }
        return exit.blocked;
    };
    if (send.Ledger.open(cx, a)) |l| {
        defer l.close();
        l.kvSetInt("token_ok", cx.nowMs()) catch {};
    } else |_| {}
    util.print(cx.io, "token: ok (a fresh access token was issued; nothing printed)\n", .{});
    return exit.ok;
}
// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
