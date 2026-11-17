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

pub const Source = struct { dir: []const u8 = "", max_age_days: u32 = 14 };
pub const Limits = struct { daily_cap: u32 = 3, daily_cap_max: u32 = 10, gap_min_s: u32 = 600, gap_max_s: u32 = 1800, disk_min_mb: u32 = 500, run_budget_s: u32 = 2400 };
pub const Video = struct { min_s: u32 = 3, max_s: u32 = 60, min_w: u32 = 540, min_h: u32 = 960, max_mb: u32 = 512, want_faststart: bool = true };
// the AI label: Vimeo has no documented API field yet, so the owner proves one (inspect --diff) and puts it here; `off` blocks going public
pub const AiLabel = struct { mode: []const u8 = "off", via: []const u8 = "create", body: []const u8 = "" };
pub const Post = struct {
    public: bool = false,
    visibility: []const u8 = "nobody",
    embed: []const u8 = "private",
    comments: []const u8 = "nobody",
    ai_notice_required: bool = true,
    ai_tag: []const u8 = "ai-generated",
    ai_label: AiLabel = .{},
    use_tags: bool = true,
    title_max: u32 = 128,
    desc_max_bytes: u32 = 4000,
    hashtags_max: u32 = 15,
    tags_max: u32 = 10,
};
pub const Net = struct {
    timeout_s: u32 = 60,
    upload_timeout_s: u32 = 1800,
    read_kb: u32 = 256,
    chunk_mb: u32 = 0,
    backoff_ms: u32 = 2000,
    retries: u32 = 5,
    status_poll_s: u32 = 10,
    status_poll_max_s: u32 = 180,
    body_cap_kb: u32 = 1024,
    rate_floor: u32 = 2,
    user_agent: []const u8 = "vimeo-shorts/0.1",
    allow_hosts: []const []const u8 = &.{ "api.vimeo.com", "*.vimeo.com" },
};
pub const Breaker = struct { fails: u32 = 3, cool_h: u32 = 6 };
pub const Approval = struct { require_for_review: bool = true };
pub const Vimeo = struct {
    api_base: []const u8 = "https://api.vimeo.com",
    api_version: []const u8 = "3.4",
    upload_hosts: []const []const u8 = &.{"*.tus.vimeo.com"},
    scope_need: []const []const u8 = &.{ "public", "private", "edit", "upload" },
    token_env: []const u8 = "VIME_TOKEN",
    token_file: []const u8 = "vime-token.txt",
};

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
    vimeo: Vimeo = .{},
    retry_pre_send: u32 = 2,
    token_warn_days: u32 = 14,
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

// keys the app builds itself: the AI-label snippet may not override them
const reserved = [_][]const u8{ "name", "description", "privacy", "upload" };

fn listHas(list: []const []const u8, v: []const u8) bool {
    return oneOf(v, list);
}

// the AI-label body must be a JSON object with no reserved top-level key
pub fn aiBodyOk(a: std.mem.Allocator, body: []const u8) bool {
    const v = std.json.parseFromSliceLeaky(std.json.Value, a, body, .{}) catch return false;
    if (v != .object) return false;
    for (reserved) |k| if (v.object.contains(k)) return false;
    return true;
}

