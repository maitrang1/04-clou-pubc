// login: the one-time OAuth sign-in (the owner's only hand job). Prints the address to open, then reads the address Pinterest sends the browser to.
// Dry-run explains; --live exchanges the code and stores the token pair (mode 0600). Never prints a token.
const std = @import("std");
const Ctx = @import("co-ctx.zig").Ctx;
const args = @import("co-args.zig");
const exit = @import("co-exit.zig");
const out = @import("co-out.zig");
const log = @import("co-log.zig");
const kill = @import("co-kill.zig");
const auth = @import("ap-auth.zig");

fn newState(cx: *const Ctx, a: std.mem.Allocator) ![]u8 {
    var r: [12]u8 = undefined;
    cx.io.random(&r);
    return std.fmt.allocPrint(a, "{s}", .{std.fmt.bytesToHex(r, .lower)});
}

pub fn run(cx: *Ctx, av: []const []const u8) u8 {
    var arena = std.heap.ArenaAllocator.init(cx.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    if (cx.clientId() == null or cx.clientSecret() == null) {
        out.warn(cx, "error: no app id/secret\nwhy: no env {s}/{s} and no files {s}/{s} in the secrets folder\nfix: do step 'Create your Pinterest app' in 10-HOW-TO", .{ cx.cfg.api.app_id_env, cx.cfg.api.app_secret_env, cx.cfg.api.app_id_file, cx.cfg.api.app_secret_file });
        return exit.USAGE;
    }
    if (auth.load(cx, a) != null and !args.has(av, "--force")) {
        out.warn(cx, "blocked: a sign-in already exists\nwhy: it refreshes itself on every run\nfix: only if token says it is dead, run: login --live --force", .{});
        return exit.BLOCKED;
    }
    const state = newState(cx, a) catch return exit.FAILED;
    const url = auth.authorizeUrl(cx, a, state) catch return exit.FAILED;
    if (args.value(av, "--paste")) |pasted| {
        // second call: the address (or code) the browser ended on
        if (!cx.live) {
            out.say(cx, "dry-run: would trade this code for tokens and store them. Add --live.", .{});
            return exit.OK;
        }
        const want = args.value(av, "--state") orelse "";
        const code = auth.codeFrom(a, pasted, want) catch |e| {
            out.warn(cx, "error: {s}\nwhy: the pasted text is not the address Pinterest sent your browser to (or the state differs)\nfix: run login again and paste the WHOLE address from the browser bar", .{@errorName(e)});
            return exit.FAILED;
        };
        if (kill.killOn(cx)) {
            out.warn(cx, "blocked: kill file is on", .{});
            return exit.BLOCKED;
        }
        switch (auth.exchange(cx, a, code)) {
            .ok => {
                log.log(cx, "info", "login: tokens stored", .{});
                out.say(cx, "stored: sign-in saved (mode 600). Run: token", .{});
                return exit.OK;
            },
            .fail => |f| {
                out.warn(cx, "error: Pinterest refused the code: {s} (http {d})\nwhy: the code is used up, expired, or the redirect address differs\nfix: run login again", .{ f.info.msg, f.http });
                return exit.FAILED;
            },
        }
    }
    out.say(cx, "1. Open this address in a browser, log in to Pinterest, press Give access:\n\n{s}\n\n2. The browser then lands on {s}?code=... (the page may fail to load: that is fine). Copy the WHOLE address from the browser bar.\n3. Run: login --state {s} --paste '<that address>' --live", .{ url, cx.cfg.api.redirect_uri, state });
    out.json(cx, a, .{ .open = url, .state = state });
    return exit.OK;
}
