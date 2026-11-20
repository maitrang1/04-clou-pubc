// Reads the producer's hand-off folder (read-only!) and judges every <name>.json + <name>.mp4 pair: ready / invalid / skipped / done. A bad pair is skipped with a plain reason, never published.
const std = @import("std");
const Io = std.Io;
const Ctx = @import("co-ctx.zig").Ctx;
const cfgm = @import("co-cfg.zig");
const probe = @import("rw-probe.zig");
const send = @import("rw-send.zig");
const slot = @import("rw-slot.zig");
const sq = @import("rw-sqlite.zig");

const CF = .{ .plat = "face-shor", .day_ms = 24 * 3600 * 1000, .json_cap = 256 * 1024, .aspect_w = 9, .aspect_h = 16 };

pub const Json = struct {
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
    plates: []const u8 = "",
    made_at: []const u8 = "",
    listing_url: []const u8 = "",
    brand: std.json.Value = .null,
    model: std.json.Value = .null,
    year: std.json.Value = .null,
    title: std.json.Value = .null,
};

fn valStr(v: std.json.Value) []const u8 {
    return switch (v) {
        .string => |s| s,
        else => "",
    };
}

pub fn valYear(v: std.json.Value) u32 {
    return switch (v) {
        .integer => |n| if (n > 0 and n < 3000) @intCast(n) else 0,
        .float => |f| if (f > 0 and f < 3000) @intFromFloat(f) else 0,
        .string => |s| std.fmt.parseInt(u32, std.mem.trim(u8, s, " "), 10) catch 0,
        else => 0,
    };
}

pub fn titleOf(j: Json) []const u8 {
    return valStr(j.title);
}
pub fn brandOf(j: Json) []const u8 {
    return valStr(j.brand);
}
pub fn modelOf(j: Json) []const u8 {
    return valStr(j.model);
}
pub const Kind = enum { ready, invalid, skipped, done };
pub const Entry = struct {
    name: []const u8,
    kind: Kind,
    reason: []const u8 = "",
    note: []const u8 = "", // e.g. "fps not in file, json trusted"
    pkey: []const u8 = "",
    j: Json = .{},
    mp4_path: []const u8 = "",
    size: u64 = 0,
    mtime_ms: i64 = 0, // json mtime
    mp4_mtime_ms: i64 = 0,
    retry: bool = false, // a failed send that never got a video id: goes again by itself, up to limits.retry_max times
};

pub fn pkeyOf(a: std.mem.Allocator, j: Json) ![]u8 {
    return std.fmt.allocPrint(a, "{s}:{s}:{s}", .{ j.car, j.template, CF.plat });
}

pub const Verdict = struct { reason: ?[]const u8 = null, note: []const u8 = "" };

