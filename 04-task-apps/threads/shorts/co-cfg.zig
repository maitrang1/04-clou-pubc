// Config loader: strict (unknown key -> refuse with line/col). Every tunable lives in 00-config.json; defaults here must equal the shipped file (parity test).
const std = @import("std");

pub const Device = struct { publisher: bool = false };
pub const Source = struct { dir: []const u8 = "", max_age_days: u32 = 14 };
pub const Host = struct { dir: []const u8 = "", done_dir: []const u8 = "", base_url: []const u8 = "", selfcheck: bool = true };
pub const Limits = struct { daily_cap: u32 = 3, quota_margin: u32 = 10, gap_min_s: u32 = 600, gap_max_s: u32 = 1800, disk_min_mb: u32 = 500, run_budget_s: u32 = 1800, quota_block_h: u32 = 6, unsure_wait_min: u32 = 60 };
pub const Video = struct {
    min_s: u32 = 1,
    max_s: u32 = 90,
    max_w: u32 = 1920,
    fps_min: u32 = 23,
    fps_max: u32 = 60,
    max_mb: u32 = 1024,
    max_mbps: u32 = 100,
    vcodecs: []const []const u8 = &.{ "avc1", "hvc1" },
    acodec: []const u8 = "mp4a",
    audio_channels_max: u32 = 2,
    audio_rate_max: u32 = 48000,
    probe_tool: []const u8 = "",
};
pub const Post = struct {
    public: bool = false,
    ai_notice_required: bool = true,
    text_max: u32 = 500,
    text_unit: []const u8 = "weighted",
    text_margin: u32 = 10,
    url_in_text: bool = true,
    reply_control: []const u8 = "everyone",
};
pub const Net = struct {
    timeout_s: u32 = 60,
    copy_chunk_kb: u32 = 256,
    backoff_ms: u32 = 2000,
    settle_s: u32 = 30,
    status_poll_s: u32 = 60,
    status_poll_max_s: u32 = 300,
    body_cap_kb: u32 = 512,
    user_agent: []const u8 = "threads-shorts/0.1",
    allow_hosts: []const []const u8 = &.{ "graph.threads.com", "graph.threads.net" },
    auth_style: []const u8 = "form",
};
pub const Breaker = struct { fails: u32 = 3, cool_h: u32 = 6 };
pub const Safety = struct { dup_probe: bool = true, dup_chars: u32 = 80 };
pub const Account = struct {
    token_env: []const u8 = "THRE_SHOR_TOKEN",
    token_file: []const u8 = "thre-shor-token",
    token_meta_file: []const u8 = "thre-shor-token-meta",
    user_id_env: []const u8 = "THRE_SHOR_USER_ID",
    user_id_file: []const u8 = "thre-shor-user-id",
    app_id_env: []const u8 = "THRE_SHOR_APP_ID",
    app_id_file: []const u8 = "thre-shor-app-id",
    app_secret_env: []const u8 = "THRE_SHOR_APP_SECRET",
    app_secret_file: []const u8 = "thre-shor-app-secret",
};
pub const Approval = struct { require_for_review: bool = true };
pub const Graph = struct {
    base: []const u8 = "https://graph.threads.com",
    version: []const u8 = "v1.0",
    need_scopes: []const []const u8 = &.{ "threads_basic", "threads_content_publish" },
};

pub const Config = struct {
    data_dir: []const u8 = "~/.threads-shorts",
    db_file: []const u8 = "ledger.db",
    secrets_dir: []const u8 = "~/.04-clou-secr",
    tz_offset_hours: i32 = 7,
    device: Device = .{},
    source: Source = .{},
    host: Host = .{},
    limits: Limits = .{},
    video: Video = .{},
    post: Post = .{},
    net: Net = .{},
    breaker: Breaker = .{},
    safety: Safety = .{},
    account: Account = .{},
    approval: Approval = .{},
    graph: Graph = .{},
    retry_pre_send: u32 = 2,
    token_warn_days: u32 = 14,
    token_refresh_days: u32 = 30,
};

pub const LoadErr = error{ BadConfig, NoConfig, OutOfMemory };

fn bad(why: *[160]u8, why_len: *usize, comptime fmt: []const u8, args: anytype) LoadErr {
    const s = std.fmt.bufPrint(why, fmt, args) catch "config: bad";
    why_len.* = s.len;
    return LoadErr.BadConfig;
}

// graph.version must look like v1.0
fn versionOk(v: []const u8) bool {
    if (v.len < 4 or v[0] != 'v') return false;
    const dot = std.mem.indexOfScalar(u8, v, '.') orelse return false;
    _ = std.fmt.parseInt(u16, v[1..dot], 10) catch return false;
    _ = std.fmt.parseInt(u16, v[dot + 1 ..], 10) catch return false;
    return true;
}

fn oneOf(v: []const u8, comptime opts: []const []const u8) bool {
    inline for (opts) |o| if (std.mem.eql(u8, v, o)) return true;
    return false;
}

