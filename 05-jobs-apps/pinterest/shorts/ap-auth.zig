// Pinterest sign-in: OAuth authorization code (one-time, owner) + refresh (every run, automatic). Tokens live in ONE file in secrets_dir (mode 0600, atomic write).
// The refresh token rotates: the new pair is written to disk BEFORE it is used, so a crash never loses the live token.
const std = @import("std");
const Ctx = @import("co-ctx.zig").Ctx;
const call = @import("ap-call.zig");
const js = @import("ap-json.zig");
const util = @import("co-util.zig");

pub const Tokens = struct { access_token: []const u8 = "", refresh_token: []const u8 = "", access_expires_at: i64 = 0, refresh_expires_at: i64 = 0, scope: []const u8 = "" };

pub fn tokenPath(cx: *const Ctx, a: std.mem.Allocator) ![]u8 {
    return cx.secretPath(a, cx.cfg.api.token_file);
}

// env override = access token only (no refresh, expiry unknown); else the token file; null = no sign-in yet
pub fn load(cx: *const Ctx, a: std.mem.Allocator) ?Tokens {
    if (cx.envGet(cx.cfg.api.access_token_env)) |v| return .{ .access_token = a.dupe(u8, std.mem.trim(u8, v, " \t\r\n")) catch return null };
    const p = tokenPath(cx, a) catch return null;
    const txt = util.readAll(a, cx.io, p, 16 * 1024) catch return null;
    const t = std.json.parseFromSliceLeaky(Tokens, a, txt, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return null;
    return if (t.access_token.len == 0) null else t;
}

fn store(cx: *const Ctx, a: std.mem.Allocator, t: Tokens) !void {
    const dir = try cx.path(a, cx.cfg.secrets_dir);
    try util.mkdirp(cx.io, dir);
    const body = try std.json.Stringify.valueAlloc(a, t, .{});
    try util.writeAtomicPriv(a, cx.io, try tokenPath(cx, a), body);
}

const Reply = struct { access_token: []const u8 = "", refresh_token: []const u8 = "", expires_in: i64 = 0, refresh_token_expires_in: i64 = 0, refresh_token_expires_at: i64 = 0, scope: []const u8 = "" };

fn form(a: std.mem.Allocator, pairs: []const [2][]const u8) ![]u8 {
    var o: std.ArrayList(u8) = .empty;
    for (pairs) |kv| {
        if (kv[1].len == 0) continue;
        if (o.items.len > 0) try o.append(a, '&');
        try o.print(a, "{s}={s}", .{ kv[0], try util.pct(a, kv[1]) });
    }
    return o.items;
}

fn tokenCall(cx: *const Ctx, a: std.mem.Allocator, body: []const u8) call.Out(Reply) {
    const oomf: call.Out(Reply) = .{ .fail = .{ .info = .{ .class = .failed, .msg = "out of memory" } } };
    const id = cx.clientId() orelse return .{ .fail = .{ .info = .{ .class = .blocked, .msg = "no app id: set the env var or the file named in config api.app_id_*" } } };
    const sec = cx.clientSecret() orelse return .{ .fail = .{ .info = .{ .class = .blocked, .msg = "no app secret: set the env var or the file named in config api.app_secret_*" } } };
    const idsec = std.fmt.allocPrint(a, "{s}:{s}", .{ id, sec }) catch return oomf;
    const url = call.apiUrl(cx, a, "oauth/token") catch return oomf;
    switch (call.call(cx, a, .{ .method = "POST", .url = url, .auth = .{ .basic = idsec }, .body = body, .ctype = "application/x-www-form-urlencoded" })) {
        .fail => |f| return .{ .fail = f },
        .ok => |ok| {
            const r = std.json.parseFromSliceLeaky(Reply, a, ok.body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return .{ .fail = .{ .info = .{ .class = .failed, .msg = "token reply unreadable" } } };
            if (r.access_token.len == 0) return .{ .fail = .{ .info = .{ .class = .failed, .msg = "token reply has no access_token" } } };
            return .{ .ok = r };
        },
    }
}

fn merge(cx: *const Ctx, old: Tokens, r: Reply) Tokens {
    const now_s = @divTrunc(cx.nowMs(), 1000);
    var rexp = old.refresh_expires_at;
    if (r.refresh_token_expires_at > 0) rexp = r.refresh_token_expires_at else if (r.refresh_token_expires_in > 0) rexp = now_s + r.refresh_token_expires_in;
    return .{
        .access_token = r.access_token,
        .refresh_token = if (r.refresh_token.len > 0) r.refresh_token else old.refresh_token,
        .access_expires_at = if (r.expires_in > 0) now_s + r.expires_in else 0,
        .refresh_expires_at = rexp,
        .scope = if (r.scope.len > 0) r.scope else old.scope,
    };
}

// code -> first token pair, stored. The one hand job (owner), then never again.
pub fn exchange(cx: *const Ctx, a: std.mem.Allocator, code: []const u8) call.Out(Tokens) {
    const body = form(a, &.{ .{ "grant_type", "authorization_code" }, .{ "code", code }, .{ "redirect_uri", cx.cfg.api.redirect_uri }, .{ "continuous_refresh", "true" } }) catch return .{ .fail = .{ .info = .{ .class = .failed, .msg = "out of memory" } } };
    switch (tokenCall(cx, a, body)) {
        .fail => |f| return .{ .fail = f },
        .ok => |r| {
            const t = merge(cx, .{}, r);
            store(cx, a, t) catch return .{ .fail = .{ .info = .{ .class = .failed, .msg = "cannot write the token file in secrets_dir" } } };
            return .{ .ok = t };
        },
    }
}

// refresh token -> new pair, stored BEFORE anyone uses it
pub fn refresh(cx: *const Ctx, a: std.mem.Allocator, old: Tokens) call.Out(Tokens) {
    if (old.refresh_token.len == 0) return .{ .fail = .{ .info = .{ .class = .blocked, .msg = "no refresh token: run login" } } };
    const body = form(a, &.{ .{ "grant_type", "refresh_token" }, .{ "refresh_token", old.refresh_token } }) catch return .{ .fail = .{ .info = .{ .class = .failed, .msg = "out of memory" } } };
    switch (tokenCall(cx, a, body)) {
        .fail => |f| return .{ .fail = f },
        .ok => |r| {
            const t = merge(cx, old, r);
            store(cx, a, t) catch return .{ .fail = .{ .info = .{ .class = .failed, .msg = "cannot write the token file in secrets_dir" } } };
            return .{ .ok = t };
        },
    }
}

pub const Ensured = union(enum) { ok: []const u8, fail: struct { msg: []const u8, dead: bool } };

// a usable access token: refreshed first when it has < token_refresh_days left. `allow_refresh` false = read-only checks.
pub fn ensure(cx: *const Ctx, a: std.mem.Allocator, allow_refresh: bool) Ensured {
    const t = load(cx, a) orelse return .{ .fail = .{ .msg = "no sign-in yet: run login (see 10-HOW-TO)", .dead = true } };
    if (t.access_expires_at == 0) return .{ .ok = t.access_token }; // env token or unknown expiry: use as is
    const now_s = @divTrunc(cx.nowMs(), 1000);
    const left = t.access_expires_at - now_s;
    if (left > @as(i64, cx.cfg.token_refresh_days) * 86400) return .{ .ok = t.access_token };
    if (!allow_refresh) return if (left > 0) .{ .ok = t.access_token } else .{ .fail = .{ .msg = "access token expired: a live run refreshes it, or run token --refresh --live", .dead = false } };
    switch (refresh(cx, a, t)) {
        .ok => |n| return .{ .ok = n.access_token },
        .fail => |f| {
            if (left > 0 and f.info.class != .blocked) return .{ .ok = t.access_token }; // refresh failed for now, old token still lives
            return .{ .fail = .{ .msg = if (f.info.class == .blocked) "sign-in is dead (refresh refused): run login again" else f.info.msg, .dead = f.info.class == .blocked } };
        },
    }
}

pub fn authorizeUrl(cx: *const Ctx, a: std.mem.Allocator, state: []const u8) ![]u8 {
    const sc = try std.mem.join(a, " ", cx.cfg.api.scopes);
    const id = cx.clientId() orelse return error.NoClientId;
    const q = try form(a, &.{ .{ "client_id", id }, .{ "redirect_uri", cx.cfg.api.redirect_uri }, .{ "response_type", "code" }, .{ "scope", sc }, .{ "state", state } });
    return std.fmt.allocPrint(a, "{s}?{s}", .{ cx.cfg.api.authorize_url, q });
}

pub const CodeErr = error{ NoCode, StateMismatch, Denied };

// the pasted redirect address (or a bare code) -> the code. State is checked when the address carries one.
pub fn codeFrom(a: std.mem.Allocator, pasted: []const u8, want_state: []const u8) CodeErr![]const u8 {
    const text = std.mem.trim(u8, pasted, " \r\n\t");
    const q = std.mem.indexOfScalar(u8, text, '?') orelse {
        return if (text.len > 0 and std.mem.indexOfAny(u8, text, " /=&") == null) text else CodeErr.NoCode;
    };
    var code: []const u8 = "";
    var state: []const u8 = "";
    var errv: []const u8 = "";
    var it = std.mem.tokenizeAny(u8, text[q + 1 ..], "& ");
    while (it.next()) |kv| {
        const eq = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
        const v = util.unpct(a, kv[eq + 1 ..]) orelse continue;
        const k = kv[0..eq];
        if (std.mem.eql(u8, k, "code")) code = v;
        if (std.mem.eql(u8, k, "state")) state = v;
        if (std.mem.eql(u8, k, "error")) errv = v;
    }
    if (errv.len > 0) return CodeErr.Denied;
    if (!std.mem.eql(u8, state, want_state)) return CodeErr.StateMismatch;
    if (code.len == 0) return CodeErr.NoCode;
    return code;
}

test "codeFrom: address or bare code, state checked, denial refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("abc123", try codeFrom(a, "http://localhost:8085/?code=abc123&state=S1", "S1"));
    try std.testing.expectEqualStrings("abc123", try codeFrom(a, "  abc123\n", "S1"));
    try std.testing.expectError(CodeErr.StateMismatch, codeFrom(a, "http://localhost:8085/?code=abc&state=OTHER", "S1"));
    try std.testing.expectError(CodeErr.Denied, codeFrom(a, "http://localhost:8085/?error=access_denied&state=S1", "S1"));
    try std.testing.expectError(CodeErr.NoCode, codeFrom(a, "http://localhost:8085/?state=S1", "S1"));
    try std.testing.expectError(CodeErr.NoCode, codeFrom(a, "", "S1"));
}

test "form encodes values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const s = try form(arena.allocator(), &.{ .{ "a", "x y&z" }, .{ "empty", "" }, .{ "b", "1" } });
    try std.testing.expectEqualStrings("a=x%20y%26z&b=1", s);
}
