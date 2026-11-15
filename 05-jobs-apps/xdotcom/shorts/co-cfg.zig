// =====================================================================
// Des: Reads 00-config.json strictly - an unknown or wrong setting stops the app with the line and column, and every number is range-checked; the locked safety switches cannot be turned off
// Flo: read file > strict JSON parse into typed structs > range checks > Config (arena-owned) or a one-line reason
// Cre: 2026-11-16                          - | Mod: 2026-11-16
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: path of 00-config.json (or its text), arena allocator
// Out: Config | LoadErr with `why` filled for the user
// Run: not run directly - imported by main and the context
// =====================================================================
const std = @import("std");

pub const Device = struct { publisher: bool = false };
pub const Source = struct { dir: []const u8 = "", max_age_days: u32 = 14 };
pub const Limits = struct { daily_cap: u32 = 3, daily_cap_max: u32 = 50, rate_margin: u32 = 5, gap_min_s: u32 = 600, gap_max_s: u32 = 1800, disk_min_mb: u32 = 500, run_budget_s: u32 = 2400, budget_usd: f64 = 5.0 };
pub const Cost = struct { post_usd: f64 = 0.015, post_url_usd: f64 = 0.2, media_usd: f64 = 0.0 };
pub const Video = struct {
    min_ms: u32 = 500,
    max_s: u32 = 90,
    max_mb: u32 = 512,
    fps_max: u32 = 60,
    dims_policy: []const u8 = "warn",
    box_long: u32 = 1280,
    box_short: u32 = 1024,
    side_min: u32 = 32,
    ratio_max: u32 = 3,
};
pub const Post = struct {
    public: bool = false,
    ai_notice_required: bool = true,
    text_max: u32 = 280,
    text_margin: u32 = 6,
    tags_max: u32 = 3,
    url_in_text: bool = false,
    url_guard: bool = true,
};
pub const Net = struct {
    timeout_s: u32 = 60,
    upload_timeout_s: u32 = 300,
    chunk_mb: u32 = 4,
    backoff_ms: u32 = 2000,
    poll_min_s: u32 = 1,
    poll_max_s: u32 = 10,
    processing_max_s: u32 = 600,
    retry_chunk: u32 = 3,
    media_ttl_h: u32 = 20,
    body_cap_kb: u32 = 1024,
    user_agent: []const u8 = "xdot-shorts/0.1",
    allow_hosts: []const []const u8 = &.{"api.x.com"},
};
pub const Breaker = struct { fails: u32 = 3, cool_h: u32 = 6 };
pub const Safety = struct { dup_probe: bool = true, dup_probe_max: u32 = 10, confirm_read: bool = false };
pub const Resolve = struct { min_wait_s: u32 = 120 };
pub const Approval = struct { require_for_review: bool = true };
pub const Account = struct {
    client_id_env: []const u8 = "XDOT_CLIENT_ID",
    client_secret_env: []const u8 = "XDOT_CLIENT_SECRET",
    client_id_file: []const u8 = "xdot-client-id.txt",
    client_secret_file: []const u8 = "xdot-client-secret.txt",
    login_file: []const u8 = "xdot-login.dat",
    user_id_file: []const u8 = "xdot-user-id.txt",
};
pub const Auth = struct {
    client_type: []const u8 = "confidential",
    authorize_url: []const u8 = "https://x.com/i/oauth2/authorize",
    token_url: []const u8 = "https://api.x.com/2/oauth2/token",
    scopes: []const []const u8 = &.{ "tweet.read", "tweet.write", "users.read", "media.write", "offline.access" },
    redirect_uri: []const u8 = "",
    port: u32 = 8765,
    login_wait_s: u32 = 300,
};
pub const Api = struct {
    base: []const u8 = "https://api.x.com",
    web_base: []const u8 = "https://x.com",
    fields_param: []const u8 = "post.fields",
};

pub const Config = struct {
    data_dir: []const u8 = "",
    secrets_dir: []const u8 = "",
    tz_offset_hours: i32 = 7,
    db_file: []const u8 = "ledger.db",
    kill_file: []const u8 = "KILL",
    device: Device = .{},
    source: Source = .{},
    limits: Limits = .{},
    cost: Cost = .{},
    video: Video = .{},
    post: Post = .{},
    net: Net = .{},
    breaker: Breaker = .{},
    safety: Safety = .{},
    resolve: Resolve = .{},
    account: Account = .{},
    auth: Auth = .{},
    api: Api = .{},
    approval: Approval = .{},
    retry_pre_send: u32 = 2,
    token_refresh_s: u32 = 600,
    token_warn_days: u32 = 30,
};

