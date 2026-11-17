// =====================================================================
// Des: Reads 00-config.json strictly - an unknown or wrong setting stops the app with the line and column, and every number is range-checked
// Flo: read file > strict JSON parse into typed structs > range checks > Config (arena-owned) or a one-line reason
// Cre: 2026-11-16                          - | Mod: 2026-11-16
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: path of 00-config.json (or its text), arena allocator
// Out: Config | LoadErr with `why` filled for the user
// Run: not run directly - imported by main and the context
// =====================================================================
const std = @import("std");

pub const Source = struct { dir: []const u8 = "", max_age_days: u32 = 14 };
pub const Device = struct { publisher: bool = false };
pub const Limits = struct { daily_cap: u32 = 3, daily_cap_max: u32 = 20, gap_min_s: u32 = 600, gap_max_s: u32 = 1800, disk_min_mb: u32 = 500, run_budget_s: u32 = 1200 };
pub const Video = struct { min_s: u32 = 1, max_s: u32 = 180, min_w: u32 = 540, min_h: u32 = 960, max_mb: u32 = 50, want_faststart: bool = true };
pub const Post = struct {
    public: bool = false,
    ai_notice_required: bool = true,
    silent: bool = true,
    protect: bool = false,
    caption_above: bool = false,
    caption_max: u32 = 1024,
    hashtags_max: u32 = 15,
};
pub const Net = struct {
    timeout_s: u32 = 60,
    upload_timeout_s: u32 = 600,
    chunk_kb: u32 = 256,
    backoff_ms: u32 = 2000,
    retries: u32 = 3,
    body_cap_kb: u32 = 1024,
    user_agent: []const u8 = "telegram-shorts/0.1",
    allow_hosts: []const []const u8 = &.{"api.telegram.org"},
};
pub const Breaker = struct { fails: u32 = 3, cool_h: u32 = 6 };
pub const Approval = struct { require_for_review: bool = true };
pub const Telegram = struct {
    api_base: []const u8 = "https://api.telegram.org",
    token_env: []const u8 = "TELE_BOT_TOKEN",
    token_file: []const u8 = "tele-bot-token.txt",
    chat_file: []const u8 = "tele-chat.txt",
    test_chat_file: []const u8 = "tele-chat-test.txt",
    link_base: []const u8 = "https://t.me",
    thread_id: u32 = 0,
    feed_limit: u32 = 100,
};

pub const max_video_mb: u32 = 50; // the documented bot upload limit on the cloud Bot API

pub const Config = struct {
    data_dir: []const u8 = "",
    secrets_dir: []const u8 = "",
    tz_offset_hours: i32 = 7,
    db_file: []const u8 = "ledger.db",
    kill_file: []const u8 = "KILL",
    source: Source = .{},
    device: Device = .{},
    limits: Limits = .{},
    video: Video = .{},
    post: Post = .{},
    net: Net = .{},
    breaker: Breaker = .{},
    approval: Approval = .{},
    telegram: Telegram = .{},
    retry_pre_send: u32 = 2,
};

pub const LoadErr = error{ BadConfig, NoConfig, OutOfMemory };

fn bad(why: *[160]u8, why_len: *usize, comptime fmt: []const u8, args: anytype) LoadErr {
    const s = std.fmt.bufPrint(why, fmt, args) catch "config: bad";
    why_len.* = s.len;
    return LoadErr.BadConfig;
}