// Plain-language range checks. Returns the first problem.
pub fn validate(c: Config, why: *[160]u8, why_len: *usize) LoadErr!void {
    if (c.limits.daily_cap < 1 or c.limits.daily_cap > 50) return bad(why, why_len, "config: limits.daily_cap must be 1..50 (Threads allows 250, this app posts shorts, not floods)", .{});
    if (c.limits.gap_min_s > c.limits.gap_max_s) return bad(why, why_len, "config: limits.gap_min_s must be <= gap_max_s", .{});
    if (c.limits.run_budget_s == 0 or c.limits.quota_block_h == 0) return bad(why, why_len, "config: limits.run_budget_s and quota_block_h must be > 0", .{});
    if (c.video.min_s == 0 or c.video.min_s > c.video.max_s) return bad(why, why_len, "config: video.min_s must be 1..max_s", .{});
    if (c.video.max_s > 300) return bad(why, why_len, "config: video.max_s must be <= 300 (Threads allows 5 minutes)", .{});
    if (c.video.fps_min == 0 or c.video.fps_min > c.video.fps_max) return bad(why, why_len, "config: video.fps_min must be 1..fps_max", .{});
    if (c.video.max_w == 0 or c.video.max_mb == 0 or c.video.max_mb > 1024 or c.video.max_mbps == 0) return bad(why, why_len, "config: video.max_w, max_mbps must be > 0 and max_mb 1..1024 (Threads allows 1 GB)", .{});
    if (c.video.vcodecs.len == 0) return bad(why, why_len, "config: video.vcodecs must not be empty", .{});
    if (c.post.text_max < 100 or c.post.text_max > 500) return bad(why, why_len, "config: post.text_max must be 100..500 (Threads allows 500)", .{});
    if (c.post.text_margin >= c.post.text_max) return bad(why, why_len, "config: post.text_margin must be < text_max", .{});
    if (!oneOf(c.post.text_unit, &.{ "weighted", "chars", "bytes" })) return bad(why, why_len, "config: post.text_unit must be weighted, chars or bytes", .{});
    if (!oneOf(c.post.reply_control, &.{ "everyone", "accounts_you_follow", "mentioned_only", "parent_post_author_only", "followers_only" })) return bad(why, why_len, "config: post.reply_control is not a value Threads knows", .{});
    if (c.net.timeout_s == 0 or c.net.copy_chunk_kb == 0 or c.net.body_cap_kb == 0) return bad(why, why_len, "config: net timeouts, copy_chunk_kb and body_cap_kb must be > 0", .{});
    if (c.net.status_poll_s == 0 or c.net.status_poll_max_s < c.net.status_poll_s) return bad(why, why_len, "config: net.status_poll_s must be > 0 and <= status_poll_max_s", .{});
    if (c.net.allow_hosts.len == 0) return bad(why, why_len, "config: net.allow_hosts must not be empty", .{});
    if (!oneOf(c.net.auth_style, &.{ "form", "bearer" })) return bad(why, why_len, "config: net.auth_style must be form or bearer", .{});
    if (c.breaker.fails == 0 or c.breaker.cool_h == 0) return bad(why, why_len, "config: breaker.fails and cool_h must be > 0", .{});
    if (c.safety.dup_chars < 10) return bad(why, why_len, "config: safety.dup_chars must be >= 10", .{});
    if (!std.mem.startsWith(u8, c.graph.base, "https://") and !std.mem.startsWith(u8, c.graph.base, "http://127.0.0.1")) return bad(why, why_len, "config: graph.base must start with https://", .{});
    if (!versionOk(c.graph.version)) return bad(why, why_len, "config: graph.version must look like v1.0", .{});
    if (c.host.base_url.len > 0 and !std.mem.startsWith(u8, c.host.base_url, "https://") and !std.mem.startsWith(u8, c.host.base_url, "http://127.0.0.1")) return bad(why, why_len, "config: host.base_url must start with https:// (Threads downloads the video from it)", .{});
    if (c.db_file.len == 0 or c.data_dir.len == 0) return bad(why, why_len, "config: data_dir and db_file must not be empty", .{});
    if (c.token_refresh_days == 0 or c.token_refresh_days > 59) return bad(why, why_len, "config: token_refresh_days must be 1..59 (a token lives 60 days)", .{});
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
    try std.testing.expectError(LoadErr.BadConfig, parse(arena.allocator(), "{\"limits\":{\"daily_cap\":51}}", &w, &n));
    try std.testing.expectError(LoadErr.BadConfig, parse(arena.allocator(), "{\"limits\":{\"daily_cap\":0}}", &w, &n));
    try std.testing.expectError(LoadErr.BadConfig, parse(arena.allocator(), "{\"limits\":{\"gap_min_s\":9,\"gap_max_s\":3}}", &w, &n));
    try std.testing.expectError(LoadErr.BadConfig, parse(arena.allocator(), "{\"graph\":{\"version\":\"1\"}}", &w, &n));
    try std.testing.expectError(LoadErr.BadConfig, parse(arena.allocator(), "{\"video\":{\"min_s\":100}}", &w, &n));
    try std.testing.expect(std.mem.indexOf(u8, w[0..n], "min_s") != null);
    try std.testing.expectError(LoadErr.BadConfig, parse(arena.allocator(), "{\"video\":{\"max_s\":301}}", &w, &n));
    try std.testing.expectError(LoadErr.BadConfig, parse(arena.allocator(), "{\"post\":{\"text_max\":501}}", &w, &n));
    try std.testing.expectError(LoadErr.BadConfig, parse(arena.allocator(), "{\"post\":{\"text_unit\":\"runes\"}}", &w, &n));
    try std.testing.expectError(LoadErr.BadConfig, parse(arena.allocator(), "{\"net\":{\"auth_style\":\"cookie\"}}", &w, &n));
}

test "host.base_url must be https (loopback http only for mocks)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var w: [160]u8 = undefined;
    var n: usize = 0;
    try std.testing.expectError(LoadErr.BadConfig, parse(arena.allocator(), "{\"host\":{\"base_url\":\"http://files.example.com/v\"}}", &w, &n));
    try std.testing.expect(std.mem.indexOf(u8, w[0..n], "https://") != null);
    _ = try parse(arena.allocator(), "{\"host\":{\"base_url\":\"https://files.example.com/v\"}}", &w, &n);
    _ = try parse(arena.allocator(), "{\"host\":{\"base_url\":\"\"}}", &w, &n); // unset is valid until doctor/publish need it
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
