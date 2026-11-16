// =====================================================================
// Des: Reads 00-config.json strictly - an unknown or wrong setting stops the app with the line and column, and every number is range-checked
// Flo: read file > strict JSON parse into typed structs > range checks > Config (arena-owned) or a one-line reason
// Cre: 2026-11-15                          - | Mod: 2026-11-15
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: path of 00-config.json (or its text), arena allocator
// Out: Config | LoadErr with `why` filled for the user
// Run: not run directly - imported by main and the context
// =====================================================================
const std = @import("std");
const slot = @import("rw-slot.zig");

pub const Source = struct { dir: []const u8 = "", slot_hours: []const u8 = "8,14,20", max_age_h: u32 = 48 };
pub const Limits = struct { daily_cap: u32 = 3, daily_cap_max: u32 = 100, gap_min_s: u32 = 600, gap_max_s: u32 = 1800, disk_min_mb: u32 = 500, run_budget_s: u32 = 2400 };
pub const Video = struct { min_s: u32 = 3, max_s: u32 = 60, min_w: u32 = 540, min_h: u32 = 960, max_mb: u32 = 512, want_faststart: bool = true };
pub const Post = struct {
    public: bool = false,
    visibility: []const u8 = "private",
    made_for_kids: bool = false,
    ai_notice_required: bool = true,
    notify_subscribers: bool = false,
    shorts_tag: bool = false,
    include_listing_url: bool = true,
    category_id: []const u8 = "2",
    title_max: u32 = 100,
    desc_max_bytes: u32 = 5000,
    tags_max_chars: u32 = 500,
    hashtags_max: u32 = 15,
};
pub const Net = struct {
    timeout_s: u32 = 60,
    upload_timeout_s: u32 = 1800,
    chunk_kb: u32 = 256,
    backoff_ms: u32 = 2000,
    retries: u32 = 5,
    status_poll_s: u32 = 10,
    status_poll_max_s: u32 = 180,
    body_cap_kb: u32 = 1024,
    user_agent: []const u8 = "youtube-shorts/0.1",
    allow_hosts: []const []const u8 = &.{ "*.googleapis.com", "accounts.google.com" },
};
pub const Breaker = struct { fails: u32 = 3, cool_h: u32 = 6 };
pub const Approval = struct { require_for_review: bool = true };
pub const Google = struct {
    auth_url: []const u8 = "https://accounts.google.com/o/oauth2/v2/auth",
    token_url: []const u8 = "https://oauth2.googleapis.com/token",
    api_base: []const u8 = "https://www.googleapis.com/youtube/v3",
    upload_base: []const u8 = "https://www.googleapis.com/upload/youtube/v3",
    scope: []const u8 = scope_upload ++ " " ++ scope_read,
    client_id_env: []const u8 = "YOUT_CLIENT_ID",
    client_secret_env: []const u8 = "YOUT_CLIENT_SECRET",
    client_id_file: []const u8 = "yout-client-id.txt",
    client_secret_file: []const u8 = "yout-client-secret.txt",
    refresh_token_file: []const u8 = "yout-refresh-token.txt",
    loopback_port: u32 = 0,
    login_wait_s: u32 = 300,
    watch_url: []const u8 = "https://www.youtube.com/watch?v=",
    region_code: []const u8 = "US",
};

pub const scope_upload = "https://www.googleapis.com/auth/youtube.upload";
// read-only: lets the app check its own uploads (processing, resolve); it cannot change anything
pub const scope_read = "https://www.googleapis.com/auth/youtube.readonly";

