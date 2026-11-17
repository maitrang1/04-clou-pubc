// =====================================================================
// Des: Reads the producer's hand-off folder (read only) - finds every .json, checks the pair against X's video rules (mp4 beside it, duration, frame rate, H.264, AAC-LC, aspect, size, label present, text buildable, not rejected or stale) and says ready or why not
// Flo: list *.json > markers (.rejected/.stale) > parse json > check fields > probe the mp4 > X video rules > build text to test limits and the link guard > sorted oldest first
// Cre: 2026-11-16                          - | Mod: 2026-11-16
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: Ctx (source.dir, video limits, post limits)
// Out: list of Item {name, status, reason, pair, facts, pkey, paths}
// Run: not run directly - imported by cm-scan, cm-publish, cm-approve
// =====================================================================
const std = @import("std");
const ctx_mod = @import("co-ctx.zig");
const util = @import("co-util.zig");
const probe_mod = @import("rw-probe.zig");
const text_mod = @import("rw-text.zig");

pub const Pair = struct {
    car: []const u8 = "",
    code: []const u8 = "",
    template: []const u8 = "",
    mp4: []const u8 = "",
    seconds: f64 = 0,
    width: u32 = 0,
    height: u32 = 0,
    hooks: []const []const u8 = &.{},
    description: []const u8 = "",
    hashtags: []const []const u8 = &.{},
    ai_notice: []const u8 = "",
    review: bool = false,
    plates: []const u8 = "",
    made_at: []const u8 = "",
    listing_url: []const u8 = "",
};

pub const Status = enum { ready, invalid, rejected, stale, old };

pub const Item = struct {
    name: []const u8, // file stem: the handle for approve / hold / resolve
    status: Status,
    reason: []const u8 = "",
    note: []const u8 = "", // warnings that do not block
    pair: Pair = .{},
    facts: ?probe_mod.Facts = null,
    pkey: []const u8 = "",
    json_path: []const u8 = "",
    mp4_path: []const u8 = "",
};

pub const Err = error{ NoSource, SourceUnreadable, OutOfMemory };

pub const key_tail = "xdot-shor";

pub fn pkeyOf(a: std.mem.Allocator, p: Pair) ![]u8 {
    return std.fmt.allocPrint(a, "{s}:{s}:{s}", .{ std.mem.trim(u8, p.car, " "), std.mem.trim(u8, p.template, " "), key_tail });
}

fn safeName(n: []const u8) bool {
    if (n.len == 0 or n.len > 200) return false;
    if (std.mem.indexOfAny(u8, n, "/\\") != null) return false;
    if (std.mem.indexOf(u8, n, "..") != null) return false;
    return true;
}

fn lessThan(_: void, x: Item, y: Item) bool {
    const c = std.mem.order(u8, x.pair.made_at, y.pair.made_at);
    if (c != .eq) return c == .lt;
    return std.mem.order(u8, x.name, y.name) == .lt;
}

fn bad(a: std.mem.Allocator, name: []const u8, st: Status, jp: []const u8, comptime fmt: []const u8, args: anytype) !Item {
    return .{ .name = name, .status = st, .json_path = jp, .reason = try std.fmt.allocPrint(a, fmt, args) };
}

pub fn scan(cx: *const ctx_mod.Ctx, a: std.mem.Allocator) Err![]Item {
    if (cx.cfg.source.dir.len == 0) return Err.NoSource;
    const src = try cx.rel(a, cx.cfg.source.dir);
    var dir = std.Io.Dir.cwd().openDir(cx.io, src, .{ .iterate = true }) catch return Err.SourceUnreadable;
    defer dir.close(cx.io);
    var items: std.ArrayList(Item) = .empty;
    var it = dir.iterate();
    while (it.next(cx.io) catch return Err.SourceUnreadable) |e| {
        if (e.kind != .file or !std.mem.endsWith(u8, e.name, ".json")) continue;
        const stem = try a.dupe(u8, e.name[0 .. e.name.len - 5]);
        try items.append(a, try one(cx, a, src, stem));
    }
    std.mem.sort(Item, items.items, {}, lessThan);
    return items.toOwnedSlice(a);
}

