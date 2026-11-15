// Config loader: strict (unknown key -> refuse with line/col). Every tunable lives in 00-config.json; defaults here must equal the shipped file (parity test).
const std = @import("std");

pub const Source = struct { dir: []const u8 = "", max_age_days: u32 = 14 };
pub const Device = struct { publisher: bool = false };
pub const Terms = struct { ack_auto_post: bool = false };
pub const Limits = struct { daily_cap: u32 = 2, gap_min_s: u32 = 600, gap_max_s: u32 = 1800, disk_min_mb: u32 = 500, run_budget_s: u32 = 1800, quota_block_h: u32 = 24 };
pub const Video = struct {
    min_s: u32 = 3,
    max_s: u32 = 90,
    min_kb: u32 = 75,
    max_mb: u32 = 500,
    fps_warn_at: u32 = 30,
    warn_min_w: u32 = 360,
    warn_min_h: u32 = 640,
    warn_max_w: u32 = 1080,
    warn_max_h: u32 = 1920,
    vcodec: []const u8 = "avc1",
    probe_tool: []const u8 = "",
};
pub const Post = struct {
    mode: []const u8 = "stage",
    visibility: []const u8 = "PUBLIC",
    ai_notice_required: bool = true,
    text_max: u32 = 3000,
    text_margin: u32 = 100,
    title_max: u32 = 100,
    hashtags_max: u32 = 5,
    url_in_text: bool = false,
    url_template: []const u8 = "https://www.linkedin.com/feed/update/{urn}",
    reshare_disabled: bool = false,
};
pub const Net = struct {
    timeout_s: u32 = 60,
    upload_timeout_s: u32 = 600,
    part_retries: u32 = 3,
    backoff_ms: u32 = 2000,
    status_poll_s: u32 = 15,
    status_poll_max_s: u32 = 600,
    body_cap_kb: u32 = 512,
    user_agent: []const u8 = "linkedin-shorts/0.1",
    allow_hosts: []const []const u8 = &.{ "api.linkedin.com", "www.linkedin.com" },
};
pub const Breaker = struct { fails: u32 = 3, cool_h: u32 = 6 };
pub const Safety = struct { dup_probe: bool = false, new_db_hours: u32 = 24 };
pub const Account = struct {
    token_env: []const u8 = "LINK_SHOR_TOKEN",
    token_file: []const u8 = "link-shor-token",
    token_meta_file: []const u8 = "link-shor-token-meta",
    person_id_env: []const u8 = "LINK_SHOR_PERSON_ID",
    person_id_file: []const u8 = "link-shor-person-id",
    client_id_env: []const u8 = "LINK_SHOR_CLIENT_ID",
    client_id_file: []const u8 = "link-shor-client-id",
    client_secret_env: []const u8 = "LINK_SHOR_CLIENT_SECRET",
    client_secret_file: []const u8 = "link-shor-client-secret",
    refresh_token_env: []const u8 = "LINK_SHOR_REFRESH_TOKEN",
    refresh_token_file: []const u8 = "link-shor-refresh-token",
};
pub const Api = struct {
    base: []const u8 = "https://api.linkedin.com",
    oauth_base: []const u8 = "https://www.linkedin.com",
    version: []const u8 = "202610",
    version_warn_months: u32 = 9,
};

pub const Config = struct {
    data_dir: []const u8 = "~/.linkedin-shorts",
    db_file: []const u8 = "ledger.db",
    secrets_dir: []const u8 = "~/.04-clou-secr",
    tz_offset_hours: i32 = 7,
    device: Device = .{},
    terms: Terms = .{},
    source: Source = .{},
    limits: Limits = .{},
    video: Video = .{},
    post: Post = .{},
    net: Net = .{},
    breaker: Breaker = .{},
    safety: Safety = .{},
    account: Account = .{},
    api: Api = .{},
    retry_pre_send: u32 = 2,
    token_warn_days: u32 = 10,
};

pub const LoadErr = error{ BadConfig, NoConfig, OutOfMemory };

