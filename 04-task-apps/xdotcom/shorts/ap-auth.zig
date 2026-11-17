// =====================================================================
// Des: X sign-in - the client id/secret from env or the secrets folder, the one-time browser login (loopback or paste, PKCE, exact callback), the token calls with the confidential Basic header, and the single-use refresh that stores the new pair before anything uses it
// Flo: secrets > POST token endpoint (code exchange | refresh) > Login saved by pv-login | login: PKCE + state > listen on 127.0.0.1 > browser sends code (30 s life) > exchange at once
// Cre: 2026-11-16                          - | Mod: 2026-11-16
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: Ctx (auth + account config, secrets folder, env)
// Out: Login (memory + the private login file) | Err; nothing secret is printed or logged
// Run: not run directly - imported by ap-call, cm-auth, cm-token, cm-doctor, cm-publish
// =====================================================================
const std = @import("std");
const Io = std.Io;
const ctx_mod = @import("co-ctx.zig");
const util = @import("co-util.zig");
const http = @import("co-http.zig");
const guard = @import("co-guard.zig");
const login_mod = @import("pv-login.zig");

pub const Login = login_mod.Login;

// NetBefore = nothing left this machine (safe to try again); Lost = the request may have reached X (a refresh may have burned the token)
pub const Err = error{ NoClientId, NoSecret, NoLogin, InvalidGrant, AuthFail, NetBefore, Lost, BadReply, OutOfMemory, StateMismatch, NoCode, Timeout, Listen, Denied, NotPublisher, SaveFail };

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
    const ac = cx.cfg.account;
    const id = secret(cx, a, ac.client_id_env, ac.client_id_file) orelse return Err.NoClientId;
    const sec = secret(cx, a, ac.client_secret_env, ac.client_secret_file) orelse "";
    if (std.mem.eql(u8, cx.cfg.auth.client_type, "confidential") and sec.len == 0) return Err.NoSecret;
    return .{ .id = id, .secret = sec };
}

const TokenReply = struct { access_token: []const u8 = "", refresh_token: []const u8 = "", expires_in: i64 = 0, token_type: []const u8 = "", scope: []const u8 = "", @"error": []const u8 = "", error_description: []const u8 = "" };

fn form(a: std.mem.Allocator, pairs: []const [2][]const u8) ![]u8 {
    var o: std.ArrayList(u8) = .empty;
    for (pairs) |kv| {
        if (kv[1].len == 0) continue;
        if (o.items.len > 0) try o.append(a, '&');
        try o.print(a, "{s}={s}", .{ kv[0], try util.pct(a, kv[1]) });
    }
    return o.toOwnedSlice(a);
}

fn isGuard(e: anyerror) bool {
    inline for (@typeInfo(guard.GuardErr).error_set.?) |f| if (e == @field(guard.GuardErr, f.name)) return true;
    return false;
}

// Basic base64(id:secret) for a confidential client
fn basicHeader(a: std.mem.Allocator, c: Creds) ![]u8 {
    const raw = try std.fmt.allocPrint(a, "{s}:{s}", .{ c.id, c.secret });
    const enc = std.base64.standard.Encoder;
    const out = try a.alloc(u8, enc.calcSize(raw.len));
    _ = enc.encode(out, raw);
    return std.fmt.allocPrint(a, "Basic {s}", .{out});
}

fn postToken(cx: *const ctx_mod.Ctx, a: std.mem.Allocator, c: Creds, body: []const u8) Err!TokenReply {
    var hs: [2]std.http.Header = undefined;
    hs[0] = .{ .name = "Content-Type", .value = "application/x-www-form-urlencoded" };
    var n: usize = 1;
    if (std.mem.eql(u8, cx.cfg.auth.client_type, "confidential")) {
        hs[1] = .{ .name = "Authorization", .value = basicHeader(a, c) catch return Err.OutOfMemory };
        n = 2;
    }
    const r = http.send(cx, a, .{ .method = "POST", .url = cx.cfg.auth.token_url, .headers = hs[0..n], .body = .{ .bytes = body } }) catch |e| {
        if (e == error.OutOfMemory) return Err.OutOfMemory;
        if (e == error.Connect or e == error.Tls or isGuard(e)) return Err.NetBefore;
        return Err.Lost;
    };
    const t = std.json.parseFromSliceLeaky(TokenReply, a, r.body, .{ .ignore_unknown_fields = true }) catch {
        if (r.status >= 500) return Err.AuthFail;
        return if (r.status >= 400) Err.InvalidGrant else Err.BadReply;
    };
    if (r.status == 200 and t.access_token.len > 0) return t;
    if (std.mem.eql(u8, t.@"error", "access_denied")) return Err.Denied;
    // the error body of a dead refresh token is not documented: any 4xx is "dead", a 5xx is "try later"
    if (r.status >= 400 and r.status < 500) return Err.InvalidGrant;
    return Err.AuthFail;
}

fn loginFrom(cx: *const ctx_mod.Ctx, t: TokenReply, keep_refresh: []const u8) Login {
    const now = cx.nowMs();
    const ttl: i64 = if (t.expires_in > 0) t.expires_in else 7200;
    return .{ .access = t.access_token, .refresh = if (t.refresh_token.len > 0) t.refresh_token else keep_refresh, .expires_ms = now + ttl * 1000, .issued_ms = now };
}

// the login on disk (newest valid file)
pub fn current(cx: *const ctx_mod.Ctx, a: std.mem.Allocator) Err!Login {
    return login_mod.read(cx, a) orelse Err.NoLogin;
}

pub fn due(cx: *const ctx_mod.Ctx, l: Login, margin_s: i64) bool {
    return cx.nowMs() + margin_s * 1000 >= l.expires_ms;
}