pub const LoadErr = error{ BadConfig, NoConfig, OutOfMemory };

fn bad(why: *[160]u8, why_len: *usize, comptime fmt: []const u8, args: anytype) LoadErr {
    const s = std.fmt.bufPrint(why, fmt, args) catch "config: bad";
    why_len.* = s.len;
    return LoadErr.BadConfig;
}

fn oneOf(v: []const u8, list: []const []const u8) bool {
    for (list) |l| if (std.mem.eql(u8, v, l)) return true;
    return false;
}

fn hasScope(c: Config, s: []const u8) bool {
    for (c.auth.scopes) |x| if (std.mem.eql(u8, x, s)) return true;
    return false;
}

// range + safety checks on a parsed config
pub fn validate(c: Config, why: *[160]u8, why_len: *usize) LoadErr!void {
    if (c.limits.daily_cap == 0 or c.limits.daily_cap > c.limits.daily_cap_max) return bad(why, why_len, "config: limits.daily_cap must be 1..daily_cap_max ({d})", .{c.limits.daily_cap_max});
    if (c.limits.daily_cap_max == 0 or c.limits.daily_cap_max > 50) return bad(why, why_len, "config: limits.daily_cap_max must be 1..50 (this app posts shorts, it does not flood)", .{});
    if (c.limits.gap_min_s > c.limits.gap_max_s) return bad(why, why_len, "config: limits.gap_min_s must be <= gap_max_s", .{});
    if (c.limits.run_budget_s == 0 or c.limits.run_budget_s <= c.net.upload_timeout_s) return bad(why, why_len, "config: limits.run_budget_s must be longer than net.upload_timeout_s ({d}s)", .{c.net.upload_timeout_s});
    if (!(c.limits.budget_usd >= 0.0) or c.limits.budget_usd > 100000.0) return bad(why, why_len, "config: limits.budget_usd must be 0..100000", .{});
    if (!(c.cost.post_usd >= 0.0) or !(c.cost.post_url_usd >= 0.0) or !(c.cost.media_usd >= 0.0)) return bad(why, why_len, "config: cost.* must be >= 0", .{});
    if (c.video.min_ms == 0 or c.video.max_s == 0 or c.video.max_s > 1200) return bad(why, why_len, "config: video.min_ms > 0 and 1 <= video.max_s <= 1200", .{});
    if (c.video.max_mb == 0 or c.video.max_mb > 8192 or c.video.fps_max == 0 or c.video.fps_max > 60) return bad(why, why_len, "config: video.max_mb 1..8192 and video.fps_max 1..60", .{});
    if (!oneOf(c.video.dims_policy, &.{ "warn", "strict" })) return bad(why, why_len, "config: video.dims_policy must be warn or strict", .{});
    if (c.video.box_long == 0 or c.video.box_short == 0 or c.video.box_short > c.video.box_long or c.video.side_min == 0 or c.video.ratio_max == 0) return bad(why, why_len, "config: video.box_* and side_min and ratio_max must be sane (box_short <= box_long)", .{});
    if (!c.post.ai_notice_required) return bad(why, why_len, "config: post.ai_notice_required is locked true (the AI label has no off switch)", .{});
    if (!c.approval.require_for_review) return bad(why, why_len, "config: approval.require_for_review is locked true (a person must look at review videos)", .{});
    if (c.post.text_max == 0 or c.post.text_max > 25000) return bad(why, why_len, "config: post.text_max must be 1..25000", .{});
    if (c.post.text_margin >= c.post.text_max) return bad(why, why_len, "config: post.text_margin must be smaller than text_max", .{});
    if (c.post.tags_max > 10) return bad(why, why_len, "config: post.tags_max must be 0..10", .{});
    if (c.post.url_in_text and !c.post.url_guard and c.limits.budget_usd <= 0.0) return bad(why, why_len, "config: url_in_text with url_guard off needs a budget (limits.budget_usd > 0)", .{});
    if (c.net.timeout_s == 0 or c.net.upload_timeout_s == 0 or c.net.body_cap_kb == 0) return bad(why, why_len, "config: net timeouts and body_cap_kb must be > 0", .{});
    if (c.net.chunk_mb == 0 or c.net.chunk_mb > 5) return bad(why, why_len, "config: net.chunk_mb must be 1..5 (X: segments at or below 5 MB)", .{});
    if (c.net.retry_chunk > 10) return bad(why, why_len, "config: net.retry_chunk must be 0..10", .{});
    if (c.net.poll_min_s == 0 or c.net.poll_min_s > c.net.poll_max_s) return bad(why, why_len, "config: net.poll_min_s must be 1..poll_max_s", .{});
    if (c.net.processing_max_s == 0 or c.net.media_ttl_h == 0 or c.net.media_ttl_h > 24) return bad(why, why_len, "config: net.processing_max_s > 0 and net.media_ttl_h 1..24", .{});
    if (c.net.allow_hosts.len == 0) return bad(why, why_len, "config: net.allow_hosts must not be empty", .{});
    if (c.breaker.fails == 0 or c.breaker.cool_h == 0) return bad(why, why_len, "config: breaker.fails and cool_h must be > 0", .{});
    if (c.safety.dup_probe_max < 5 or c.safety.dup_probe_max > 100) return bad(why, why_len, "config: safety.dup_probe_max must be 5..100 (X: max_results 5..100)", .{});
    if (c.retry_pre_send > 5) return bad(why, why_len, "config: retry_pre_send must be 0..5", .{});
    if (c.token_refresh_s < 60 or c.token_refresh_s > 3600) return bad(why, why_len, "config: token_refresh_s must be 60..3600", .{});
    if (c.token_warn_days == 0) return bad(why, why_len, "config: token_warn_days must be > 0", .{});
    if (c.tz_offset_hours < -12 or c.tz_offset_hours > 14) return bad(why, why_len, "config: tz_offset_hours must be -12..14", .{});
    if (c.db_file.len == 0 or c.kill_file.len == 0 or c.account.login_file.len == 0 or c.account.user_id_file.len == 0) return bad(why, why_len, "config: db_file, kill_file, account.login_file and user_id_file must not be empty", .{});
    if (!oneOf(c.auth.client_type, &.{ "confidential", "public" })) return bad(why, why_len, "config: auth.client_type must be confidential or public", .{});
    if (!hasScope(c, "media.write") or !hasScope(c, "offline.access") or !hasScope(c, "tweet.write")) return bad(why, why_len, "config: auth.scopes must include tweet.write, media.write and offline.access", .{});
    if (c.auth.port == 0 or c.auth.port > 65535 or c.auth.login_wait_s == 0) return bad(why, why_len, "config: auth.port 1..65535 (the callback is exact, with its port) and login_wait_s > 0", .{});
    if (std.mem.indexOf(u8, c.auth.redirect_uri, "localhost") != null) return bad(why, why_len, "config: auth.redirect_uri must use 127.0.0.1, not localhost (X rule)", .{});
    if (c.auth.authorize_url.len == 0 or c.auth.token_url.len == 0 or c.api.base.len == 0 or c.api.web_base.len == 0 or c.api.fields_param.len == 0) return bad(why, why_len, "config: auth and api urls must not be empty", .{});
}

