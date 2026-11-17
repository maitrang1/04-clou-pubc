// =====================================================================
// Des: Google sign-in - reads the client id/secret and the refresh token from env or the secrets folder, turns the refresh token into a short-lived access token, and runs the one-time browser login (loopback + PKCE)
// Flo: secrets > POST token endpoint (refresh) | login: PKCE + state > listen on 127.0.0.1 > browser sends code > exchange for the refresh token
// Cre: 2026-11-15                          - | Mod: 2026-11-15
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: Ctx (google config, secrets folder, env)
// Out: access token (memory only) | refresh token (returned to the caller to store, mode 600) | Err
// Run: not run directly - imported by cm-login, cm-token, cm-doctor, cm-publish
// =====================================================================
const std = @import("std");
const Io = std.Io;
const ctx_mod = @import("co-ctx.zig");
const util = @import("co-util.zig");
const http = @import("co-http.zig");

pub const Err = error{ NoClientId, NoRefreshToken, InvalidGrant, AuthFail, Net, BadReply, OutOfMemory, StateMismatch, NoCode, Timeout, Listen, Denied };

pub const Creds = struct { id: []const u8, secret: []const u8 };

// env first, then a file in the secrets folder; trimmed; null when neither has it
pub fn secret(cx: *const ctx_mod.Ctx, a: std.mem.Allocator, env_key: []const u8, file_name: []const u8) ?[]const u8 {
    if (env_key.len > 0) if (cx.envGet(env_key)) |v| return util.trimSecret(v);
    if (file_name.len == 0) return null;
    const p = cx.secretPath(a, file_name) catch return null;
    const t = util.readAll(a, cx.io, p, 16 * 1024) catch return null;
    const s = util.trimSecret(t);
    return if (s.len == 0) null else s;
}

pub fn creds(cx: *const ctx_mod.Ctx, a: std.mem.Allocator) Err!Creds {
    const g = cx.cfg.google;
    const id = secret(cx, a, g.client_id_env, g.client_id_file) orelse return Err.NoClientId;
    const sec = secret(cx, a, g.client_secret_env, g.client_secret_file) orelse "";
    return .{ .id = id, .secret = sec };
}

pub fn refreshPath(cx: *const ctx_mod.Ctx, a: std.mem.Allocator) ![]u8 {
    return cx.secretPath(a, cx.cfg.google.refresh_token_file);
}

pub fn readRefresh(cx: *const ctx_mod.Ctx, a: std.mem.Allocator) ?[]const u8 {
    const p = refreshPath(cx, a) catch return null;
    const t = util.readAll(a, cx.io, p, 16 * 1024) catch return null;
    const s = util.trimSecret(t);
    return if (s.len == 0) null else s;
}

const TokenReply = struct { access_token: []const u8 = "", refresh_token: []const u8 = "", expires_in: u32 = 0, @"error": []const u8 = "", error_description: []const u8 = "" };

fn form(a: std.mem.Allocator, pairs: []const [2][]const u8) ![]u8 {
    var o: std.ArrayList(u8) = .empty;
    for (pairs) |kv| {
        if (kv[1].len == 0) continue;
        if (o.items.len > 0) try o.append(a, '&');
        try o.print(a, "{s}={s}", .{ kv[0], try util.pct(a, kv[1]) });
    }
    return o.toOwnedSlice(a);
}

fn postToken(cx: *const ctx_mod.Ctx, a: std.mem.Allocator, body: []const u8) Err!TokenReply {
    const hs = [_]std.http.Header{.{ .name = "Content-Type", .value = "application/x-www-form-urlencoded" }};
    const r = http.send(cx, a, .{ .method = "POST", .url = cx.cfg.google.token_url, .headers = &hs, .body = .{ .bytes = body } }) catch |e| return if (e == error.OutOfMemory) Err.OutOfMemory else Err.Net;
    const t = std.json.parseFromSliceLeaky(TokenReply, a, r.body, .{ .ignore_unknown_fields = true }) catch return Err.BadReply;
    if (r.status == 200 and t.access_token.len > 0) return t;
    if (std.mem.eql(u8, t.@"error", "invalid_grant")) return Err.InvalidGrant;
    if (std.mem.eql(u8, t.@"error", "access_denied")) return Err.Denied;
    return Err.AuthFail;
}