// POST grant_type=refresh_token. The answer carries a NEW refresh token and the old one is dead: the new pair is on disk before this returns.
// Only a publisher device may rotate the login; callers hold the run lock.
pub fn refreshNow(cx: *const ctx_mod.Ctx, a: std.mem.Allocator, cur: Login) Err!Login {
    if (!cx.cfg.device.publisher) return Err.NotPublisher;
    const c = try creds(cx, a);
    const body = form(a, &.{ .{ "grant_type", "refresh_token" }, .{ "refresh_token", cur.refresh }, .{ "client_id", if (std.mem.eql(u8, cx.cfg.auth.client_type, "public")) c.id else "" } }) catch return Err.OutOfMemory;
    const t = try postToken(cx, a, c, body);
    if (t.refresh_token.len == 0) return Err.BadReply; // offline.access missing: the next refresh would have nothing to use
    const nl = loginFrom(cx, t, cur.refresh);
    login_mod.save(cx, a, nl) catch return Err.SaveFail;
    return nl;
}

// a usable access token: the stored one, refreshed first when it ends within token_refresh_s
pub fn fresh(cx: *const ctx_mod.Ctx, a: std.mem.Allocator, margin_s: i64) Err!Login {
    const cur = try current(cx, a);
    if (!due(cx, cur, margin_s)) return cur;
    return refreshNow(cx, a, cur);
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

pub fn redirectFor(cx: *const ctx_mod.Ctx, a: std.mem.Allocator, port: u16) ![]u8 {
    if (cx.cfg.auth.redirect_uri.len > 0) return a.dupe(u8, cx.cfg.auth.redirect_uri);
    return std.fmt.allocPrint(a, "http://127.0.0.1:{d}/callback", .{port});
}

// builds the consent url (the redirect is exact: it must be one of the app's callback URLs, port included)
pub fn prepare(cx: *const ctx_mod.Ctx, a: std.mem.Allocator, port: u16) Err!Prep {
    const c = try creds(cx, a);
    const au = cx.cfg.auth;
    const verifier = randB64(cx, a, 32) catch return Err.OutOfMemory;
    const challenge = pkceChallenge(a, verifier) catch return Err.OutOfMemory;
    const state = randB64(cx, a, 16) catch return Err.OutOfMemory;
    const redirect = redirectFor(cx, a, port) catch return Err.OutOfMemory;
    const scope = std.mem.join(a, " ", au.scopes) catch return Err.OutOfMemory;
    const q = form(a, &.{
        .{ "response_type", "code" },
        .{ "client_id", c.id },
        .{ "redirect_uri", redirect },
        .{ "scope", scope },
        .{ "state", state },
        .{ "code_challenge", challenge },
        .{ "code_challenge_method", "S256" },
    }) catch return Err.OutOfMemory;
    const url = std.fmt.allocPrint(a, "{s}?{s}", .{ au.authorize_url, q }) catch return Err.OutOfMemory;
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

// code -> login pair (stored by the caller through pv-login). The code lives 30 seconds: exchange at once.
pub fn exchange(cx: *const ctx_mod.Ctx, a: std.mem.Allocator, code: []const u8, p: Prep) Err!Login {
    const c = try creds(cx, a);
    const body = form(a, &.{ .{ "grant_type", "authorization_code" }, .{ "code", code }, .{ "redirect_uri", p.redirect }, .{ "code_verifier", p.verifier }, .{ "client_id", if (std.mem.eql(u8, cx.cfg.auth.client_type, "public")) c.id else "" } }) catch return Err.OutOfMemory;
    const t = try postToken(cx, a, c, body);
    if (t.refresh_token.len == 0) return Err.AuthFail; // offline.access was not granted
    return loginFrom(cx, t, "");
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
    try std.testing.expectEqualStrings("abc123", try codeFrom(a, "/?code=abc%2F123&state=S1&scope=x", "S1"));
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
    try std.testing.expect(secret(&cx, a, "XDOT_CLIENT_ID", "id.txt") == null);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/id.txt", .{dir}), .data = "from-file\n" });
    try std.testing.expectEqualStrings("from-file", secret(&cx, a, "XDOT_CLIENT_ID", "id.txt").?);
    try env.put("XDOT_CLIENT_ID", "from-env");
    try std.testing.expectEqualStrings("from-env", secret(&cx, a, "XDOT_CLIENT_ID", "id.txt").?);
}

test "prepare: exact redirect with the port, S256, every scope, no localhost" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var env = std.process.Environ.Map.init(a);
    try env.put("XDOT_CLIENT_ID", "CID");
    try env.put("XDOT_CLIENT_SECRET", "SEC");
    const cx = ctx_mod.testCtx(a, &env, ".");
    const p = try prepare(&cx, a, 8765);
    try std.testing.expectEqualStrings("http://127.0.0.1:8765/callback", p.redirect);
    try std.testing.expect(std.mem.startsWith(u8, p.url, "https://x.com/i/oauth2/authorize?"));
    try std.testing.expect(std.mem.indexOf(u8, p.url, "code_challenge_method=S256") != null);
    try std.testing.expect(std.mem.indexOf(u8, p.url, "media.write") != null and std.mem.indexOf(u8, p.url, "offline.access") != null);
    try std.testing.expect(std.mem.indexOf(u8, p.url, "SEC") == null and std.mem.indexOf(u8, p.url, "localhost") == null);
    // a confidential client without a secret cannot log in
    var env2 = std.process.Environ.Map.init(a);
    try env2.put("XDOT_CLIENT_ID", "CID");
    const cx2 = ctx_mod.testCtx(a, &env2, ".");
    try std.testing.expectError(Err.NoSecret, prepare(&cx2, a, 8765));
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