// range + safety checks on a parsed config
pub fn validate(a: std.mem.Allocator, c: Config, why: *[160]u8, why_len: *usize) LoadErr!void {
    if (c.limits.daily_cap == 0 or c.limits.daily_cap > c.limits.daily_cap_max) return bad(why, why_len, "config: limits.daily_cap must be 1..daily_cap_max ({d})", .{c.limits.daily_cap_max});
    if (c.limits.daily_cap_max == 0 or c.limits.daily_cap_max > 1000) return bad(why, why_len, "config: limits.daily_cap_max must be 1..1000", .{});
    if (c.limits.gap_min_s > c.limits.gap_max_s) return bad(why, why_len, "config: limits.gap_min_s must be <= gap_max_s", .{});
    if (c.limits.run_budget_s == 0 or c.limits.run_budget_s <= c.net.upload_timeout_s) return bad(why, why_len, "config: limits.run_budget_s must be longer than net.upload_timeout_s ({d}s)", .{c.net.upload_timeout_s});
    if (c.video.min_s == 0 or c.video.min_s > c.video.max_s or c.video.max_s > 600) return bad(why, why_len, "config: video.min_s <= video.max_s <= 600 (these are short videos)", .{});
    if (c.video.min_w == 0 or c.video.min_h == 0 or c.video.max_mb == 0) return bad(why, why_len, "config: video.min_w, min_h, max_mb must be > 0", .{});
    if (!oneOf(c.post.visibility, &.{ "nobody", "unlisted", "contacts", "users" })) return bad(why, why_len, "config: post.visibility must be nobody, unlisted, contacts or users (public needs post.public)", .{});
    if (!oneOf(c.post.embed, &.{ "private", "public" })) return bad(why, why_len, "config: post.embed must be private or public", .{});
    if (!oneOf(c.post.comments, &.{ "nobody", "contacts", "anybody" })) return bad(why, why_len, "config: post.comments must be nobody, contacts or anybody", .{});
    if (!c.post.ai_notice_required) return bad(why, why_len, "config: post.ai_notice_required is locked true (the AI label has no off switch)", .{});
    if (!c.approval.require_for_review) return bad(why, why_len, "config: approval.require_for_review is locked true (a person must look at review videos)", .{});
    if (c.post.ai_tag.len == 0 or c.post.ai_tag.len > 40) return bad(why, why_len, "config: post.ai_tag must be 1..40 characters", .{});
    if (c.post.title_max == 0 or c.post.title_max > 1000) return bad(why, why_len, "config: post.title_max must be 1..1000", .{});
    if (c.post.desc_max_bytes < 200 or c.post.desc_max_bytes > 20000) return bad(why, why_len, "config: post.desc_max_bytes must be 200..20000", .{});
    if (c.post.hashtags_max > 60) return bad(why, why_len, "config: post.hashtags_max must be 0..60", .{});
    if (c.post.tags_max == 0 or c.post.tags_max > 20) return bad(why, why_len, "config: post.tags_max must be 1..20 (Vimeo allows 20 tags)", .{});
    if (!oneOf(c.post.ai_label.mode, &.{ "off", "api" })) return bad(why, why_len, "config: post.ai_label.mode must be off or api", .{});
    if (!oneOf(c.post.ai_label.via, &.{ "create", "patch" })) return bad(why, why_len, "config: post.ai_label.via must be create or patch", .{});
    if (std.mem.eql(u8, c.post.ai_label.mode, "api") and !aiBodyOk(a, c.post.ai_label.body)) return bad(why, why_len, "config: post.ai_label.body must be a JSON object without name, description, privacy or upload", .{});
    if (c.net.timeout_s == 0 or c.net.upload_timeout_s == 0 or c.net.body_cap_kb == 0) return bad(why, why_len, "config: net timeouts and body_cap_kb must be > 0", .{});
    if (c.net.read_kb < 4 or c.net.read_kb > 65536) return bad(why, why_len, "config: net.read_kb must be 4..65536", .{});
    if (c.net.chunk_mb > 4096) return bad(why, why_len, "config: net.chunk_mb must be 0 (whole file) .. 4096", .{});
    if (c.net.retries > 10) return bad(why, why_len, "config: net.retries must be 0..10", .{});
    if (c.net.rate_floor > 20) return bad(why, why_len, "config: net.rate_floor must be 0..20", .{});
    if (c.net.status_poll_s == 0 or c.net.status_poll_s > c.net.status_poll_max_s) return bad(why, why_len, "config: net.status_poll_s must be 1..status_poll_max_s", .{});
    if (c.net.allow_hosts.len == 0) return bad(why, why_len, "config: net.allow_hosts must not be empty", .{});
    if (c.vimeo.upload_hosts.len == 0) return bad(why, why_len, "config: vimeo.upload_hosts must not be empty", .{});
    if (listHas(c.vimeo.scope_need, "delete")) return bad(why, why_len, "config: vimeo.scope_need must not contain delete (the app never deletes)", .{});
    if (!listHas(c.vimeo.scope_need, "upload") or !listHas(c.vimeo.scope_need, "edit")) return bad(why, why_len, "config: vimeo.scope_need needs upload and edit", .{});
    if (c.vimeo.api_base.len == 0 or c.vimeo.api_version.len == 0) return bad(why, why_len, "config: vimeo.api_base and api_version must not be empty", .{});
    if (c.vimeo.token_file.len == 0 and c.vimeo.token_env.len == 0) return bad(why, why_len, "config: vimeo.token_env or token_file must be set", .{});
    if (c.breaker.fails == 0 or c.breaker.cool_h == 0) return bad(why, why_len, "config: breaker.fails and cool_h must be > 0", .{});
    if (c.retry_pre_send > 5) return bad(why, why_len, "config: retry_pre_send must be 0..5", .{});
    if (c.token_warn_days == 0) return bad(why, why_len, "config: token_warn_days must be > 0", .{});
    if (c.tz_offset_hours < -12 or c.tz_offset_hours > 14) return bad(why, why_len, "config: tz_offset_hours must be -12..14", .{});
    if (c.db_file.len == 0 or c.kill_file.len == 0) return bad(why, why_len, "config: db_file and kill_file must not be empty", .{});
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
    try validate(arena, cfg, why, why_len);
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

test "safe defaults parse: nobody can see it, AI label off, no delete scope" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var w: [160]u8 = undefined;
    var n: usize = 0;
    const c = try parse(arena.allocator(), "{}", &w, &n);
    try std.testing.expect(!c.post.public);
    try std.testing.expectEqualStrings("nobody", c.post.visibility);
    try std.testing.expectEqualStrings("off", c.post.ai_label.mode);
    try std.testing.expect(c.post.ai_notice_required and c.approval.require_for_review);
    try std.testing.expect(!listHas(c.vimeo.scope_need, "delete"));
}