// refresh token -> access token. invalid_grant = the refresh token is dead: login again.
pub fn accessToken(cx: *const ctx_mod.Ctx, a: std.mem.Allocator) Err![]const u8 {
    const c = try creds(cx, a);
    const rt = readRefresh(cx, a) orelse return Err.NoRefreshToken;
    const body = form(a, &.{ .{ "client_id", c.id }, .{ "client_secret", c.secret }, .{ "refresh_token", rt }, .{ "grant_type", "refresh_token" } }) catch return Err.OutOfMemory;
    const t = try postToken(cx, a, body);
    return t.access_token;
}

// ---- login: PKCE + loopback ----
pub const Prep = struct { verifier: []const u8, challenge: []const u8, state: []const u8, redirect: []const u8, url: []const u8 };

pub fn pkceChallenge(a: std.mem.Allocator, verifier: []const u8) ![]u8 {
    var h: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(verifier, &h, .{});
    return util.b64url(a, &h);
}

fn randB64(cx: *const ctx_mod.Ctx, a: std.mem.Allocator, n: usize) ![]u8 {
    const b = try a.alloc(u8, n);
    cx.io.random(b);
    return util.b64url(a, b);
}

// builds the consent url for a given loopback port
pub fn prepare(cx: *const ctx_mod.Ctx, a: std.mem.Allocator, port: u16) Err!Prep {
    const c = try creds(cx, a);
    const g = cx.cfg.google;
    const verifier = randB64(cx, a, 32) catch return Err.OutOfMemory;
    const challenge = pkceChallenge(a, verifier) catch return Err.OutOfMemory;
    const state = randB64(cx, a, 16) catch return Err.OutOfMemory;
    const redirect = std.fmt.allocPrint(a, "http://127.0.0.1:{d}", .{port}) catch return Err.OutOfMemory;
    const q = form(a, &.{
        .{ "client_id", c.id },
        .{ "redirect_uri", redirect },
        .{ "response_type", "code" },
        .{ "scope", g.scope },
        .{ "access_type", "offline" },
        .{ "prompt", "consent" },
        .{ "code_challenge", challenge },
        .{ "code_challenge_method", "S256" },
        .{ "state", state },
    }) catch return Err.OutOfMemory;
    const url = std.fmt.allocPrint(a, "{s}?{s}", .{ g.auth_url, q }) catch return Err.OutOfMemory;
    return .{ .verifier = verifier, .challenge = challenge, .state = state, .redirect = redirect, .url = url };
}

// code from a redirect url or a request path: "...?code=X&state=Y". Checks state, honors error=
pub fn codeFrom(a: std.mem.Allocator, text: []const u8, want_state: []const u8) Err![]const u8 {
    const q = std.mem.indexOfScalar(u8, text, '?') orelse return Err.NoCode;
    var code: []const u8 = "";
    var state: []const u8 = "";
    var errv: []const u8 = "";
    var it = std.mem.tokenizeAny(u8, std.mem.trim(u8, text[q + 1 ..], " \r\n\t"), "& ");
    while (it.next()) |kv| {
        const eq = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
        const v = util.unpct(a, kv[eq + 1 ..]) orelse continue;
        const k = kv[0..eq];
        if (std.mem.eql(u8, k, "code")) code = v;
        if (std.mem.eql(u8, k, "state")) state = v;
        if (std.mem.eql(u8, k, "error")) errv = v;
    }
    if (errv.len > 0) return Err.Denied;
    if (!std.mem.eql(u8, state, want_state)) return Err.StateMismatch;
    if (code.len == 0) return Err.NoCode;
    return code;
}

// code -> refresh token (the caller stores it, mode 600)
pub fn exchange(cx: *const ctx_mod.Ctx, a: std.mem.Allocator, code: []const u8, p: Prep) Err![]const u8 {
    const c = try creds(cx, a);
    const body = form(a, &.{ .{ "code", code }, .{ "client_id", c.id }, .{ "client_secret", c.secret }, .{ "redirect_uri", p.redirect }, .{ "grant_type", "authorization_code" }, .{ "code_verifier", p.verifier } }) catch return Err.OutOfMemory;
    const t = try postToken(cx, a, body);
    if (t.refresh_token.len == 0) return Err.AuthFail;
    return t.refresh_token;
}

// ---- the one-shot loopback listener ----
pub const Listener = struct {
    io: Io,
    server: Io.net.Server,
    port: u16,

    pub fn open(io: Io, port: u16) Err!Listener {
        const addr = Io.net.IpAddress.parse("127.0.0.1", port) catch return Err.Listen;
        const s = addr.listen(io, .{ .reuse_address = true }) catch return Err.Listen;
        return .{ .io = io, .server = s, .port = s.socket.address.getPort() };
    }
    pub fn close(self: *Listener) void {
        self.server.deinit(self.io);
    }
};