// Parse text strictly. On failure `why` gets a one-line reason with line/col.
pub fn parse(arena: std.mem.Allocator, text: []const u8, why: *[160]u8, why_len: *usize) LoadErr!Config {
    var diag = std.json.Diagnostics{};
    var sc = std.json.Scanner.initCompleteInput(arena, text);
    defer sc.deinit();
    sc.enableDiagnostics(&diag);
    const cfg = std.json.parseFromTokenSourceLeaky(Config, arena, &sc, .{ .ignore_unknown_fields = false }) catch |e| {
        return bad(why, why_len, "config: {s} at line {d} col {d}", .{ @errorName(e), diag.getLine(), diag.getColumn() });
    };
    try validate(cfg, why, why_len);
    return cfg;
}

pub fn load(arena: std.mem.Allocator, io: std.Io, path: []const u8, why: *[160]u8, why_len: *usize) LoadErr!Config {
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(256 * 1024)) catch {
        const s = std.fmt.bufPrint(why, "config: cannot read {s}", .{path}) catch "config: unreadable";
        why_len.* = s.len;
        return LoadErr.NoConfig;
    };
    const body = if (std.mem.startsWith(u8, text, "\xef\xbb\xbf")) text[3..] else text;
    return parse(arena, body, why, why_len);
}

fn expectBad(text: []const u8, needle: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var w: [160]u8 = undefined;
    var n: usize = 0;
    try std.testing.expectError(LoadErr.BadConfig, parse(arena.allocator(), text, &w, &n));
    try std.testing.expect(std.mem.indexOf(u8, w[0..n], needle) != null);
}

