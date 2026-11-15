// Config loader: strict (unknown key -> refuse with line/col). Every tunable lives in 00-config.json; defaults here must equal the shipped file (parity test).
const std = @import("std");

pub const Source = struct { dir: []const u8 = "", max_age_days: u32 = 14 };
pub const Limits = struct { tier: []const u8 = "standard", daily_cap: u32 = 3, daily_minutes: u32 = 120, gap_min_s: u32 = 600, gap_max_s: u32 = 1800, disk_min_mb: u32 = 500, run_budget_s: u32 = 1800, quota_block_h: u32 = 24 };
pub const Video = struct {
    min_s: u32 = 3,
    max_s: u32 = 60,
    min_w: u32 = 540,
    min_h: u32 = 960,
    rec_w: u32 = 1080,
    rec_h: u32 = 1920,
    fps_ok: []const u32 = &.{ 24, 25, 30, 50, 60 },
    max_mb: u32 = 512,
    vcodec: []const u8 = "avc1",
    acodec: []const u8 = "mp4a",
    probe_tool: []const u8 = "",
};
pub const Post = struct {
    public: bool = false,
    is_for_kids: bool = false,
    ai_notice_required: bool = true,
    enable_comments: bool = false,
    title_max: u32 = 255,
    desc_max: u32 = 3000,
    hashtags_max: u32 = 10,
    hashtags_in_desc: bool = true,
    send_tags: bool = false,
    html_breaks: bool = true,
    title_unique_days: u32 = 30,
    language: []const u8 = "",
    country: []const u8 = "",
    category: []const u8 = "auto",
    category_mode: []const u8 = "try",
    url_base: []const u8 = "https://www.dailymotion.com/video",
};
pub const Net = struct {
    timeout_s: u32 = 60,
    upload_timeout_s: u32 = 1800,
    chunk_kb: u32 = 256,
    backoff_ms: u32 = 2000,
    status_poll_s: u32 = 5,
    status_poll_max_s: u32 = 300,
    retries: u32 = 3,
    rate_wait_max_s: u32 = 60,
    body_cap_kb: u32 = 512,
    user_agent: []const u8 = "dmotion-shorts/0.1",
    upload_name: []const u8 = "short.mp4",
    allow_hosts: []const []const u8 = &.{ "oauth2.dailymotion.com", "api.dailymotion.com", "*.dailymotion.com" },
};
pub const Breaker = struct { fails: u32 = 3, cool_h: u32 = 6 };
pub const Account = struct { profile_id: []const u8 = "", profile_id_env: []const u8 = "DMOT_SHOR_PROFILE_ID" };
pub const Approval = struct { require_for_review: bool = true };
pub const Dmot = struct {
    token_url: []const u8 = "https://oauth2.dailymotion.com/v2/token",
    api_base: []const u8 = "https://api.dailymotion.com/v2",
    scope: []const u8 = "video.manage",
    client_id_env: []const u8 = "DMOT_SHOR_CLIENT_ID",
    client_id_file: []const u8 = "dmot-shor-client-id",
    client_secret_env: []const u8 = "DMOT_SHOR_CLIENT_SECRET",
    client_secret_file: []const u8 = "dmot-shor-client-secret",
};

pub const Config = struct {
    data_dir: []const u8 = "~/.dmotion-shorts",
    db_file: []const u8 = "ledger.db",
    secrets_dir: []const u8 = "~/.04-clou-secr",
    tz_offset_hours: i32 = 7,
    source: Source = .{},
    limits: Limits = .{},
    video: Video = .{},
    post: Post = .{},
    net: Net = .{},
    breaker: Breaker = .{},
    account: Account = .{},
    approval: Approval = .{},
    dmot: Dmot = .{},
    retry_pre_send: u32 = 2,
};

pub const LoadErr = error{ BadConfig, NoConfig, OutOfMemory };

// ---- tier table (data: df-dmot-tiers.json, embedded at build time) ----
const tier_text = @embedFile("df-dmot-tiers.json");
pub const Tier = struct { name: []const u8 = "", videos_24h: u32 = 0, minutes_24h: u32 = 0, max_mb: u32 = 0, max_s: u32 = 0 };
const TierFile = struct { version: u32 = 0, note: []const u8 = "", tiers: []const Tier = &.{} };

pub fn tierOf(a: std.mem.Allocator, name: []const u8) ?Tier {
    const f = std.json.parseFromSliceLeaky(TierFile, a, tier_text, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return null;
    for (f.tiers) |t| if (std.mem.eql(u8, t.name, name)) return t;
    return null;
}

// the 16 categories Dailymotion lists (VideoCategory enum, developers.dailymotion.com create-profile-video)
pub const categories = [_][]const u8{ "animals", "auto", "creation", "fun", "kids", "lifestyle", "music", "news", "people", "school", "sport", "tech", "travel", "tv", "videogames", "webcam" };

fn bad(why: *[160]u8, why_len: *usize, comptime fmt: []const u8, args: anytype) LoadErr {
    const s = std.fmt.bufPrint(why, fmt, args) catch "config: bad";
    why_len.* = s.len;
    return LoadErr.BadConfig;
}

fn twoLetters(s: []const u8) bool {
    if (s.len == 0) return true; // empty = not sent
    return s.len == 2 and std.ascii.isAlphabetic(s[0]) and std.ascii.isAlphabetic(s[1]);
}

fn oneOf(s: []const u8, list: []const []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, s, x)) return true;
    return false;
}

