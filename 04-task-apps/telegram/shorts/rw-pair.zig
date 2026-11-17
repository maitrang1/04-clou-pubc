// =====================================================================
// Des: Reads the producer's hand-off folder (read only) - finds every .json, checks the pair (mp4 beside it, size and length in range, label present, caption buildable, not rejected or stale) and says ready or why not
// Flo: list *.json > markers (.rejected/.stale) > parse json > check fields > probe the mp4 > build text to test limits > sorted oldest first
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

pub const key_tail = "tele-short";

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
    if (secs < v.min_s) return withPair(a, stem, .invalid, jp, p, "too short ({d}s, video.min_s {d})", .{ secs, v.min_s });
    if (secs > v.max_s) return withPair(a, stem, .invalid, jp, p, "too long ({d}s, video.max_s {d})", .{ secs, v.max_s });
    if (f.width < v.min_w or f.height < v.min_h) return withPair(a, stem, .invalid, jp, p, "too small ({d}x{d}, minimum {d}x{d})", .{ f.width, f.height, v.min_w, v.min_h });
    // the text must be buildable: label present, limits respected
    _ = text_mod.build(a, .{ .hooks = p.hooks, .description = p.description, .hashtags = p.hashtags, .listing_url = p.listing_url, .ai_notice = p.ai_notice }, cx.cfg.post) catch |e| switch (e) {
        error.NoNotice => return withPair(a, stem, .invalid, jp, p, "json has no ai_notice: every post must carry the AI label", .{}),
        error.NoTitle => return withPair(a, stem, .invalid, jp, p, "json has no hooks and no description: no first line for the caption", .{}),
        error.TooLong => return withPair(a, stem, .invalid, jp, p, "hook + ai_notice are longer than post.caption_max: nothing may be cut", .{}),
        error.OutOfMemory => return error.OutOfMemory,
    };
    var note: std.ArrayList(u8) = .empty;
    if (v.want_faststart and !f.faststart) try note.appendSlice(a, "mp4 index is after the data (no fast start: weaker inline streaming); ");
    if (p.width != 0 and (p.width != f.width or p.height != f.height)) try note.print(a, "json says {d}x{d}, file says {d}x{d}; ", .{ p.width, p.height, f.width, f.height });
    try note.appendSlice(a, "codec (H.264/AAC advised) and fps come from the json, not probed");
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
    // not ready: too long (a wide video is fine for Telegram), missing mp4, bad json, label missing, markers, traversal, no car
    try t.put(a, "wide.json", try goodJson(a, "w", "2026-11-03", ""));
    try t.put(a, "wide.mp4", try probe_mod.testMp4(a, 1920, 1080, 15, true));
    try t.put(a, "long.json", try goodJson(a, "l", "2026-11-03", ""));
    try t.put(a, "long.mp4", try probe_mod.testMp4(a, 1080, 1920, 200, true));
    try t.put(a, "nomp4.json", try goodJson(a, "n", "2026-11-03", ""));
    try t.put(a, "broken.json", "{not json");
    try t.put(a, "nolabel.json", "{\"car\":\"x\",\"template\":\"t\",\"hooks\":[\"h\"],\"ai_notice\":\"\"}");
    try t.put(a, "nolabel.mp4", good);
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
    try std.testing.expect(seen.get("wide").? == .ready and seen.get("long").? == .invalid and seen.get("nomp4").? == .invalid);
    try std.testing.expect(seen.get("broken").? == .invalid and seen.get("nolabel").? == .invalid and seen.get("trav").? == .invalid and seen.get("nocar").? == .invalid);
    try std.testing.expect(seen.get("rej").? == .rejected and seen.get("stl").? == .stale);
    // oldest first among the ready ones
    var first_ready: []const u8 = "";
    for (items) |i| if (i.status == .ready) {
        first_ready = i.name;
        break;
    };
    try std.testing.expectEqualStrings("a-old", first_ready);
    for (items) |i| {
        if (std.mem.eql(u8, i.name, "long")) try std.testing.expect(std.mem.indexOf(u8, i.reason, "too long") != null);
        if (std.mem.eql(u8, i.name, "nolabel")) try std.testing.expect(std.mem.indexOf(u8, i.reason, "ai_notice") != null);
        if (std.mem.eql(u8, i.name, "a-old")) try std.testing.expectEqualStrings("car1:t1:tele-short", i.pkey);
    }
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
