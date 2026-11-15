// Config loader: strict (unknown key -> refuse with line/col). Every tunable lives in 00-config.json; defaults here must equal the shipped file (parity test).
const std = @import("std");

pub const Source = struct { dir: []const u8 = "", max_age_days: u32 = 14 };
pub const Limits = struct { daily_cap: u32 = 3, meta_cap: u32 = 25, container_cap: u32 = 40, gap_min_s: u32 = 600, gap_max_s: u32 = 1800, disk_min_mb: u32 = 500, run_budget_s: u32 = 1800, usage_stop_pct: u32 = 80, quota_block_h: u32 = 24 };
pub const Video = struct {
    min_s: u32 = 3,
    max_s: u32 = 90,
    min_w: u32 = 540,
    min_h: u32 = 960,
    rec_w: u32 = 1080,
    rec_h: u32 = 1920,
    max_w: u32 = 1920,
    aspect_w: u32 = 9,
    aspect_h: u32 = 16,
    aspect_tol_pct: u32 = 2,
    fps_min: u32 = 23,
    fps_max: u32 = 60,
    max_mb: u32 = 300,
    vcodec: []const u8 = "avc1",
    acodec: []const u8 = "mp4a",
    audio_channels_max: u32 = 2,
    audio_rate_max: u32 = 48000,
    probe_tool: []const u8 = "",
};
pub const Post = struct { public: bool = false, ai_notice_required: bool = true, caption_max: u32 = 2200, tags_max: u32 = 10, share_to_feed: bool = true, thumb_offset_ms: u32 = 0 };
pub const Net = struct {
    timeout_s: u32 = 60,
    upload_timeout_s: u32 = 1800,
    chunk_kb: u32 = 256,
    backoff_ms: u32 = 2000,
    status_poll_s: u32 = 60,
    status_poll_max_s: u32 = 300,
    resume_max: u32 = 2,
    notready_wait_s: u32 = 30,
    body_cap_kb: u32 = 512,
    user_agent: []const u8 = "instagram-shorts/0.1",
    allow_hosts: []const []const u8 = &.{ "graph.facebook.com", "rupload.facebook.com" },
};
pub const Breaker = struct { fails: u32 = 3, cool_h: u32 = 6 };
pub const Account = struct { ig_user_id_env: []const u8 = "INST_SHOR_USER_ID", ig_user_id_file: []const u8 = "inst-shor-user-id" };
pub const Approval = struct { require_for_review: bool = true };
pub const Graph = struct {
    base: []const u8 = "https://graph.facebook.com",
    version: []const u8 = "v27.0",
    login: []const u8 = "facebook",
    token_env: []const u8 = "INST_SHOR_TOKEN",
    token_file: []const u8 = "inst-shor-token",
};

pub const Config = struct {
    data_dir: []const u8 = "~/.instagram-shorts",
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
    graph: Graph = .{},
    retry_pre_send: u32 = 2,
    retry_publish: u32 = 2,
};

pub const LoadErr = error{ BadConfig, NoConfig, OutOfMemory };

fn bad(why: *[160]u8, why_len: *usize, comptime fmt: []const u8, args: anytype) LoadErr {
    const s = std.fmt.bufPrint(why, fmt, args) catch "config: bad";
    why_len.* = s.len;
    return LoadErr.BadConfig;
}

// graph.version must look like v27.0
fn versionOk(v: []const u8) bool {
    if (v.len < 4 or v[0] != 'v') return false;
    const dot = std.mem.indexOfScalar(u8, v, '.') orelse return false;
    _ = std.fmt.parseInt(u16, v[1..dot], 10) catch return false;
    _ = std.fmt.parseInt(u16, v[dot + 1 ..], 10) catch return false;
    return true;
}