pub const Config = struct {
    data_dir: []const u8 = "",
    secrets_dir: []const u8 = "",
    tz_offset_hours: i32 = 7,
    db_file: []const u8 = "ledger.db",
    kill_file: []const u8 = "KILL",
    source: Source = .{},
    limits: Limits = .{},
    video: Video = .{},
    post: Post = .{},
    net: Net = .{},
    breaker: Breaker = .{},
    approval: Approval = .{},
    google: Google = .{},
    retry_pre_send: u32 = 2,
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

// range + safety checks on a parsed config
pub fn validate(c: Config, why: *[160]u8, why_len: *usize) LoadErr!void {
    if (c.limits.daily_cap == 0 or c.limits.daily_cap > c.limits.daily_cap_max) return bad(why, why_len, "config: limits.daily_cap must be 1..daily_cap_max ({d})", .{c.limits.daily_cap_max});
    if (c.limits.daily_cap_max == 0 or c.limits.daily_cap_max > 100000) return bad(why, why_len, "config: limits.daily_cap_max must be 1..100000", .{});
    if (c.limits.gap_min_s > c.limits.gap_max_s) return bad(why, why_len, "config: limits.gap_min_s must be <= gap_max_s", .{});
    if (c.limits.run_budget_s == 0 or c.limits.run_budget_s <= c.net.upload_timeout_s) return bad(why, why_len, "config: limits.run_budget_s must be longer than net.upload_timeout_s ({d}s)", .{c.net.upload_timeout_s});
    if (c.video.min_s == 0 or c.video.min_s > c.video.max_s or c.video.max_s > 180) return bad(why, why_len, "config: video.min_s <= video.max_s <= 180 (a Short is up to 3 minutes)", .{});
    if (c.video.min_w == 0 or c.video.min_h == 0 or c.video.max_mb == 0) return bad(why, why_len, "config: video.min_w, min_h, max_mb must be > 0", .{});
    if (!oneOf(c.post.visibility, &.{ "private", "unlisted", "public" })) return bad(why, why_len, "config: post.visibility must be private, unlisted or public", .{});
    if (std.mem.eql(u8, c.post.visibility, "public") and !c.post.public) return bad(why, why_len, "config: post.visibility public needs post.public true", .{});
    if (!c.post.ai_notice_required) return bad(why, why_len, "config: post.ai_notice_required is locked true (the AI label has no off switch)", .{});
    if (!c.approval.require_for_review) return bad(why, why_len, "config: approval.require_for_review is locked true (a person must look at review videos)", .{});
    if (c.post.category_id.len == 0 or c.post.category_id.len > 4) return bad(why, why_len, "config: post.category_id must be a short number string", .{});
    for (c.post.category_id) |ch| if (!std.ascii.isDigit(ch)) return bad(why, why_len, "config: post.category_id must be digits", .{});
    if (c.post.title_max == 0 or c.post.title_max > 100) return bad(why, why_len, "config: post.title_max must be 1..100 (YouTube limit)", .{});
    if (c.post.desc_max_bytes == 0 or c.post.desc_max_bytes > 5000) return bad(why, why_len, "config: post.desc_max_bytes must be 1..5000 (YouTube limit)", .{});
    if (c.post.tags_max_chars > 500) return bad(why, why_len, "config: post.tags_max_chars must be 0..500 (YouTube limit)", .{});
    if (c.post.hashtags_max > 60) return bad(why, why_len, "config: post.hashtags_max must be 0..60 (more than 60 and YouTube ignores all)", .{});
    if (c.net.timeout_s == 0 or c.net.upload_timeout_s == 0 or c.net.body_cap_kb == 0) return bad(why, why_len, "config: net timeouts and body_cap_kb must be > 0", .{});
    if (c.net.chunk_kb < 4 or c.net.chunk_kb > 65536) return bad(why, why_len, "config: net.chunk_kb must be 4..65536", .{});
    if (c.net.retries > 10) return bad(why, why_len, "config: net.retries must be 0..10", .{});
    if (c.net.status_poll_s == 0 or c.net.status_poll_s > c.net.status_poll_max_s) return bad(why, why_len, "config: net.status_poll_s must be 1..status_poll_max_s", .{});
    if (c.net.allow_hosts.len == 0) return bad(why, why_len, "config: net.allow_hosts must not be empty", .{});
    if (c.breaker.fails == 0 or c.breaker.cool_h == 0) return bad(why, why_len, "config: breaker.fails and cool_h must be > 0", .{});
    if (c.retry_pre_send > 5) return bad(why, why_len, "config: retry_pre_send must be 0..5", .{});
    if (c.token_warn_days == 0) return bad(why, why_len, "config: token_warn_days must be > 0", .{});
    var sb: [8]u8 = undefined;
    if (slot.parse(&sb, c.source.slot_hours) == null) return bad(why, why_len, "config: source.slot_hours must be ascending hours 0..23, like \"8,14,20\"", .{});
    if (c.tz_offset_hours < -12 or c.tz_offset_hours > 14) return bad(why, why_len, "config: tz_offset_hours must be -12..14", .{});
    if (c.db_file.len == 0 or c.kill_file.len == 0) return bad(why, why_len, "config: db_file and kill_file must not be empty", .{});
    var has_upload = false;
    var sc = std.mem.tokenizeScalar(u8, c.google.scope, ' ');
    while (sc.next()) |one| {
        if (std.mem.eql(u8, one, scope_upload)) has_upload = true else if (!std.mem.eql(u8, one, scope_read)) return bad(why, why_len, "config: google.scope may hold only youtube.upload and youtube.readonly (least privilege)", .{});
    }
    if (!has_upload) return bad(why, why_len, "config: google.scope must include {s}", .{scope_upload});
    if (c.google.login_wait_s == 0 or c.google.loopback_port > 65535) return bad(why, why_len, "config: google.login_wait_s must be > 0 and loopback_port 0..65535", .{});
    if (c.google.token_url.len == 0 or c.google.api_base.len == 0 or c.google.upload_base.len == 0 or c.google.auth_url.len == 0) return bad(why, why_len, "config: google urls must not be empty", .{});
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

test "safe defaults parse and are private" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var w: [160]u8 = undefined;
    var n: usize = 0;
    const c = try parse(arena.allocator(), "{}", &w, &n);
    try std.testing.expect(!c.post.public);
    try std.testing.expectEqualStrings("private", c.post.visibility);
    try std.testing.expect(c.post.ai_notice_required and c.approval.require_for_review);
    try std.testing.expect(!c.post.notify_subscribers);
}

test "locked safety switches and ranges are refused" {
    try expectBad("{\"post\":{\"ai_notice_required\":false}}", "ai_notice_required");
    try expectBad("{\"approval\":{\"require_for_review\":false}}", "require_for_review");
    try expectBad("{\"post\":{\"visibility\":\"public\"}}", "post.public");
    try expectBad("{\"post\":{\"visibility\":\"secret\"}}", "visibility");
    try expectBad("{\"post\":{\"title_max\":101}}", "title_max");
    try expectBad("{\"post\":{\"desc_max_bytes\":5001}}", "desc_max_bytes");
    try expectBad("{\"limits\":{\"daily_cap\":0}}", "daily_cap");
    try expectBad("{\"limits\":{\"daily_cap\":200}}", "daily_cap");
    try expectBad("{\"limits\":{\"gap_min_s\":9,\"gap_max_s\":3}}", "gap_min_s");
    try expectBad("{\"video\":{\"max_s\":181}}", "video.min_s");
    try expectBad("{\"google\":{\"scope\":\"https://www.googleapis.com/auth/youtube\"}}", "google.scope");
    try expectBad("{\"google\":{\"scope\":\"https://www.googleapis.com/auth/youtube.readonly\"}}", "must include");
    try expectBad("{\"google\":{\"scope\":\"https://www.googleapis.com/auth/youtube.upload https://www.googleapis.com/auth/youtube.force-ssl\"}}", "only youtube.upload");
    try expectBad("{\"net\":{\"allow_hosts\":[]}}", "allow_hosts");
    try expectBad("{\"net\":{\"chunk_kb\":1}}", "chunk_kb");
}

test "shipped 00-config.json parses and equals the defaults" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var w: [160]u8 = undefined;
    var n: usize = 0;
    const c = try load(arena.allocator(), std.testing.io, "00-config.json", &w, &n);
    const d: Config = .{};
    try std.testing.expectEqual(d.limits.daily_cap, c.limits.daily_cap);
    try std.testing.expectEqual(d.limits.gap_min_s, c.limits.gap_min_s);
    try std.testing.expectEqual(d.video.max_s, c.video.max_s);
    try std.testing.expectEqual(d.post.public, c.post.public);
    try std.testing.expectEqual(d.post.include_listing_url, c.post.include_listing_url);
    try std.testing.expectEqualStrings(d.post.visibility, c.post.visibility);
    try std.testing.expectEqualStrings(d.post.category_id, c.post.category_id);
    try std.testing.expectEqual(d.net.chunk_kb, c.net.chunk_kb);
    try std.testing.expectEqual(d.net.upload_timeout_s, c.net.upload_timeout_s);
    try std.testing.expectEqual(d.breaker.fails, c.breaker.fails);
    try std.testing.expectEqualStrings(d.google.token_url, c.google.token_url);
    try std.testing.expectEqualStrings(d.google.upload_base, c.google.upload_base);
    try std.testing.expectEqual(d.token_warn_days, c.token_warn_days);
    try std.testing.expectEqual(d.google.login_wait_s, c.google.login_wait_s);
    try std.testing.expectEqualStrings(d.google.watch_url, c.google.watch_url);
    try std.testing.expectEqualStrings("", c.source.dir);
}
// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