// Plain-language range checks. Returns the first problem.
pub fn validate(c: Config, why: *[160]u8, why_len: *usize) LoadErr!void {
    var buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const tier = tierOf(fba.allocator(), c.limits.tier) orelse return bad(why, why_len, "config: limits.tier must be standard, premium or edge", .{});
    if (c.limits.daily_cap < 1) return bad(why, why_len, "config: limits.daily_cap must be at least 1", .{});
    if (c.limits.daily_cap > tier.videos_24h) return bad(why, why_len, "config: limits.daily_cap {d} is above the {s} tier limit of {d} per 24 h (over it, uploads can be suspended)", .{ c.limits.daily_cap, tier.name, tier.videos_24h });
    if (c.limits.daily_minutes < 1) return bad(why, why_len, "config: limits.daily_minutes must be at least 1", .{});
    if (tier.minutes_24h > 0 and c.limits.daily_minutes > tier.minutes_24h) return bad(why, why_len, "config: limits.daily_minutes {d} is above the {s} tier limit of {d}", .{ c.limits.daily_minutes, tier.name, tier.minutes_24h });
    if (c.limits.gap_min_s > c.limits.gap_max_s) return bad(why, why_len, "config: limits.gap_min_s must be <= gap_max_s", .{});
    if (c.limits.run_budget_s == 0 or c.limits.quota_block_h == 0) return bad(why, why_len, "config: limits.run_budget_s and quota_block_h must be > 0", .{});
    if (c.video.min_s == 0 or c.video.min_s > c.video.max_s) return bad(why, why_len, "config: video.min_s must be 1..max_s", .{});
    if (tier.max_s > 0 and c.video.max_s > tier.max_s) return bad(why, why_len, "config: video.max_s is above the {s} tier limit of {d} s", .{ tier.name, tier.max_s });
    if (c.video.min_w == 0 or c.video.min_h == 0 or c.video.max_mb == 0) return bad(why, why_len, "config: video.min_w, min_h, max_mb must be > 0", .{});
    if (c.video.max_mb > tier.max_mb) return bad(why, why_len, "config: video.max_mb is above the {s} tier limit of {d} MB", .{ tier.name, tier.max_mb });
    if (c.video.fps_ok.len == 0) return bad(why, why_len, "config: video.fps_ok must list at least one frame rate", .{});
    if (c.post.desc_max < 100 or c.post.desc_max > 3000) return bad(why, why_len, "config: post.desc_max must be 100..3000 (Dailymotion allows 3000)", .{});
    if (c.post.title_max == 0 or c.post.title_max > 255) return bad(why, why_len, "config: post.title_max must be 1..255 (Dailymotion allows 255)", .{});
    if (!twoLetters(c.post.language) or !twoLetters(c.post.country)) return bad(why, why_len, "config: post.language and post.country must be empty or two letters", .{});
    if (!oneOf(c.post.category, &categories)) return bad(why, why_len, "config: post.category must be one of Dailymotion's 16 categories (for example auto)", .{});
    if (!oneOf(c.post.category_mode, &.{ "try", "with", "without" })) return bad(why, why_len, "config: post.category_mode must be try, with or without", .{});
    if (c.net.timeout_s == 0 or c.net.upload_timeout_s == 0 or c.net.chunk_kb == 0 or c.net.body_cap_kb == 0) return bad(why, why_len, "config: net timeouts, chunk_kb and body_cap_kb must be > 0", .{});
    if (c.net.status_poll_s == 0 or c.net.status_poll_max_s < c.net.status_poll_s) return bad(why, why_len, "config: net.status_poll_s must be > 0 and <= status_poll_max_s", .{});
    if (c.net.upload_name.len == 0 or std.mem.indexOfAny(u8, c.net.upload_name, "/\\\"\r\n") != null) return bad(why, why_len, "config: net.upload_name must be a plain file name", .{});
    if (c.net.allow_hosts.len == 0) return bad(why, why_len, "config: net.allow_hosts must not be empty", .{});
    if (c.breaker.fails == 0 or c.breaker.cool_h == 0) return bad(why, why_len, "config: breaker.fails and cool_h must be > 0", .{});
    if (!httpsOrLoop(c.dmot.token_url) or !httpsOrLoop(c.dmot.api_base)) return bad(why, why_len, "config: dmot.token_url and dmot.api_base must start with https://", .{});
    if (c.dmot.scope.len == 0) return bad(why, why_len, "config: dmot.scope must not be empty", .{});
    if (c.db_file.len == 0 or c.data_dir.len == 0) return bad(why, why_len, "config: data_dir and db_file must not be empty", .{});
}