test "locked safety switches and ranges are refused" {
    try expectBad("{\"post\":{\"ai_notice_required\":false}}", "ai_notice_required");
    try expectBad("{\"approval\":{\"require_for_review\":false}}", "require_for_review");
    try expectBad("{\"post\":{\"visibility\":\"anybody\"}}", "post.visibility");
    try expectBad("{\"post\":{\"visibility\":\"secret\"}}", "visibility");
    try expectBad("{\"post\":{\"tags_max\":21}}", "tags_max");
    try expectBad("{\"post\":{\"desc_max_bytes\":10}}", "desc_max_bytes");
    try expectBad("{\"limits\":{\"daily_cap\":0}}", "daily_cap");
    try expectBad("{\"limits\":{\"daily_cap\":200}}", "daily_cap");
    try expectBad("{\"limits\":{\"gap_min_s\":9,\"gap_max_s\":3}}", "gap_min_s");
    try expectBad("{\"video\":{\"max_s\":601}}", "video.min_s");
    try expectBad("{\"vimeo\":{\"scope_need\":[\"upload\",\"edit\",\"delete\"]}}", "delete");
    try expectBad("{\"vimeo\":{\"scope_need\":[\"public\"]}}", "upload and edit");
    try expectBad("{\"net\":{\"allow_hosts\":[]}}", "allow_hosts");
    try expectBad("{\"net\":{\"read_kb\":1}}", "read_kb");
}

test "the AI-label snippet must be a plain object and may not override the safety fields" {
    try expectBad("{\"post\":{\"ai_label\":{\"mode\":\"api\",\"body\":\"nope\"}}}", "ai_label.body");
    try expectBad("{\"post\":{\"ai_label\":{\"mode\":\"api\",\"body\":\"{\\\"privacy\\\":{}}\"}}}", "ai_label.body");
    try expectBad("{\"post\":{\"ai_label\":{\"mode\":\"maybe\"}}}", "ai_label.mode");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var w: [160]u8 = undefined;
    var n: usize = 0;
    const c = try parse(arena.allocator(), "{\"post\":{\"ai_label\":{\"mode\":\"api\",\"body\":\"{\\\"fake_ai\\\":true}\"}}}", &w, &n);
    try std.testing.expectEqualStrings("api", c.post.ai_label.mode);
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
    try std.testing.expectEqual(d.video.max_s, c.video.max_s);
    try std.testing.expectEqual(d.post.public, c.post.public);
    try std.testing.expectEqualStrings(d.post.visibility, c.post.visibility);
    try std.testing.expectEqualStrings(d.post.ai_tag, c.post.ai_tag);
    try std.testing.expectEqualStrings(d.post.ai_label.mode, c.post.ai_label.mode);
    try std.testing.expectEqual(d.post.title_max, c.post.title_max);
    try std.testing.expectEqual(d.net.read_kb, c.net.read_kb);
    try std.testing.expectEqual(d.net.chunk_mb, c.net.chunk_mb);
    try std.testing.expectEqual(d.net.rate_floor, c.net.rate_floor);
    try std.testing.expectEqual(d.net.upload_timeout_s, c.net.upload_timeout_s);
    try std.testing.expectEqual(d.breaker.fails, c.breaker.fails);
    try std.testing.expectEqualStrings(d.vimeo.api_base, c.vimeo.api_base);
    try std.testing.expectEqualStrings(d.vimeo.api_version, c.vimeo.api_version);
    try std.testing.expectEqualStrings(d.vimeo.token_file, c.vimeo.token_file);
    try std.testing.expectEqual(d.vimeo.upload_hosts.len, c.vimeo.upload_hosts.len);
    try std.testing.expectEqual(d.vimeo.scope_need.len, c.vimeo.scope_need.len);
    try std.testing.expectEqual(d.token_warn_days, c.token_warn_days);
    try std.testing.expectEqualStrings("", c.source.dir);
}
// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