// range + safety checks on a parsed config
pub fn validate(c: Config, why: *[160]u8, why_len: *usize) LoadErr!void {
    if (c.limits.daily_cap == 0 or c.limits.daily_cap > c.limits.daily_cap_max) return bad(why, why_len, "config: limits.daily_cap must be 1..daily_cap_max ({d})", .{c.limits.daily_cap_max});
    if (c.limits.daily_cap_max == 0 or c.limits.daily_cap_max > 1000) return bad(why, why_len, "config: limits.daily_cap_max must be 1..1000", .{});
    if (c.limits.gap_min_s < 1 or c.limits.gap_min_s > c.limits.gap_max_s) return bad(why, why_len, "config: limits.gap_min_s must be >= 1 (one message per second per chat) and <= gap_max_s", .{});
    if (c.limits.run_budget_s == 0 or c.limits.run_budget_s <= c.net.upload_timeout_s) return bad(why, why_len, "config: limits.run_budget_s must be longer than net.upload_timeout_s ({d}s)", .{c.net.upload_timeout_s});
    if (c.video.min_s == 0 or c.video.min_s > c.video.max_s) return bad(why, why_len, "config: video.min_s must be 1..video.max_s", .{});
    if (c.video.min_w == 0 or c.video.min_h == 0) return bad(why, why_len, "config: video.min_w and min_h must be > 0", .{});
    if (c.video.max_mb == 0 or c.video.max_mb > max_video_mb) return bad(why, why_len, "config: video.max_mb must be 1..{d} (the bot upload limit)", .{max_video_mb});
    if (!c.post.ai_notice_required) return bad(why, why_len, "config: post.ai_notice_required is locked true (the AI label has no off switch)", .{});
    if (!c.approval.require_for_review) return bad(why, why_len, "config: approval.require_for_review is locked true (a person must look at review videos)", .{});
    if (c.post.caption_max == 0 or c.post.caption_max > 1024) return bad(why, why_len, "config: post.caption_max must be 1..1024 (Telegram video caption limit)", .{});
    if (c.post.hashtags_max > 60) return bad(why, why_len, "config: post.hashtags_max must be 0..60", .{});
    if (c.post.public and !c.device.publisher) return bad(why, why_len, "config: post.public true needs device.publisher true (one publishing device only)", .{});
    if (c.net.timeout_s == 0 or c.net.upload_timeout_s == 0 or c.net.body_cap_kb == 0) return bad(why, why_len, "config: net timeouts and body_cap_kb must be > 0", .{});
    if (c.net.chunk_kb < 4 or c.net.chunk_kb > 65536) return bad(why, why_len, "config: net.chunk_kb must be 4..65536", .{});
    if (c.net.retries > 10) return bad(why, why_len, "config: net.retries must be 0..10", .{});
    if (c.net.allow_hosts.len == 0) return bad(why, why_len, "config: net.allow_hosts must not be empty", .{});
    if (c.breaker.fails == 0 or c.breaker.cool_h == 0) return bad(why, why_len, "config: breaker.fails and cool_h must be > 0", .{});
    if (c.retry_pre_send > 5) return bad(why, why_len, "config: retry_pre_send must be 0..5", .{});
    if (c.tz_offset_hours < -12 or c.tz_offset_hours > 14) return bad(why, why_len, "config: tz_offset_hours must be -12..14", .{});
    if (c.db_file.len == 0 or c.kill_file.len == 0) return bad(why, why_len, "config: db_file and kill_file must not be empty", .{});
    const t = c.telegram;
    if (t.api_base.len == 0 or t.token_file.len == 0 or t.chat_file.len == 0 or t.test_chat_file.len == 0) return bad(why, why_len, "config: telegram.api_base and the secret file names must not be empty", .{});
    if (std.mem.eql(u8, t.chat_file, t.test_chat_file)) return bad(why, why_len, "config: telegram.chat_file and test_chat_file must be different files", .{});
    if (std.mem.indexOfAny(u8, t.api_base, "?#@ ") != null or std.mem.endsWith(u8, t.api_base, "/")) return bad(why, why_len, "config: telegram.api_base must be a plain https address without a trailing slash", .{});
    if (t.feed_limit == 0 or t.feed_limit > 100) return bad(why, why_len, "config: telegram.feed_limit must be 1..100", .{});
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

test "safe defaults parse: test chat mode, silent, not a publisher" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var w: [160]u8 = undefined;
    var n: usize = 0;
    const c = try parse(arena.allocator(), "{}", &w, &n);
    try std.testing.expect(!c.post.public and !c.device.publisher);
    try std.testing.expect(c.post.ai_notice_required and c.approval.require_for_review);
    try std.testing.expect(c.post.silent and !c.post.protect);
    try std.testing.expectEqual(@as(u32, 1024), c.post.caption_max);
    try std.testing.expectEqual(@as(u32, 50), c.video.max_mb);
}