const Wait = struct {
    io: Io,
    server: *Io.net.Server,
    state: []const u8,
    done: std.atomic.Value(bool) = .init(false),
    stop: std.atomic.Value(bool) = .init(false),
    path: [2048]u8 = undefined,
    path_len: usize = 0,
};

const done_body = "<html><body>Done. You can close this tab.</body></html>";

fn acceptMain(w: *Wait) void {
    var tries: u32 = 0;
    while (tries < 6 and !w.done.load(.acquire)) : (tries += 1) {
        var st = w.server.accept(w.io) catch break;
        defer st.close(w.io);
        if (w.stop.load(.acquire)) break;
        var rb: [4096]u8 = undefined;
        var wb: [256]u8 = undefined;
        var r = st.reader(w.io, &rb);
        var wr = st.writer(w.io, &wb);
        const line = r.interface.takeDelimiterExclusive('\n') catch continue;
        var it = std.mem.tokenizeScalar(u8, std.mem.trimEnd(u8, line, "\r"), ' ');
        _ = it.next();
        const target = it.next() orelse continue;
        wr.interface.print("HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nConnection: close\r\nContent-Length: {d}\r\n\r\n{s}", .{ done_body.len, done_body }) catch {};
        wr.interface.flush() catch {};
        // only a request that carries the code (or an error) AND our own state ends the wait: favicon and stray local requests are ignored
        const has_result = std.mem.indexOf(u8, target, "code=") != null or std.mem.indexOf(u8, target, "error=") != null;
        var want: [96]u8 = undefined;
        const mine = std.fmt.bufPrint(&want, "state={s}", .{w.state}) catch "";
        if (!has_result or std.mem.indexOf(u8, target, mine) == null) continue;
        const n = @min(target.len, w.path.len);
        @memcpy(w.path[0..n], target[0..n]);
        w.path_len = n;
        break;
    }
    w.done.store(true, .release);
}

// waits for the browser; returns the code, or Timeout / Denied / NoCode
pub fn waitCode(cx: *const ctx_mod.Ctx, a: std.mem.Allocator, l: *Listener, state: []const u8, wait_s: u32) Err![]const u8 {
    // heap: on a timeout the thread may still sit in a read on an idle connection; it is detached and the struct is left to it
    const w = std.heap.page_allocator.create(Wait) catch return Err.Listen;
    w.* = Wait{ .io = cx.io, .server = &l.server, .state = state };
    const th = std.Thread.spawn(.{}, acceptMain, .{w}) catch {
        std.heap.page_allocator.destroy(w);
        return Err.Listen;
    };
    const deadline = util.monoMs(cx.io) + @as(i64, wait_s) * 1000;
    while (!w.done.load(.acquire) and util.monoMs(cx.io) < deadline) util.sleepMs(cx.io, 20);
    if (!w.done.load(.acquire)) {
        w.stop.store(true, .release);
        // wake a blocked accept so an idle thread can end; a thread stuck reading is simply left behind (the process ends right after login)
        if (Io.net.IpAddress.parse("127.0.0.1", l.port)) |ad| {
            if (ad.connect(cx.io, .{ .mode = .stream })) |s| s.close(cx.io) else |_| {}
        } else |_| {}
        th.detach();
        return Err.Timeout;
    }
    th.join();
    defer std.heap.page_allocator.destroy(w);
    if (w.path_len == 0) return Err.Timeout;
    return codeFrom(a, w.path[0..w.path_len], state);
}

test "PKCE challenge matches the RFC 7636 example" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const c = try pkceChallenge(ar.allocator(), "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk");
    try std.testing.expectEqualStrings("E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", c);
}

test "codeFrom: good, wrong state, denied, no code, pasted full url" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    try std.testing.expectEqualStrings("4/abc", try codeFrom(a, "/?code=4%2Fabc&state=S1&scope=x", "S1"));
    try std.testing.expectEqualStrings("c2", try codeFrom(a, "http://127.0.0.1:1/?state=S1&code=c2\n", "S1"));
    try std.testing.expectError(Err.StateMismatch, codeFrom(a, "/?code=c&state=EVIL", "S1"));
    try std.testing.expectError(Err.Denied, codeFrom(a, "/?error=access_denied&state=S1", "S1"));
    try std.testing.expectError(Err.NoCode, codeFrom(a, "/?state=S1", "S1"));
    try std.testing.expectError(Err.NoCode, codeFrom(a, "nothing", "S1"));
}