// plain-language check against the Reels spec (values from config). null reason = fine.
pub fn validate(a: std.mem.Allocator, v: cfgm.Video, f: probe.Facts, j: Json) !Verdict {
    var notes: std.ArrayList(u8) = .empty;
    const secs = f.seconds orelse blk: {
        try notes.appendSlice(a, "length not in file, json trusted; ");
        break :blk j.seconds;
    };
    const w = f.width orelse blk: {
        try notes.appendSlice(a, "size not in file, json trusted; ");
        break :blk j.width;
    };
    const h = f.height orelse j.height;
    if (secs < @as(f64, @floatFromInt(v.min_s))) return .{ .reason = try std.fmt.allocPrint(a, "too short: {d:.1} s (min {d})", .{ secs, v.min_s }) };
    if (secs > @as(f64, @floatFromInt(v.max_s)) + 0.05) return .{ .reason = try std.fmt.allocPrint(a, "too long: {d:.1} s (max {d})", .{ secs, v.max_s }) };
    if (w == 0 or h == 0) return .{ .reason = "size unknown (not in the mp4 or the json)" };
    if (w < v.min_w or h < v.min_h) return .{ .reason = try std.fmt.allocPrint(a, "too small: {d}x{d} (min {d}x{d})", .{ w, h, v.min_w, v.min_h }) };
    if (h < w or @as(u64, w) * CF.aspect_h < @as(u64, h) * CF.aspect_w) return .{ .reason = try std.fmt.allocPrint(a, "wrong shape: {d}x{d} is not between 9:16 and square", .{ w, h }) };
    if (f.fps) |fps| {
        if (fps < @as(f64, @floatFromInt(v.fps_min)) - 0.5 or fps > @as(f64, @floatFromInt(v.fps_max)) + 0.5) return .{ .reason = try std.fmt.allocPrint(a, "frame rate {d:.1} outside {d}-{d}", .{ fps, v.fps_min, v.fps_max }) };
    } else try notes.appendSlice(a, "fps unknown; ");
    if (v.vcodec.len > 0) {
        if (f.vcodec.len == 0) try notes.appendSlice(a, "video codec unknown; ") else if (!std.mem.eql(u8, f.vcodec, v.vcodec)) return .{ .reason = try std.fmt.allocPrint(a, "video codec {s} (need {s})", .{ f.vcodec, v.vcodec }) };
    }
    if (v.acodec.len > 0 and std.mem.eql(u8, f.source, "json")) {
        try notes.appendSlice(a, "audio unknown; ");
    } else if (v.acodec.len > 0) {
        if (!f.has_audio) return .{ .reason = "no audio track" };
        if (!std.mem.eql(u8, f.acodec, v.acodec)) return .{ .reason = try std.fmt.allocPrint(a, "audio codec {s} (need {s})", .{ f.acodec, v.acodec }) };
        if (f.channels) |c| if (c != v.audio_channels) return .{ .reason = try std.fmt.allocPrint(a, "audio has {d} channels (need {d})", .{ c, v.audio_channels }) };
        if (f.rate) |r| if (r != v.audio_rate) return .{ .reason = try std.fmt.allocPrint(a, "audio rate {d} Hz (need {d})", .{ r, v.audio_rate }) };
    }
    return .{ .note = std.mem.trimEnd(u8, notes.items, "; ") };
}

fn v_below(v: cfgm.Video, f: probe.Facts, j: Json) bool {
    const w = f.width orelse j.width;
    const h = f.height orelse j.height;
    return w > 0 and h > 0 and (w < v.rec_w or h < v.rec_h);
}

fn bareName(s: []const u8) bool {
    if (s.len == 0 or std.mem.indexOfAny(u8, s, "/\\") != null or std.mem.indexOf(u8, s, "..") != null or s[0] == '.') return false;
    return std.ascii.endsWithIgnoreCase(s, ".mp4");
}