fn bad(why: *[160]u8, why_len: *usize, comptime fmt: []const u8, args: anytype) LoadErr {
    const s = std.fmt.bufPrint(why, fmt, args) catch "config: bad";
    why_len.* = s.len;
    return LoadErr.BadConfig;
}

// api.version is YYYYMM (six digits, month 01..12)
pub fn versionOk(v: []const u8) bool {
    if (v.len != 6) return false;
    for (v) |c| if (c < '0' or c > '9') return false;
    const mo = std.fmt.parseInt(u8, v[4..6], 10) catch return false;
    return mo >= 1 and mo <= 12;
}

pub const Mode = enum { stage, approve, auto };
pub fn modeOf(s: []const u8) ?Mode {
    inline for (@typeInfo(Mode).@"enum".fields) |f| if (std.mem.eql(u8, s, f.name)) return @enumFromInt(f.value);
    return null;
}

fn visOk(v: []const u8) bool {
    const ok = [_][]const u8{ "PUBLIC", "CONNECTIONS", "LOGGED_IN", "CONTAINER" };
    for (ok) |o| if (std.mem.eql(u8, v, o)) return true;
    return false;
}

// Plain-language range checks. Returns the first problem.
pub fn validate(c: Config, why: *[160]u8, why_len: *usize) LoadErr!void {
    const mode = modeOf(c.post.mode) orelse return bad(why, why_len, "config: post.mode must be stage, approve or auto", .{});
    if (mode == .auto and !c.terms.ack_auto_post) return bad(why, why_len, "config: post.mode auto needs terms.ack_auto_post true (a person must accept the LinkedIn Terms risk)", .{});
    if (c.limits.daily_cap < 1 or c.limits.daily_cap > 20) return bad(why, why_len, "config: limits.daily_cap must be 1..20", .{});
    if (c.limits.gap_min_s > c.limits.gap_max_s) return bad(why, why_len, "config: limits.gap_min_s must be <= gap_max_s", .{});
    if (c.limits.run_budget_s == 0 or c.limits.quota_block_h == 0) return bad(why, why_len, "config: limits.run_budget_s and quota_block_h must be > 0", .{});
    if (c.video.min_s == 0 or c.video.min_s > c.video.max_s) return bad(why, why_len, "config: video.min_s must be 1..max_s", .{});
    if (c.video.min_kb == 0 or c.video.max_mb == 0) return bad(why, why_len, "config: video.min_kb and max_mb must be > 0", .{});
    if (c.post.text_max < 200 or c.post.text_margin >= c.post.text_max) return bad(why, why_len, "config: post.text_max must be >= 200 and above text_margin", .{});
    if (c.post.title_max == 0) return bad(why, why_len, "config: post.title_max must be > 0", .{});
    if (!visOk(c.post.visibility)) return bad(why, why_len, "config: post.visibility must be PUBLIC, CONNECTIONS, LOGGED_IN or CONTAINER", .{});
    if (std.mem.indexOf(u8, c.post.url_template, "{urn}") == null) return bad(why, why_len, "config: post.url_template must contain {{urn}}", .{});
    if (c.net.timeout_s == 0 or c.net.upload_timeout_s == 0 or c.net.body_cap_kb == 0) return bad(why, why_len, "config: net timeouts and body_cap_kb must be > 0", .{});
    if (c.net.status_poll_s == 0 or c.net.status_poll_max_s < c.net.status_poll_s) return bad(why, why_len, "config: net.status_poll_s must be > 0 and <= status_poll_max_s", .{});
    if (c.net.allow_hosts.len == 0) return bad(why, why_len, "config: net.allow_hosts must not be empty", .{});
    if (c.breaker.fails == 0 or c.breaker.cool_h == 0) return bad(why, why_len, "config: breaker.fails and cool_h must be > 0", .{});
    if (c.safety.new_db_hours == 0) return bad(why, why_len, "config: safety.new_db_hours must be > 0", .{});
    const loop = std.mem.startsWith(u8, c.api.base, "http://127.0.0.1");
    if (!std.mem.startsWith(u8, c.api.base, "https://") and !loop) return bad(why, why_len, "config: api.base must start with https://", .{});
    if (!std.mem.startsWith(u8, c.api.oauth_base, "https://") and !std.mem.startsWith(u8, c.api.oauth_base, "http://127.0.0.1")) return bad(why, why_len, "config: api.oauth_base must start with https://", .{});
    if (!versionOk(c.api.version)) return bad(why, why_len, "config: api.version must be six digits YYYYMM, like 202610", .{});
    if (c.api.version_warn_months == 0) return bad(why, why_len, "config: api.version_warn_months must be > 0", .{});
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

test "unknown key refused with line, ranges checked, mode rules" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var w: [160]u8 = undefined;
    var n: usize = 0;
    const c = try parse(arena.allocator(), "{\"limits\":{\"daily_cap\":5}}", &w, &n);
    try std.testing.expectEqual(@as(u32, 5), c.limits.daily_cap);
    try std.testing.expectError(LoadErr.BadConfig, parse(arena.allocator(), "{\"limitz\":{}}", &w, &n));
    try std.testing.expect(std.mem.indexOf(u8, w[0..n], "line 1") != null);
    try std.testing.expectError(LoadErr.BadConfig, parse(arena.allocator(), "{\"limits\":{\"daily_cap\":21}}", &w, &n));
    try std.testing.expectError(LoadErr.BadConfig, parse(arena.allocator(), "{\"limits\":{\"daily_cap\":0}}", &w, &n));
    try std.testing.expectError(LoadErr.BadConfig, parse(arena.allocator(), "{\"limits\":{\"gap_min_s\":9,\"gap_max_s\":3}}", &w, &n));
    try std.testing.expectError(LoadErr.BadConfig, parse(arena.allocator(), "{\"api\":{\"version\":\"27\"}}", &w, &n));
    try std.testing.expectError(LoadErr.BadConfig, parse(arena.allocator(), "{\"api\":{\"version\":\"202613\"}}", &w, &n));
    try std.testing.expectError(LoadErr.BadConfig, parse(arena.allocator(), "{\"video\":{\"min_s\":100}}", &w, &n));
    try std.testing.expect(std.mem.indexOf(u8, w[0..n], "min_s") != null);
    try std.testing.expectError(LoadErr.BadConfig, parse(arena.allocator(), "{\"post\":{\"mode\":\"yolo\"}}", &w, &n));
    // auto needs the person's acknowledgement; approve does not
    try std.testing.expectError(LoadErr.BadConfig, parse(arena.allocator(), "{\"post\":{\"mode\":\"auto\"}}", &w, &n));
    try std.testing.expect(std.mem.indexOf(u8, w[0..n], "ack_auto_post") != null);
    _ = try parse(arena.allocator(), "{\"post\":{\"mode\":\"auto\"},\"terms\":{\"ack_auto_post\":true}}", &w, &n);
    _ = try parse(arena.allocator(), "{\"post\":{\"mode\":\"approve\"}}", &w, &n);
    try std.testing.expectError(LoadErr.BadConfig, parse(arena.allocator(), "{\"post\":{\"visibility\":\"EVERYONE\"}}", &w, &n));
    try std.testing.expectError(LoadErr.BadConfig, parse(arena.allocator(), "{\"post\":{\"url_template\":\"x\"}}", &w, &n));
}

// shipped file == built-in defaults: a typo in either shows up here; and the shipped file is the safe one
test "shipped 00-config.json equals the defaults and ships stage-only" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var w: [160]u8 = undefined;
    var n: usize = 0;
    const shipped = try load(a, std.testing.io, "00-config.json", &w, &n);
    const s1 = try std.json.Stringify.valueAlloc(a, shipped, .{});
    const s2 = try std.json.Stringify.valueAlloc(a, Config{}, .{});
    try std.testing.expectEqualStrings(s2, s1);
    try std.testing.expectEqualStrings("stage", shipped.post.mode);
    try std.testing.expect(!shipped.terms.ack_auto_post);
    try std.testing.expect(!shipped.device.publisher);
    try std.testing.expect(!shipped.safety.dup_probe);
}