// Plain-language range checks. Returns the first problem.
pub fn validate(c: Config, why: *[160]u8, why_len: *usize) LoadErr!void {
    if (c.limits.daily_cap < 1 or c.limits.daily_cap > c.limits.meta_cap) return bad(why, why_len, "config: limits.daily_cap must be 1..meta_cap", .{});
    if (c.limits.meta_cap < 1 or c.limits.meta_cap > 50) return bad(why, why_len, "config: limits.meta_cap must be 1..50 (Meta says 50 or 100; we stay at or under the lower)", .{});
    if (c.limits.container_cap < 1 or c.limits.container_cap > 400) return bad(why, why_len, "config: limits.container_cap must be 1..400 (Meta: 400 containers per 24 h)", .{});
    if (c.limits.gap_min_s > c.limits.gap_max_s) return bad(why, why_len, "config: limits.gap_min_s must be <= gap_max_s", .{});
    if (c.limits.usage_stop_pct < 1 or c.limits.usage_stop_pct > 100) return bad(why, why_len, "config: limits.usage_stop_pct must be 1..100", .{});
    if (c.limits.run_budget_s == 0 or c.limits.quota_block_h == 0) return bad(why, why_len, "config: limits.run_budget_s and quota_block_h must be > 0", .{});
    if (c.video.min_s == 0 or c.video.min_s > c.video.max_s) return bad(why, why_len, "config: video.min_s must be 1..max_s", .{});
    if (c.video.max_s > 900) return bad(why, why_len, "config: video.max_s must be <= 900 (Meta: 15 min)", .{});
    if (c.video.fps_min == 0 or c.video.fps_min > c.video.fps_max) return bad(why, why_len, "config: video.fps_min must be 1..fps_max", .{});
    if (c.video.min_w == 0 or c.video.min_h == 0 or c.video.max_mb == 0) return bad(why, why_len, "config: video.min_w, min_h, max_mb must be > 0", .{});
    if (c.video.max_mb > 300) return bad(why, why_len, "config: video.max_mb must be <= 300 (Meta's Reels file limit)", .{});
    if (c.video.max_w == 0 or c.video.max_w > 1920 or c.video.min_w > c.video.max_w) return bad(why, why_len, "config: video.max_w must be min_w..1920", .{});
    if (c.video.aspect_w == 0 or c.video.aspect_h == 0 or c.video.aspect_tol_pct > 50) return bad(why, why_len, "config: video.aspect_w, aspect_h must be > 0 and aspect_tol_pct <= 50", .{});
    if (c.video.audio_channels_max == 0 or c.video.audio_rate_max == 0) return bad(why, why_len, "config: video.audio_channels_max and audio_rate_max must be > 0", .{});
    if (c.post.caption_max < 100 or c.post.caption_max > 2200) return bad(why, why_len, "config: post.caption_max must be 100..2200 (Meta: 2200 characters)", .{});
    if (c.post.tags_max > 30) return bad(why, why_len, "config: post.tags_max must be <= 30 (Meta: 30 hashtags)", .{});
    if (c.net.timeout_s == 0 or c.net.upload_timeout_s == 0 or c.net.chunk_kb == 0 or c.net.body_cap_kb == 0) return bad(why, why_len, "config: net timeouts, chunk_kb and body_cap_kb must be > 0", .{});
    if (c.net.status_poll_s == 0 or c.net.status_poll_max_s < c.net.status_poll_s) return bad(why, why_len, "config: net.status_poll_s must be > 0 and <= status_poll_max_s", .{});
    if (c.net.allow_hosts.len == 0) return bad(why, why_len, "config: net.allow_hosts must not be empty", .{});
    if (c.breaker.fails == 0 or c.breaker.cool_h == 0) return bad(why, why_len, "config: breaker.fails and cool_h must be > 0", .{});
    if (!std.mem.startsWith(u8, c.graph.base, "https://") and !std.mem.startsWith(u8, c.graph.base, "http://127.0.0.1")) return bad(why, why_len, "config: graph.base must start with https://", .{});
    if (!versionOk(c.graph.version)) return bad(why, why_len, "config: graph.version must look like v27.0", .{});
    if (!std.mem.eql(u8, c.graph.login, "facebook")) return bad(why, why_len, "config: graph.login must be \"facebook\" (resumable upload is documented only for Facebook Login)", .{});
    if (c.db_file.len == 0 or c.data_dir.len == 0) return bad(why, why_len, "config: data_dir and db_file must not be empty", .{});
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

test "unknown key refused with line, ranges checked" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var w: [160]u8 = undefined;
    var n: usize = 0;
    const c = try parse(arena.allocator(), "{\"limits\":{\"daily_cap\":5}}", &w, &n);
    try std.testing.expectEqual(@as(u32, 5), c.limits.daily_cap);
    try std.testing.expectError(LoadErr.BadConfig, parse(arena.allocator(), "{\"limitz\":{}}", &w, &n));
    try std.testing.expect(std.mem.indexOf(u8, w[0..n], "line 1") != null);
    try std.testing.expectError(LoadErr.BadConfig, parse(arena.allocator(), "{\"limits\":{\"daily_cap\":26}}", &w, &n));
    try std.testing.expectError(LoadErr.BadConfig, parse(arena.allocator(), "{\"limits\":{\"daily_cap\":0}}", &w, &n));
    try std.testing.expectError(LoadErr.BadConfig, parse(arena.allocator(), "{\"limits\":{\"gap_min_s\":9,\"gap_max_s\":3}}", &w, &n));
    try std.testing.expectError(LoadErr.BadConfig, parse(arena.allocator(), "{\"graph\":{\"version\":\"27\"}}", &w, &n));
    try std.testing.expectError(LoadErr.BadConfig, parse(arena.allocator(), "{\"video\":{\"min_s\":100}}", &w, &n));
    try std.testing.expect(std.mem.indexOf(u8, w[0..n], "min_s") != null);
    try std.testing.expectError(LoadErr.BadConfig, parse(arena.allocator(), "{\"graph\":{\"login\":\"instagram\"}}", &w, &n));
    try std.testing.expect(std.mem.indexOf(u8, w[0..n], "facebook") != null);
    try std.testing.expectError(LoadErr.BadConfig, parse(arena.allocator(), "{\"post\":{\"caption_max\":3000}}", &w, &n));
    try std.testing.expectError(LoadErr.BadConfig, parse(arena.allocator(), "{\"video\":{\"max_mb\":400}}", &w, &n));
    try std.testing.expectError(LoadErr.BadConfig, parse(arena.allocator(), "{\"limits\":{\"meta_cap\":60}}", &w, &n));
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