fn entryFor(cx: *const Ctx, a: std.mem.Allocator, dir: Io.Dir, dir_path: []const u8, jname: []const u8, mtime: i64, db: ?*sq.Db) !Entry {
    const name = jname[0 .. jname.len - 5];
    var e = Entry{ .name = try a.dupe(u8, name), .kind = .invalid, .mtime_ms = mtime };
    const rej = try std.fmt.allocPrint(a, "{s}.rejected", .{name});
    const stl = try std.fmt.allocPrint(a, "{s}.stale", .{name});
    if (dir.access(cx.io, rej, .{})) |_| {
        e.kind = .skipped;
        e.reason = "rejected by a person";
        return e;
    } else |_| {}
    if (dir.access(cx.io, stl, .{})) |_| {
        e.kind = .skipped;
        e.reason = "being re-rendered (stale)";
        return e;
    } else |_| {}
    const text = dir.readFileAlloc(cx.io, jname, a, .limited(CF.json_cap)) catch {
        e.reason = "json unreadable";
        return e;
    };
    const j = std.json.parseFromSliceLeaky(Json, a, text, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch |er| {
        e.reason = try std.fmt.allocPrint(a, "json invalid: {s}", .{@errorName(er)});
        return e;
    };
    e.j = j;
    if (j.car.len == 0 or j.template.len == 0) {
        e.reason = "json has no car or template";
        return e;
    }
    e.pkey = try pkeyOf(a, j);
    if (!bareName(j.mp4)) {
        e.reason = "json mp4 must be a plain .mp4 file name";
        return e;
    }
    if (!std.mem.eql(u8, j.mp4[0 .. j.mp4.len - 4], name)) {
        e.reason = "json mp4 must be <name>.mp4 (same name as the json)";
        return e;
    }
    const st = dir.statFile(cx.io, j.mp4, .{}) catch {
        e.reason = "mp4 missing beside the json";
        return e;
    };
    e.size = st.size;
    e.mp4_mtime_ms = st.mtime.toMilliseconds();
    e.mp4_path = try std.fmt.allocPrint(a, "{s}/{s}", .{ std.mem.trimEnd(u8, dir_path, "/"), j.mp4 });
    if (st.size == 0) {
        e.reason = "mp4 is empty";
        return e;
    }
    if (st.size > @as(u64, cx.cfg.video.max_mb) * 1024 * 1024) {
        e.reason = try std.fmt.allocPrint(a, "mp4 is {d} MB (max {d})", .{ st.size / (1024 * 1024), cx.cfg.video.max_mb });
        return e;
    }
    if (db) |d| if (try send.byPkey(d, a, e.pkey)) |row| { // already sent: no need to probe it again
        if (row.state == .failed and row.video_id.len == 0 and row.attempts <= cx.cfg.limits.retry_max) {
            e.retry = true; // never started an upload: checked again below, sent after the fresh ones
        } else {
            e.kind = .done;
            e.reason = send.stateName(row.state);
            return e;
        }
    };
    if (slot.tooOld(cx.nowMs(), e.mp4_mtime_ms, cx.cfg.source.max_age_h)) { // made too long ago: left alone, never deleted
        e.kind = .skipped;
        e.reason = try std.fmt.allocPrint(a, "older than {d} h (source.max_age_h)", .{cx.cfg.source.max_age_h});
        return e;
    }
    const facts = probe.probe(a, cx.io, cx.cfg.video.probe_tool, e.mp4_path) catch |er| blk: {
        if (cx.cfg.video.probe_tool.len == 0 or er != error.ToolMissing) {
            e.reason = try std.fmt.allocPrint(a, "mp4 not readable ({s})", .{@errorName(er)});
            return e;
        }
        break :blk probe.Facts{ .source = "json" };
    };
    const vd = try validate(a, cx.cfg.video, facts, j);
    e.note = vd.note;
    if (vd.reason) |r| {
        e.reason = r;
        return e;
    }
    e.kind = .ready;
    if (v_below(cx.cfg.video, facts, j)) e.note = try std.fmt.allocPrint(a, "{s}{s}below the recommended {d}x{d}", .{ e.note, if (e.note.len > 0) "; " else "", cx.cfg.video.rec_w, cx.cfg.video.rec_h });
    return e;
}

fn madeMs(e: Entry) i64 {
    return if (e.mp4_mtime_ms != 0) e.mp4_mtime_ms else e.mtime_ms;
}

const Ord = struct { tz: i32, hours: []const u8 };

fn slotOrder(o: Ord, x: Entry, y: Entry) bool {
    return slot.before(o.tz, o.hours, .{ .made_ms = madeMs(x), .name = x.name }, .{ .made_ms = madeMs(y), .name = y.name });
}

// read-only walk of source.dir; best first = newest slot, oldest video inside it (rw-slot)
pub fn scan(cx: *const Ctx, a: std.mem.Allocator, db: ?*sq.Db) ![]Entry {
    if (cx.cfg.source.dir.len == 0) return error.NoSourceDir;
    const dp = try cx.path(a, cx.cfg.source.dir);
    var dir = Io.Dir.cwd().openDir(cx.io, dp, .{ .iterate = true }) catch return error.NoSourceDir;
    defer dir.close(cx.io);
    var out: std.ArrayList(Entry) = .empty;
    var it = dir.iterate();
    while (try it.next(cx.io)) |e| {
        if (e.kind != .file or !std.ascii.endsWithIgnoreCase(e.name, ".json") or e.name.len <= 5) continue;
        const st = dir.statFile(cx.io, e.name, .{}) catch continue;
        try out.append(a, try entryFor(cx, a, dir, dp, e.name, st.mtime.toMilliseconds(), db));
    }
    std.mem.sort(Entry, out.items, Ord{ .tz = cx.cfg.tz_offset_hours, .hours = cx.cfg.source.slot_hours }, slotOrder);
    return out.items;
}

pub fn find(entries: []const Entry, name: []const u8) ?Entry {
    for (entries) |e| if (std.mem.eql(u8, e.name, name)) return e;
    return null;
}

// ---- tests ----
const mp4 = @import("te-mp4.zig");
const ctxm = @import("co-ctx.zig");

fn put(io: Io, dir: []const u8, a: std.mem.Allocator, name: []const u8, body: []const u8) !void {
    const p = try std.fmt.allocPrint(a, "{s}/{s}", .{ dir, name });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = p, .data = body });
}