test "strict: unknown key refused with line and col" {
    try expectBad("{\"limitz\":{}}", "line 1");
    try expectBad("{\"post\":{\"publik\":true}}", "UnknownField");
}

test "safe defaults parse: nothing public, label on, one device flag off, no url in text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var w: [160]u8 = undefined;
    var n: usize = 0;
    const c = try parse(arena.allocator(), "{}", &w, &n);
    try std.testing.expect(!c.post.public and !c.device.publisher and !c.post.url_in_text and c.post.url_guard);
    try std.testing.expect(c.post.ai_notice_required and c.approval.require_for_review);
    try std.testing.expectEqual(@as(u32, 280), c.post.text_max);
}

test "locked safety switches and ranges are refused" {
    try expectBad("{\"post\":{\"ai_notice_required\":false}}", "ai_notice_required");
    try expectBad("{\"approval\":{\"require_for_review\":false}}", "require_for_review");
    try expectBad("{\"limits\":{\"daily_cap\":0}}", "daily_cap");
    try expectBad("{\"limits\":{\"daily_cap\":60,\"daily_cap_max\":60}}", "daily_cap_max");
    try expectBad("{\"limits\":{\"gap_min_s\":9,\"gap_max_s\":3}}", "gap_min_s");
    try expectBad("{\"net\":{\"chunk_mb\":6}}", "chunk_mb");
    try expectBad("{\"net\":{\"chunk_mb\":0}}", "chunk_mb");
    try expectBad("{\"net\":{\"allow_hosts\":[]}}", "allow_hosts");
    try expectBad("{\"safety\":{\"dup_probe_max\":4}}", "dup_probe_max");
    try expectBad("{\"auth\":{\"scopes\":[\"tweet.write\",\"tweet.read\"]}}", "auth.scopes");
    try expectBad("{\"auth\":{\"redirect_uri\":\"http://localhost:8765/callback\"}}", "localhost");
    try expectBad("{\"video\":{\"dims_policy\":\"loose\"}}", "dims_policy");
    try expectBad("{\"post\":{\"text_margin\":280}}", "text_margin");
    try expectBad("{\"post\":{\"url_in_text\":true,\"url_guard\":false},\"limits\":{\"budget_usd\":0}}", "budget");
}

test "shipped 00-config.json parses and equals the defaults" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var w: [160]u8 = undefined;
    var n: usize = 0;
    const c = try load(arena.allocator(), std.testing.io, "00-config.json", &w, &n);
    const d: Config = .{};
    try std.testing.expectEqual(d.device.publisher, c.device.publisher);
    try std.testing.expectEqual(d.limits.daily_cap, c.limits.daily_cap);
    try std.testing.expectEqual(d.limits.budget_usd, c.limits.budget_usd);
    try std.testing.expectEqual(d.cost.post_usd, c.cost.post_usd);
    try std.testing.expectEqual(d.cost.post_url_usd, c.cost.post_url_usd);
    try std.testing.expectEqual(d.video.max_s, c.video.max_s);
    try std.testing.expectEqualStrings(d.video.dims_policy, c.video.dims_policy);
    try std.testing.expectEqual(d.post.public, c.post.public);
    try std.testing.expectEqual(d.post.text_max, c.post.text_max);
    try std.testing.expectEqual(d.post.url_in_text, c.post.url_in_text);
    try std.testing.expectEqual(d.net.chunk_mb, c.net.chunk_mb);
    try std.testing.expectEqual(d.net.media_ttl_h, c.net.media_ttl_h);
    try std.testing.expectEqual(d.breaker.fails, c.breaker.fails);
    try std.testing.expectEqual(d.safety.dup_probe, c.safety.dup_probe);
    try std.testing.expectEqual(d.resolve.min_wait_s, c.resolve.min_wait_s);
    try std.testing.expectEqualStrings(d.auth.token_url, c.auth.token_url);
    try std.testing.expectEqualStrings(d.auth.authorize_url, c.auth.authorize_url);
    try std.testing.expectEqual(d.auth.scopes.len, c.auth.scopes.len);
    try std.testing.expectEqual(d.auth.port, c.auth.port);
    try std.testing.expectEqualStrings(d.api.base, c.api.base);
    try std.testing.expectEqualStrings(d.api.fields_param, c.api.fields_param);
    try std.testing.expectEqual(d.token_refresh_s, c.token_refresh_s);
    try std.testing.expectEqual(d.token_warn_days, c.token_warn_days);
    try std.testing.expectEqualStrings("", c.source.dir);
}
// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