fn httpsOrLoop(u: []const u8) bool {
    return std.mem.startsWith(u8, u, "https://") or std.mem.startsWith(u8, u, "http://127.0.0.1");
}

// Parse text strictly. On failure `why` gets a one-line reason with line/col.
pub fn parse(arena: std.mem.Allocator, text: []const u8, why: *[160]u8, why_len: *usize) LoadErr!Config {
    var diag = std.json.Diagnostics{};
    var sc = std.json.Scanner.initCompleteInput(arena, text);
    defer sc.deinit();
    sc.enableDiagnostics(&diag);
    const cfg = std.json.parseFromTokenSourceLeaky(Config, arena, &sc, .{ .ignore_unknown_fields = false }) catch |e| return bad(why, why_len, "config: {s} at line {d} col {d}", .{ @errorName(e), diag.getLine(), diag.getColumn() });
    try validate(cfg, why, why_len);
    return cfg;
}

pub fn load(arena: std.mem.Allocator, io: std.Io, path: []const u8, why: *[160]u8, why_len: *usize) LoadErr!Config {
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(256 * 1024)) catch {
        const s = std.fmt.bufPrint(why, "config: cannot read {s}", .{path}) catch "config: unreadable";
        why_len.* = s.len;
        return LoadErr.NoConfig;
    };
    return parse(arena, text, why, why_len);
}

test "unknown key refused with line, ranges checked, tier caps enforced" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var w: [160]u8 = undefined;
    var n: usize = 0;
    const c = try parse(arena.allocator(), "{\"limits\":{\"daily_cap\":5}}", &w, &n);
    try std.testing.expectEqual(@as(u32, 5), c.limits.daily_cap);
    try std.testing.expectError(LoadErr.BadConfig, parse(arena.allocator(), "{\"limitz\":{}}", &w, &n));
    try std.testing.expect(std.mem.indexOf(u8, w[0..n], "line 1") != null);
    // cap above the standard tier (15) is refused; premium allows it
    try std.testing.expectError(LoadErr.BadConfig, parse(arena.allocator(), "{\"limits\":{\"daily_cap\":16}}", &w, &n));
    try std.testing.expect(std.mem.indexOf(u8, w[0..n], "tier limit") != null);
    _ = try parse(arena.allocator(), "{\"limits\":{\"tier\":\"premium\",\"daily_cap\":40}}", &w, &n);
    try std.testing.expectError(LoadErr.BadConfig, parse(arena.allocator(), "{\"limits\":{\"tier\":\"gold\"}}", &w, &n));
    try std.testing.expectError(LoadErr.BadConfig, parse(arena.allocator(), "{\"limits\":{\"daily_cap\":0}}", &w, &n));
    try std.testing.expectError(LoadErr.BadConfig, parse(arena.allocator(), "{\"limits\":{\"daily_minutes\":601}}", &w, &n));
    try std.testing.expectError(LoadErr.BadConfig, parse(arena.allocator(), "{\"limits\":{\"gap_min_s\":9,\"gap_max_s\":3}}", &w, &n));
    try std.testing.expectError(LoadErr.BadConfig, parse(arena.allocator(), "{\"video\":{\"min_s\":100}}", &w, &n));
    try std.testing.expect(std.mem.indexOf(u8, w[0..n], "min_s") != null);
    try std.testing.expectError(LoadErr.BadConfig, parse(arena.allocator(), "{\"post\":{\"category\":\"cars\"}}", &w, &n));
    try std.testing.expectError(LoadErr.BadConfig, parse(arena.allocator(), "{\"post\":{\"category_mode\":\"maybe\"}}", &w, &n));
    try std.testing.expectError(LoadErr.BadConfig, parse(arena.allocator(), "{\"post\":{\"language\":\"eng\"}}", &w, &n));
    try std.testing.expectError(LoadErr.BadConfig, parse(arena.allocator(), "{\"post\":{\"title_max\":300}}", &w, &n));
    try std.testing.expectError(LoadErr.BadConfig, parse(arena.allocator(), "{\"dmot\":{\"api_base\":\"http://example.com\"}}", &w, &n));
    try std.testing.expectError(LoadErr.BadConfig, parse(arena.allocator(), "{\"net\":{\"upload_name\":\"a/b.mp4\"}}", &w, &n));
}

// shipped file == built-in defaults: a typo in either shows up here
test "shipped 00-config.json equals the defaults" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var w: [160]u8 = undefined;
    var n: usize = 0;
    const shipped = try load(a, std.testing.io, "00-config.json", &w, &n);
    const s1 = try std.json.Stringify.valueAlloc(a, shipped, .{});
    const s2 = try std.json.Stringify.valueAlloc(a, Config{}, .{});
    try std.testing.expectEqualStrings(s2, s1);
}

test "tier table reads" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqual(@as(u32, 15), tierOf(arena.allocator(), "standard").?.videos_24h);
    try std.testing.expectEqual(@as(u32, 96), tierOf(arena.allocator(), "edge").?.videos_24h);
    try std.testing.expect(tierOf(arena.allocator(), "x") == null);
}