test "locked safety switches and ranges are refused" {
    try expectBad("{\"post\":{\"ai_notice_required\":false}}", "ai_notice_required");
    try expectBad("{\"approval\":{\"require_for_review\":false}}", "require_for_review");
    try expectBad("{\"post\":{\"public\":true}}", "device.publisher");
    try expectBad("{\"post\":{\"caption_max\":1025}}", "caption_max");
    try expectBad("{\"video\":{\"max_mb\":51}}", "video.max_mb");
    try expectBad("{\"limits\":{\"daily_cap\":0}}", "daily_cap");
    try expectBad("{\"limits\":{\"daily_cap\":200}}", "daily_cap");
    try expectBad("{\"limits\":{\"gap_min_s\":0}}", "gap_min_s");
    try expectBad("{\"limits\":{\"gap_min_s\":9,\"gap_max_s\":3}}", "gap_min_s");
    try expectBad("{\"net\":{\"allow_hosts\":[]}}", "allow_hosts");
    try expectBad("{\"net\":{\"chunk_kb\":1}}", "chunk_kb");
    try expectBad("{\"telegram\":{\"chat_file\":\"x\",\"test_chat_file\":\"x\"}}", "different files");
    try expectBad("{\"telegram\":{\"api_base\":\"https://x.example/\"}}", "api_base");
}

test "public needs the publisher device, both set is valid" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var w: [160]u8 = undefined;
    var n: usize = 0;
    const c = try parse(arena.allocator(), "{\"post\":{\"public\":true},\"device\":{\"publisher\":true}}", &w, &n);
    try std.testing.expect(c.post.public and c.device.publisher);
}

test "shipped 00-config.json parses and equals the defaults" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var w: [160]u8 = undefined;
    var n: usize = 0;
    const c = try load(arena.allocator(), std.testing.io, "00-config.json", &w, &n);
    const d: Config = .{};
    try std.testing.expectEqual(d.limits.daily_cap, c.limits.daily_cap);
    try std.testing.expectEqual(d.limits.daily_cap_max, c.limits.daily_cap_max);
    try std.testing.expectEqual(d.limits.gap_min_s, c.limits.gap_min_s);
    try std.testing.expectEqual(d.limits.gap_max_s, c.limits.gap_max_s);
    try std.testing.expectEqual(d.limits.run_budget_s, c.limits.run_budget_s);
    try std.testing.expectEqual(d.video.max_s, c.video.max_s);
    try std.testing.expectEqual(d.video.max_mb, c.video.max_mb);
    try std.testing.expectEqual(d.post.public, c.post.public);
    try std.testing.expectEqual(d.post.silent, c.post.silent);
    try std.testing.expectEqual(d.post.caption_max, c.post.caption_max);
    try std.testing.expectEqual(d.device.publisher, c.device.publisher);
    try std.testing.expectEqual(d.net.chunk_kb, c.net.chunk_kb);
    try std.testing.expectEqual(d.net.upload_timeout_s, c.net.upload_timeout_s);
    try std.testing.expectEqual(d.breaker.fails, c.breaker.fails);
    try std.testing.expectEqualStrings(d.telegram.api_base, c.telegram.api_base);
    try std.testing.expectEqualStrings(d.telegram.token_file, c.telegram.token_file);
    try std.testing.expectEqualStrings(d.telegram.chat_file, c.telegram.chat_file);
    try std.testing.expectEqualStrings(d.telegram.test_chat_file, c.telegram.test_chat_file);
    try std.testing.expectEqual(d.telegram.feed_limit, c.telegram.feed_limit);
    try std.testing.expectEqualStrings(d.net.allow_hosts[0], c.net.allow_hosts[0]);
    try std.testing.expectEqualStrings("", c.source.dir);
}
// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