test "every verdict: ready invalid skipped done, source folder untouched; review:true is ignored" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var t = try send.testDb(a, &env, &tmp.sub_path);
    defer t.db.close();
    var cx = t.cx;
    const src = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/src", .{&tmp.sub_path});
    try Io.Dir.cwd().createDirPath(cx.io, src);
    cx.cfg.source.dir = src;
    cx.fake_now_ms = 0; // real clock: files just written
    const io = cx.io;
    // good, review-flagged, bad size, missing mp4, rejected, stale, bad json, traversal, already sent
    const good = "{\"car\":\"c1\",\"template\":\"t\",\"mp4\":\"good.mp4\",\"ai_notice\":\"AI\"}";
    try mp4.write(a, io, try std.fmt.allocPrint(a, "{s}/good.mp4", .{src}), .{});
    try put(io, src, a, "good.json", good);
    try mp4.write(a, io, try std.fmt.allocPrint(a, "{s}/held.mp4", .{src}), .{});
    try put(io, src, a, "held.json", "{\"car\":\"c2\",\"template\":\"t\",\"mp4\":\"held.mp4\",\"review\":true}");
    try mp4.write(a, io, try std.fmt.allocPrint(a, "{s}/tiny.mp4", .{src}), .{ .w = 320, .h = 568 });
    try put(io, src, a, "tiny.json", "{\"car\":\"c3\",\"template\":\"t\",\"mp4\":\"tiny.mp4\"}");
    try put(io, src, a, "nomp4.json", "{\"car\":\"c4\",\"template\":\"t\",\"mp4\":\"gone.mp4\"}");
    try mp4.write(a, io, try std.fmt.allocPrint(a, "{s}/rej.mp4", .{src}), .{});
    try put(io, src, a, "rej.json", "{\"car\":\"c5\",\"template\":\"t\",\"mp4\":\"rej.mp4\"}");
    try put(io, src, a, "rej.rejected", "");
    try mp4.write(a, io, try std.fmt.allocPrint(a, "{s}/stl.mp4", .{src}), .{});
    try put(io, src, a, "stl.json", "{\"car\":\"c6\",\"template\":\"t\",\"mp4\":\"stl.mp4\"}");
    try put(io, src, a, "stl.stale", "");
    try put(io, src, a, "bad.json", "{not json");
    try put(io, src, a, "evil.json", "{\"car\":\"c7\",\"template\":\"t\",\"mp4\":\"../x.mp4\"}");
    try mp4.write(a, io, try std.fmt.allocPrint(a, "{s}/sent.mp4", .{src}), .{});
    try put(io, src, a, "sent.json", "{\"car\":\"c8\",\"template\":\"t\",\"mp4\":\"sent.mp4\"}");
    _ = try send.begin(&cx, &t.db, a, "sent", "c8:t:face-shor", "1", false);
    const es = try scan(&cx, a, &t.db);
    try std.testing.expectEqual(Kind.ready, find(es, "good").?.kind);
    try std.testing.expectEqual(Kind.ready, find(es, "held").?.kind); // review:true changes nothing
    try std.testing.expectEqual(Kind.invalid, find(es, "tiny").?.kind);
    try std.testing.expect(std.mem.indexOf(u8, find(es, "tiny").?.reason, "too small") != null);
    try std.testing.expectEqual(Kind.invalid, find(es, "nomp4").?.kind);
    try std.testing.expectEqual(Kind.skipped, find(es, "rej").?.kind);
    try std.testing.expectEqual(Kind.skipped, find(es, "stl").?.kind);
    try std.testing.expectEqual(Kind.invalid, find(es, "bad").?.kind);
    try std.testing.expectEqual(Kind.invalid, find(es, "evil").?.kind);
    try std.testing.expectEqual(Kind.done, find(es, "sent").?.kind);
    try std.testing.expectEqualStrings("sending", find(es, "sent").?.reason);
    // read-only: no file in the source folder changed or appeared
    var dir = try Io.Dir.cwd().openDir(io, src, .{ .iterate = true });
    defer dir.close(io);
    var n: usize = 0;
    var itr = dir.iterate();
    while (try itr.next(io)) |_| n += 1;
    try std.testing.expectEqual(@as(usize, 17), n);
}

