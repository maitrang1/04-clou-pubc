// =====================================================================
// Des: The login command - the one-time Google consent in a browser (loopback + PKCE): prints the address to open, waits for the browser (or reads a pasted address), trades the code for a refresh token and stores it with mode 600; never prints a token
// Flo: refuse if a token exists (unless --force) > dry run explains > live: listen > print url > wait or read paste > exchange > write token file
// Cre: 2026-11-15                          - | Mod: 2026-11-15
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: login [--live] [--paste] [--force]
// Out: "stored" on success; exit 0 · 2 usage · 3 blocked or not done · 1 failed
// Run: /home/mai_trang/04-clou-base/05-jobs-apps/youtube/shorts/zig-out/bin/shorts login --live
// =====================================================================
const std = @import("std");
const ctx_mod = @import("co-ctx.zig");
const util = @import("co-util.zig");
const args = @import("co-args.zig");
const exit = @import("co-exit.zig");
const log = @import("co-log.zig");
const auth = @import("ap-auth.zig");

fn store(cx: *const ctx_mod.Ctx, a: std.mem.Allocator, token: []const u8) u8 {
    util.mkdirp(cx.io, cx.secrets_dir) catch {
        util.eprint(cx.io, "error: cannot create the secrets folder\nwhy: {s}\nfix: check the path and permissions\n", .{cx.secrets_dir});
        return exit.failed;
    };
    const p = auth.refreshPath(cx, a) catch return exit.failed;
    const body = std.fmt.allocPrint(a, "{s}\n", .{token}) catch return exit.failed;
    util.writeAtomicMode(a, cx.io, p, body, 0o600) catch {
        util.eprint(cx.io, "error: cannot write the token file\nwhy: {s}\nfix: check the path and permissions\n", .{p});
        return exit.failed;
    };
    log.line(cx, "INFO", "login: refresh token stored", .{});
    util.print(cx.io, "stored: sign-in saved to {s} (mode 600)\n", .{p});
    return exit.ok;
}

fn explain(cx: *const ctx_mod.Ctx, e: auth.Err) u8 {
    switch (e) {
        error.NoClientId => util.eprint(cx.io, "error: no client id\nwhy: no env {s} and no file {s} in the secrets folder\nfix: do \"Create your Google client id\" in 10-HOW-TO\n", .{ cx.cfg.google.client_id_env, cx.cfg.google.client_id_file }),
        error.Timeout => util.eprint(cx.io, "error: no answer from the browser in {d}s\nwhy: the consent page was not finished\nfix: run login again, or use --paste\n", .{cx.cfg.google.login_wait_s}),
        error.Denied => util.eprint(cx.io, "error: consent denied\nwhy: you pressed Cancel or Google refused\nfix: run login again and press Allow\n", .{}),
        error.StateMismatch => util.eprint(cx.io, "error: wrong state in the address\nwhy: the address does not belong to this login\nfix: run login again\n", .{}),
        error.NoCode => util.eprint(cx.io, "error: no code in the address\nwhy: the pasted text has no code=\nfix: copy the whole address from the browser bar\n", .{}),
        error.InvalidGrant => util.eprint(cx.io, "error: Google refused the code\nwhy: the code is used up or expired\nfix: run login again\n", .{}),
        else => util.eprint(cx.io, "error: login failed ({s})\nwhy: network or Google problem\nfix: try again\n", .{@errorName(e)}),
    }
    return if (e == error.NoClientId) exit.blocked else exit.failed;
}

// code text (a pasted redirect address) -> stored token; used by --paste and by the tests
pub fn finish(cx: *const ctx_mod.Ctx, a: std.mem.Allocator, p: auth.Prep, pasted: []const u8) u8 {
    const code = auth.codeFrom(a, pasted, p.state) catch |e| return explain(cx, e);
    const rt = auth.exchange(cx, a, code, p) catch |e| return explain(cx, e);
    return store(cx, a, rt);
}

pub fn run(cx: *const ctx_mod.Ctx, av: []const []const u8) u8 {
    var arena = std.heap.ArenaAllocator.init(cx.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const live = args.has(av, "--live");
    const paste = args.has(av, "--paste");
    if (auth.readRefresh(cx, a) != null and !args.has(av, "--force")) {
        util.eprint(cx.io, "blocked: a sign-in already exists\nwhy: Google keeps only a few refresh tokens per client and silently kills the older ones\nfix: run shorts token; only if it says dead, run: shorts login --live --force\n", .{});
        return exit.blocked;
    }
    _ = auth.creds(cx, a) catch |e| return explain(cx, e);
    if (!live) {
        util.print(cx.io, "dry run: would {s}, then store the refresh token in {s} (mode 600).\n  scope: {s}\n  This is the one hand job: you press Allow in the browser. Add --live to start.\n", .{ if (paste) "print a consent address and read the address you paste back" else "listen on 127.0.0.1 and print a consent address for your browser", cx.secrets_dir, cx.cfg.google.scope });
        return exit.ok;
    }
    if (paste) {
        const port: u16 = if (cx.cfg.google.loopback_port != 0) @intCast(cx.cfg.google.loopback_port) else 1;
        const p = auth.prepare(cx, a, port) catch |e| return explain(cx, e);
        util.print(cx.io, "1. Open this address in any browser and press Allow:\n\n{s}\n\n2. The browser then shows an error page (cannot connect). Copy the WHOLE address from its address bar and paste it here, then press Enter:\n", .{p.url});
        var rb: [8192]u8 = undefined;
        var r = std.Io.File.stdin().readerStreaming(cx.io, &rb);
        const line = r.interface.takeDelimiterExclusive('\n') catch {
            util.eprint(cx.io, "error: nothing pasted\nwhy: no input\nfix: run login --paste again\n", .{});
            return exit.failed;
        };
        return finish(cx, a, p, line);
    }
    var l = auth.Listener.open(cx.io, @intCast(cx.cfg.google.loopback_port)) catch |e| return explain(cx, e);
    defer l.close();
    const p = auth.prepare(cx, a, l.port) catch |e| return explain(cx, e);
    util.print(cx.io, "Open this address in a browser on this machine and press Allow:\n\n{s}\n\nWaiting up to {d}s for the browser...\n", .{ p.url, cx.cfg.google.login_wait_s });
    const code = auth.waitCode(cx, a, &l, p.state, cx.cfg.google.login_wait_s) catch |e| return explain(cx, e);
    const rt = auth.exchange(cx, a, code, p) catch |e| return explain(cx, e);
    return store(cx, a, rt);
}
// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