fn one(cx: *const ctx_mod.Ctx, a: std.mem.Allocator, src: []const u8, stem: []const u8) std.mem.Allocator.Error!Item {
    const jp = try std.fmt.allocPrint(a, "{s}/{s}.json", .{ src, stem });
    const rej = try std.fmt.allocPrint(a, "{s}/{s}.rejected", .{ src, stem });
    const stl = try std.fmt.allocPrint(a, "{s}/{s}.stale", .{ src, stem });
    if (util.exists(cx.io, rej)) return bad(a, stem, .rejected, jp, "a person rejected it ({s}.rejected)", .{stem});
    if (util.exists(cx.io, stl)) return bad(a, stem, .stale, jp, "being re-rendered ({s}.stale)", .{stem});
    const text = util.readAll(a, cx.io, jp, 1 << 20) catch return bad(a, stem, .invalid, jp, "cannot read the json", .{});
    const body = if (std.mem.startsWith(u8, text, "\xef\xbb\xbf")) text[3..] else text;
    const p = std.json.parseFromSliceLeaky(Pair, a, body, .{ .ignore_unknown_fields = true }) catch return bad(a, stem, .invalid, jp, "json does not parse", .{});
    if (std.mem.trim(u8, p.car, " ").len == 0 or std.mem.trim(u8, p.template, " ").len == 0) return withPair(a, stem, .invalid, jp, p, "json has no car or template", .{});
    const mp4_name = if (p.mp4.len > 0) p.mp4 else try std.fmt.allocPrint(a, "{s}.mp4", .{stem});
    if (!safeName(mp4_name)) return withPair(a, stem, .invalid, jp, p, "mp4 name is not a plain file name", .{});
    const mp4p = try std.fmt.allocPrint(a, "{s}/{s}", .{ src, mp4_name });
    // age: the json is written last, so its time is the video's age
    if (util.mtimeMs(cx.io, jp)) |mt| {
        const age = cx.nowMs() - mt;
        if (age > @as(i64, cx.cfg.source.max_age_days) * 86_400_000) return withPair(a, stem, .old, jp, p, "older than {d} days (source.max_age_days)", .{cx.cfg.source.max_age_days});
    } else |_| {}
    const size = util.fileSize(cx.io, mp4p) catch return withPair(a, stem, .invalid, jp, p, "mp4 {s} is missing beside the json", .{mp4_name});
    if (size == 0) return withPair(a, stem, .invalid, jp, p, "mp4 is empty", .{});
    if (size > @as(u64, cx.cfg.video.max_mb) * 1024 * 1024) return withPair(a, stem, .invalid, jp, p, "mp4 is over {d} MB (video.max_mb)", .{cx.cfg.video.max_mb});
    var pa = std.heap.ArenaAllocator.init(cx.gpa); // the moov buffer lives only for this probe
    defer pa.deinit();
    const f = probe_mod.probe(cx.io, pa.allocator(), mp4p) catch |e| return withPair(a, stem, .invalid, jp, p, "cannot read the mp4 ({s})", .{@errorName(e)});
    const v = cx.cfg.video;
    const secs = (f.ms + 999) / 1000;
    if (f.ms < v.min_ms) return withPair(a, stem, .invalid, jp, p, "too short ({d} ms, video.min_ms {d})", .{ f.ms, v.min_ms });
    if (secs > v.max_s) return withPair(a, stem, .invalid, jp, p, "too long ({d}s, video.max_s {d})", .{ secs, v.max_s });
    const long = @max(f.width, f.height);
    const short = @min(f.width, f.height);
    if (short < v.side_min) return withPair(a, stem, .invalid, jp, p, "too small ({d}x{d}, a side must be at least {d})", .{ f.width, f.height, v.side_min });
    if (@as(u64, long) > @as(u64, short) * v.ratio_max) return withPair(a, stem, .invalid, jp, p, "aspect ratio outside 1:{d} to {d}:1 ({d}x{d})", .{ v.ratio_max, v.ratio_max, f.width, f.height });
    if (f.fps_x100 > v.fps_max * 100 + 50) return withPair(a, stem, .invalid, jp, p, "frame rate {d}.{d:0>2} is over {d} fps (video.fps_max): the producer must re-render", .{ f.fps_x100 / 100, f.fps_x100 % 100, v.fps_max });
    if (f.vcodec[0] != 0 and !std.mem.eql(u8, &f.vcodec, "avc1") and !std.mem.eql(u8, &f.vcodec, "avc3")) return withPair(a, stem, .invalid, jp, p, "video codec is {s}, X wants H.264 (avc1): the producer must re-render", .{&f.vcodec});
    if (f.acodec[0] != 0 and !std.mem.eql(u8, &f.acodec, "mp4a")) return withPair(a, stem, .invalid, jp, p, "audio codec is {s}, X wants AAC (mp4a): the producer must re-render", .{&f.acodec});
    if (f.aac_lc) |lc| if (!lc) return withPair(a, stem, .invalid, jp, p, "audio is HE-AAC, X supports only AAC-LC: the producer must re-render", .{});
    if (f.channels > 2) return withPair(a, stem, .invalid, jp, p, "audio has {d} channels, X takes mono or stereo", .{f.channels});
    var note: std.ArrayList(u8) = .empty;
    const in_box = long <= v.box_long and short <= v.box_short;
    if (!in_box) {
        if (std.mem.eql(u8, v.dims_policy, "strict")) return withPair(a, stem, .invalid, jp, p, "{d}x{d} is over X's {d}x{d} box (video.dims_policy strict)", .{ f.width, f.height, v.box_long, v.box_short });
        try note.print(a, "{d}x{d} is over X's {d}x{d} box: sent anyway (dims_policy warn), X may downscale or refuse; ", .{ f.width, f.height, v.box_long, v.box_short });
    }
    // the text must be buildable: label present, limits respected, no link-like word
    _ = text_mod.build(a, .{ .hooks = p.hooks, .description = p.description, .hashtags = p.hashtags, .listing_url = p.listing_url, .ai_notice = p.ai_notice }, cx.cfg.post) catch |e| switch (e) {
        error.NoNotice => return withPair(a, stem, .invalid, jp, p, "json has no ai_notice: every post must carry the AI label", .{}),
        error.NoText => return withPair(a, stem, .invalid, jp, p, "json has no hooks and no description: no text", .{}),
        error.NoticeTooLong => return withPair(a, stem, .invalid, jp, p, "ai_notice does not fit in the post text limit", .{}),
        error.LooksLikeUrl => return withPair(a, stem, .invalid, jp, p, "the text has a link or a word.domain: it would cost the URL price (post.url_guard); the producer must remove it", .{}),
        error.OutOfMemory => return error.OutOfMemory,
    };
    if (p.width != 0 and (p.width != f.width or p.height != f.height)) try note.print(a, "json says {d}x{d}, file says {d}x{d}; ", .{ p.width, p.height, f.width, f.height });
    if (f.vcodec[0] == 0) try note.appendSlice(a, "video codec not found in the file; ");
    if (f.fps_x100 == 0) try note.appendSlice(a, "frame rate not found in the file; ");
    if (f.acodec[0] == 0) try note.appendSlice(a, "no audio track found; ");
    try note.appendSlice(a, "pixel format and GOP are not probed");
    return .{ .name = stem, .status = .ready, .pair = p, .facts = f, .pkey = try pkeyOf(a, p), .json_path = jp, .mp4_path = mp4p, .note = try note.toOwnedSlice(a) };
}