test "scan order: newest slot first, oldest inside it; too old is skipped" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var t = try send.testDb(a, &env, &tmp.sub_path);
    defer t.db.close();
    var cx = t.cx;
    const src = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/src", .{&tmp.sub_path});
    try Io.Dir.cwd().createDirPath(cx.io, src);
    cx.cfg.source.dir = src;
    const io = cx.io;
    for ([_][]const u8{ "a", "b", "c" }) |n| {
        try mp4.write(a, io, try std.fmt.allocPrint(a, "{s}/{s}.mp4", .{ src, n }), .{});
        try put(io, src, a, try std.fmt.allocPrint(a, "{s}.json", .{n}), try std.fmt.allocPrint(a, "{{\"car\":\"{s}\",\"template\":\"t\",\"mp4\":\"{s}.mp4\"}}", .{ n, n }));
    }
    cx.fake_now_ms = 0;
    cx.cfg.source.max_age_h = 0;
    const es = try scan(&cx, a, &t.db);
    try std.testing.expectEqual(@as(usize, 3), es.len);
    for (es) |e| try std.testing.expectEqual(Kind.ready, e.kind);
    cx.cfg.source.max_age_h = 48;
    cx.fake_now_ms = std.Io.Timestamp.now(io, .real).toMilliseconds() + 3 * 24 * 3600 * 1000;
    const es2 = try scan(&cx, a, &t.db);
    for (es2) |e| {
        try std.testing.expectEqual(Kind.skipped, e.kind);
        try std.testing.expect(std.mem.indexOf(u8, e.reason, "max_age_h") != null);
    }
}

test "spec checks: length, shape, fps, codecs, audio" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = cfgm.Video{};
    const ok = probe.Facts{ .seconds = 30, .width = 1080, .height = 1920, .fps = 30, .vcodec = "avc1", .acodec = "mp4a", .channels = 2, .rate = 48000, .has_audio = true };
    try std.testing.expect((try validate(a, v, ok, .{})).reason == null);
    var f = ok;
    f.seconds = 2;
    try std.testing.expect(std.mem.indexOf(u8, (try validate(a, v, f, .{})).reason.?, "too short") != null);
    f.seconds = 91;
    try std.testing.expect(std.mem.indexOf(u8, (try validate(a, v, f, .{})).reason.?, "too long") != null);
    f = ok;
    f.width = 1920;
    f.height = 1080;
    try std.testing.expect(std.mem.indexOf(u8, (try validate(a, v, f, .{})).reason.?, "wrong shape") != null);
    f = ok;
    f.fps = 12;
    try std.testing.expect(std.mem.indexOf(u8, (try validate(a, v, f, .{})).reason.?, "frame rate") != null);
    f = ok;
    f.vcodec = "hvc1";
    try std.testing.expect(std.mem.indexOf(u8, (try validate(a, v, f, .{})).reason.?, "video codec") != null);
    f = ok;
    f.has_audio = false;
    try std.testing.expect(std.mem.indexOf(u8, (try validate(a, v, f, .{})).reason.?, "no audio") != null);
    f = ok;
    f.rate = 44100;
    try std.testing.expect(std.mem.indexOf(u8, (try validate(a, v, f, .{})).reason.?, "44100") != null);
    // unknown facts fall back to the json and say so
    const unk = probe.Facts{ .source = "json" };
    const r = try validate(a, v, unk, .{ .seconds = 20, .width = 1080, .height = 1920 });
    try std.testing.expect(r.reason == null);
    try std.testing.expect(std.mem.indexOf(u8, r.note, "json trusted") != null);
}