test "secrets: env wins over file, file is trimmed, missing is null" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    var env = std.process.Environ.Map.init(a);
    const cx = ctx_mod.testCtx(a, &env, dir);
    try std.testing.expect(secret(&cx, a, "YOUT_CLIENT_ID", "id.txt") == null);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/id.txt", .{dir}), .data = "from-file\n" });
    try std.testing.expectEqualStrings("from-file", secret(&cx, a, "YOUT_CLIENT_ID", "id.txt").?);
    try env.put("YOUT_CLIENT_ID", "from-env");
    try std.testing.expectEqualStrings("from-env", secret(&cx, a, "YOUT_CLIENT_ID", "id.txt").?);
}

test "loopback listener hands over the browser's code, ignores a favicon request, times out when nobody comes" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var env = std.process.Environ.Map.init(a);
    const cx = ctx_mod.testCtx(a, &env, ".");
    var l = try Listener.open(cx.io, 0);
    defer l.close();
    const Browser = struct {
        fn run(io: Io, port: u16) void {
            util.sleepMs(io, 100);
            for ([_][]const u8{ "GET /favicon.ico HTTP/1.1\r\nHost: x\r\n\r\n", "GET /?code=CODE-1&state=ST HTTP/1.1\r\nHost: x\r\n\r\n" }) |req| {
                const ad = Io.net.IpAddress.parse("127.0.0.1", port) catch return;
                var s = ad.connect(io, .{ .mode = .stream }) catch return;
                defer s.close(io);
                var wb: [256]u8 = undefined;
                var wr = s.writer(io, &wb);
                wr.interface.writeAll(req) catch return;
                wr.interface.flush() catch return;
                var rb: [256]u8 = undefined;
                var r = s.reader(io, &rb);
                _ = r.interface.takeDelimiterExclusive('\n') catch {};
            }
        }
    };
    const th = try std.Thread.spawn(.{}, Browser.run, .{ cx.io, l.port });
    const code = try waitCode(&cx, a, &l, "ST", 10);
    th.join();
    try std.testing.expectEqualStrings("CODE-1", code);
    var l2 = try Listener.open(cx.io, 0);
    defer l2.close();
    try std.testing.expectError(Err.Timeout, waitCode(&cx, a, &l2, "ST", 1));
}
test "an idle connection and a request with the wrong state do not break or end the wait" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var env = std.process.Environ.Map.init(a);
    const cx = ctx_mod.testCtx(a, &env, ".");
    var l = try Listener.open(cx.io, 0);
    defer l.close();
    const Stray = struct {
        fn run(io: Io, port: u16) void {
            // 1. a connection that says nothing (a browser preconnect)
            const ad = Io.net.IpAddress.parse("127.0.0.1", port) catch return;
            const idle = ad.connect(io, .{ .mode = .stream }) catch return;
            util.sleepMs(io, 1500);
            idle.close(io);
        }
    };
    const th = try std.Thread.spawn(.{}, Stray.run, .{ cx.io, l.port });
    // nobody completes the login: Timeout, and it returns (no hang) even with the idle connection open
    try std.testing.expectError(Err.Timeout, waitCode(&cx, a, &l, "ST", 1));
    th.join();
    // a stray local request with the wrong state is ignored; the right one still wins
    var l2 = try Listener.open(cx.io, 0);
    defer l2.close();
    const Two = struct {
        fn run(io: Io, port: u16) void {
            util.sleepMs(io, 100);
            for ([_][]const u8{ "GET /?code=EVIL&state=OTHER HTTP/1.1\r\nHost: x\r\n\r\n", "GET /?code=CODE-2&state=ST HTTP/1.1\r\nHost: x\r\n\r\n" }) |req| {
                const ad = Io.net.IpAddress.parse("127.0.0.1", port) catch return;
                var s = ad.connect(io, .{ .mode = .stream }) catch return;
                defer s.close(io);
                var wb: [256]u8 = undefined;
                var wr = s.writer(io, &wb);
                wr.interface.writeAll(req) catch return;
                wr.interface.flush() catch return;
                var rb: [256]u8 = undefined;
                var r = s.reader(io, &rb);
                _ = r.interface.takeDelimiterExclusive('\n') catch {};
            }
        }
    };
    const th2 = try std.Thread.spawn(.{}, Two.run, .{ cx.io, l2.port });
    const code = try waitCode(&cx, a, &l2, "ST", 10);
    th2.join();
    try std.testing.expectEqualStrings("CODE-2", code);
}

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