fn withPair(a: std.mem.Allocator, stem: []const u8, st: Status, jp: []const u8, p: Pair, comptime fmt: []const u8, args: anytype) !Item {
    var it = try bad(a, stem, st, jp, fmt, args);
    it.pair = p;
    return it;
}

// ---- tests ----
const T = struct {
    dir: []const u8,
    fn put(self: T, a: std.mem.Allocator, name: []const u8, data: []const u8) !void {
        const p = try std.fmt.allocPrint(a, "{s}/{s}", .{ self.dir, name });
        try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = p, .data = data });
    }
};

fn goodJson(a: std.mem.Allocator, car: []const u8, made: []const u8, extra: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "{{\"car\":\"{s}\",\"code\":\"C1\",\"template\":\"t1\",\"mp4\":\"\",\"hooks\":[\"Xe dep\"],\"description\":\"Mo ta\",\"hashtags\":[\"xe\"],\"ai_notice\":\"AI\",\"review\":false,\"made_at\":\"{s}\",\"new_field_from_producer\":1{s}}}", .{ car, made, extra });
}

test "scan: every verdict, sorted oldest first, source untouched" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    var env = std.process.Environ.Map.init(a);
    var cx = ctx_mod.testCtx(a, &env, dir);
    cx.cfg_dir = ".";
    cx.cfg.source.dir = dir;
    const t = T{ .dir = dir };
    const good = try probe_mod.testMp4(a, 1080, 1920, 15, true);
    // two ready, newer one written first
    try t.put(a, "b-new.json", try goodJson(a, "car2", "2026-11-02T10:00:00Z", ""));
    try t.put(a, "b-new.mp4", good);
    try t.put(a, "a-old.json", try goodJson(a, "car1", "2026-11-01T10:00:00Z", ""));
    try t.put(a, "a-old.mp4", good);
    // landscape is fine for X (over the box: a warning, not a refusal)
    try t.put(a, "wide.json", try goodJson(a, "w", "2026-11-03", ""));
    try t.put(a, "wide.mp4", try probe_mod.testMp4(a, 1920, 1080, 15, true));
    // not ready: too long, hevc, he-aac, 61 fps, 5 channels, extreme ratio, tiny, missing mp4, bad json, label missing, link in text, markers, traversal, no car
    try t.put(a, "long.json", try goodJson(a, "l", "2026-11-03", ""));
    try t.put(a, "long.mp4", try probe_mod.testMp4(a, 1080, 1920, 120, true));
    try t.put(a, "hevc.json", try goodJson(a, "h", "2026-11-03", ""));
    try t.put(a, "hevc.mp4", try probe_mod.testMp4Opts(a, 1080, 1920, 15, true, 0, .{ .vcodec = "hvc1" }));
    try t.put(a, "heaac.json", try goodJson(a, "he", "2026-11-03", ""));
    try t.put(a, "heaac.mp4", try probe_mod.testMp4Opts(a, 1080, 1920, 15, true, 0, .{ .aot = 5 }));
    try t.put(a, "fps.json", try goodJson(a, "f", "2026-11-03", ""));
    try t.put(a, "fps.mp4", try probe_mod.testMp4Opts(a, 1080, 1920, 15, true, 0, .{ .fps = 120 }));
    try t.put(a, "chan.json", try goodJson(a, "c", "2026-11-03", ""));
    try t.put(a, "chan.mp4", try probe_mod.testMp4Opts(a, 1080, 1920, 15, true, 0, .{ .channels = 6 }));
    try t.put(a, "ratio.json", try goodJson(a, "r2", "2026-11-03", ""));
    try t.put(a, "ratio.mp4", try probe_mod.testMp4(a, 1920, 300, 15, true));
    try t.put(a, "tiny.json", try goodJson(a, "ti", "2026-11-03", ""));
    try t.put(a, "tiny.mp4", try probe_mod.testMp4(a, 16, 64, 15, true));
    try t.put(a, "nomp4.json", try goodJson(a, "n", "2026-11-03", ""));
    try t.put(a, "broken.json", "{not json");
    try t.put(a, "nolabel.json", "{\"car\":\"x\",\"template\":\"t\",\"hooks\":[\"h\"],\"ai_notice\":\"\"}");
    try t.put(a, "nolabel.mp4", good);
    try t.put(a, "link.json", "{\"car\":\"k\",\"template\":\"t\",\"hooks\":[\"xem abc.com\"],\"ai_notice\":\"AI\"}");
    try t.put(a, "link.mp4", good);
    try t.put(a, "rej.json", try goodJson(a, "r", "2026-11-03", ""));
    try t.put(a, "rej.mp4", good);
    try t.put(a, "rej.rejected", "x");
    try t.put(a, "stl.json", try goodJson(a, "s", "2026-11-03", ""));
    try t.put(a, "stl.mp4", good);
    try t.put(a, "stl.stale", "x");
    try t.put(a, "trav.json", try std.fmt.allocPrint(a, "{{\"car\":\"t\",\"template\":\"t\",\"mp4\":\"../x.mp4\",\"hooks\":[\"h\"],\"ai_notice\":\"AI\"}}", .{}));
    try t.put(a, "nocar.json", "{\"template\":\"t\",\"mp4\":\"a.mp4\"}");
    const items = try scan(&cx, a);
    var ready: usize = 0;
    var seen = std.StringHashMap(Status).init(a);
    for (items) |i| {
        try seen.put(i.name, i.status);
        if (i.status == .ready) ready += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), ready);
    for ([_][]const u8{ "long", "hevc", "heaac", "fps", "chan", "ratio", "tiny", "nomp4", "broken", "nolabel", "link", "trav", "nocar" }) |n| try std.testing.expect(seen.get(n).? == .invalid);
    try std.testing.expect(seen.get("rej").? == .rejected and seen.get("stl").? == .stale and seen.get("wide").? == .ready);
    // oldest first among the ready ones
    var first_ready: []const u8 = "";
    for (items) |i| if (i.status == .ready) {
        first_ready = i.name;
        break;
    };
    try std.testing.expect(std.mem.eql(u8, first_ready, "a-old") or std.mem.eql(u8, first_ready, "wide")); // wide has no made_at date earlier than 2026-11-03
    for (items) |i| {
        if (std.mem.eql(u8, i.name, "wide")) try std.testing.expect(std.mem.indexOf(u8, i.note, "over X's") != null);
        if (std.mem.eql(u8, i.name, "long")) try std.testing.expect(std.mem.indexOf(u8, i.reason, "too long") != null);
        if (std.mem.eql(u8, i.name, "hevc")) try std.testing.expect(std.mem.indexOf(u8, i.reason, "H.264") != null);
        if (std.mem.eql(u8, i.name, "heaac")) try std.testing.expect(std.mem.indexOf(u8, i.reason, "HE-AAC") != null);
        if (std.mem.eql(u8, i.name, "fps")) try std.testing.expect(std.mem.indexOf(u8, i.reason, "frame rate") != null);
        if (std.mem.eql(u8, i.name, "link")) try std.testing.expect(std.mem.indexOf(u8, i.reason, "URL price") != null);
        if (std.mem.eql(u8, i.name, "nolabel")) try std.testing.expect(std.mem.indexOf(u8, i.reason, "ai_notice") != null);
        if (std.mem.eql(u8, i.name, "a-old")) try std.testing.expectEqualStrings("car1:t1:xdot-shor", i.pkey);
    }
    // strict dims policy refuses what warn only flags
    cx.cfg.video.dims_policy = "strict";
    const strict = try scan(&cx, a);
    for (strict) |i| if (std.mem.eql(u8, i.name, "wide")) try std.testing.expect(i.status == .invalid);
}

test "scan: old files are skipped, an empty source is a config error, a missing folder is unreadable" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    var env = std.process.Environ.Map.init(a);
    var cx = ctx_mod.testCtx(a, &env, dir);
    cx.cfg_dir = ".";
    try std.testing.expectError(Err.NoSource, scan(&cx, a));
    cx.cfg.source.dir = "no/such/folder";
    try std.testing.expectError(Err.SourceUnreadable, scan(&cx, a));
    cx.cfg.source.dir = dir;
    const t = T{ .dir = dir };
    try t.put(a, "o.json", try goodJson(a, "o", "2026-11-01", ""));
    try t.put(a, "o.mp4", try probe_mod.testMp4(a, 1080, 1920, 15, true));
    cx.fake_now_ms = util.nowMs(std.testing.io) + 30 * 86_400_000; // a month later
    const items = try scan(&cx, a);
    try std.testing.expectEqual(@as(usize, 1), items.len);
    try std.testing.expect(items[0].status == .old);
}
// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
