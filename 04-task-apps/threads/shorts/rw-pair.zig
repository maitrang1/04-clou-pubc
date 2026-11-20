// Reads the producer's hand-off folder (read-only!) and judges every <name>.json + <name>.mp4 pair: ready / pending / invalid / skipped / done.
// A bad pair is skipped with a plain reason, never published. `pending` = a ledger row that is still before the publish request (sending) or finished-but-not-published (staged).
const std = @import("std");
const Io = std.Io;
const Ctx = @import("co-ctx.zig").Ctx;
const cfgm = @import("co-cfg.zig");
const probe = @import("rw-probe.zig");
const send = @import("rw-send.zig");
const sq = @import("rw-sqlite.zig");

const CF = .{ .plat = "thre-shor", .day_ms = 24 * 3600 * 1000, .json_cap = 256 * 1024 };

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
};
pub const Kind = enum { ready, pending, invalid, skipped, done };
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
};

pub fn pkeyOf(a: std.mem.Allocator, j: Json) ![]u8 {
    return std.fmt.allocPrint(a, "{s}:{s}:{s}", .{ j.car, j.template, CF.plat });
}

pub const Verdict = struct { reason: ?[]const u8 = null, note: []const u8 = "" };

fn addNote(a: std.mem.Allocator, notes: *std.ArrayList(u8), s: []const u8) !void {
    try notes.appendSlice(a, s);
    try notes.appendSlice(a, "; ");
}

// plain-language check against the Threads video spec (values from config). null reason = fine.
pub fn validate(a: std.mem.Allocator, v: cfgm.Video, f: probe.Facts, j: Json, size: u64) !Verdict {
    var notes: std.ArrayList(u8) = .empty;
    const secs = f.seconds orelse blk: {
        try addNote(a, &notes, "length not in file, json trusted");
        break :blk j.seconds;
    };
    const w = f.width orelse blk: {
        try addNote(a, &notes, "size not in file, json trusted");
        break :blk j.width;
    };
    const h = f.height orelse j.height;
    if (secs < @as(f64, @floatFromInt(v.min_s))) return .{ .reason = try std.fmt.allocPrint(a, "too short: {d:.1} s (min {d})", .{ secs, v.min_s }) };
    if (secs > @as(f64, @floatFromInt(v.max_s)) + 0.05) return .{ .reason = try std.fmt.allocPrint(a, "too long: {d:.1} s (max {d})", .{ secs, v.max_s }) };
    if (w == 0 or h == 0) return .{ .reason = "size unknown (not in the mp4 or the json)" };
    if (w > v.max_w) return .{ .reason = try std.fmt.allocPrint(a, "too wide: {d} px (max {d})", .{ w, v.max_w }) };
    if (@as(u64, w) * 100 < h or w > @as(u64, h) * 10) return .{ .reason = try std.fmt.allocPrint(a, "wrong shape: {d}x{d} is outside 0.01:1 to 10:1", .{ w, h }) };
    const diff: u64 = if (@as(u64, w) * 16 > @as(u64, h) * 9) @as(u64, w) * 16 - @as(u64, h) * 9 else @as(u64, h) * 9 - @as(u64, w) * 16;
    if (diff * 50 > @as(u64, h) * 9) try addNote(a, &notes, "not 9:16: Threads may crop or add bars");
    if (f.fps) |fps| {
        if (fps < @as(f64, @floatFromInt(v.fps_min)) - 0.5 or fps > @as(f64, @floatFromInt(v.fps_max)) + 0.5) return .{ .reason = try std.fmt.allocPrint(a, "frame rate {d:.1} outside {d}-{d}", .{ fps, v.fps_min, v.fps_max }) };
    } else try addNote(a, &notes, "fps unknown");
    if (f.vcodec.len == 0) {
        try addNote(a, &notes, "video codec unknown");
    } else {
        var okc = false;
        for (v.vcodecs) |c| if (std.mem.eql(u8, f.vcodec, c)) {
            okc = true;
        };
        if (!okc) return .{ .reason = try std.fmt.allocPrint(a, "video codec {s} (need H.264 or HEVC)", .{f.vcodec}) };
    }
    if (std.mem.eql(u8, f.source, "json")) {
        try addNote(a, &notes, "audio unknown");
    } else if (!f.has_audio) {
        try addNote(a, &notes, "no audio track");
    } else {
        if (v.acodec.len > 0 and !std.mem.eql(u8, f.acodec, v.acodec)) return .{ .reason = try std.fmt.allocPrint(a, "audio codec {s} (need AAC)", .{f.acodec}) };
        if (f.channels) |c| if (c == 0 or c > v.audio_channels_max) return .{ .reason = try std.fmt.allocPrint(a, "audio has {d} channels (need mono or stereo)", .{c}) };
        if (f.rate) |r| if (r == 0) try addNote(a, &notes, "audio rate unknown");
        if (f.rate) |r| if (r > v.audio_rate_max) return .{ .reason = try std.fmt.allocPrint(a, "audio rate {d} Hz (max {d})", .{ r, v.audio_rate_max }) };
    }
    if (f.faststart) |fs| {
        if (!fs) return .{ .reason = "moov atom is at the end of the file (not faststart): re-mux with ffmpeg -movflags +faststart" };
    } else try addNote(a, &notes, "faststart unknown");
    if (f.edit_list) |el| {
        if (el) return .{ .reason = "the file has an edit list (Threads refuses it): re-mux without one, e.g. ffmpeg -use_editlist 0" };
    }
    if (secs > 0) {
        const bits: f64 = @as(f64, @floatFromInt(size)) * 8.0;
        if (bits / secs > @as(f64, @floatFromInt(v.max_mbps)) * 1_000_000.0) return .{ .reason = try std.fmt.allocPrint(a, "bit rate about {d:.0} Mbps (max {d})", .{ bits / secs / 1_000_000.0, v.max_mbps }) };
    }
    return .{ .note = std.mem.trimEnd(u8, notes.items, "; ") };
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
    if (cx.cfg.source.max_age_days > 0 and cx.nowMs() - mtime > @as(i64, cx.cfg.source.max_age_days) * CF.day_ms) {
        e.reason = try std.fmt.allocPrint(a, "older than {d} days", .{cx.cfg.source.max_age_days});
        return e;
    }
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
    if (db) |d| if (try send.byPkey(d, a, e.pkey)) |row| { // already in the ledger: no need to probe it again
        e.kind = switch (row.state) {
            .sending, .staged => .pending,
            else => .done,
        };
        e.reason = send.stateName(row.state);
        return e;
    };
    const facts = probe.probe(a, cx.io, cx.cfg.video.probe_tool, e.mp4_path) catch |er| blk: {
        if (cx.cfg.video.probe_tool.len == 0 or er != error.ToolMissing) {
            e.reason = try std.fmt.allocPrint(a, "mp4 not readable ({s})", .{@errorName(er)});
            return e;
        }
        break :blk probe.Facts{ .source = "json" };
    };
    const vd = try validate(a, cx.cfg.video, facts, j, st.size);
    e.note = vd.note;
    if (vd.reason) |r| {
        e.reason = r;
        return e;
    }
    e.kind = .ready;
    return e;
}

fn older(_: void, x: Entry, y: Entry) bool {
    if (x.mtime_ms != y.mtime_ms) return x.mtime_ms < y.mtime_ms;
    return std.mem.lessThan(u8, x.name, y.name);
}

// read-only walk of source.dir; oldest first
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
    std.mem.sort(Entry, out.items, {}, older);
    return out.items;
}

pub fn find(entries: []const Entry, name: []const u8) ?Entry {
    for (entries) |e| if (std.mem.eql(u8, e.name, name)) return e;
    return null;
}

// ---- tests ----
const mp4 = @import("te-mp4.zig");

fn put(io: Io, dir: []const u8, a: std.mem.Allocator, name: []const u8, body: []const u8) !void {
    const p = try std.fmt.allocPrint(a, "{s}/{s}", .{ dir, name });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = p, .data = body });
}

test "every verdict: ready pending invalid skipped done, source folder untouched; review:true is ignored" {
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
    const good = "{\"car\":\"c1\",\"template\":\"t\",\"mp4\":\"good.mp4\",\"ai_notice\":\"AI\"}";
    try mp4.write(a, io, try std.fmt.allocPrint(a, "{s}/good.mp4", .{src}), .{});
    try put(io, src, a, "good.json", good);
    try mp4.write(a, io, try std.fmt.allocPrint(a, "{s}/held.mp4", .{src}), .{});
    try put(io, src, a, "held.json", "{\"car\":\"c2\",\"template\":\"t\",\"mp4\":\"held.mp4\",\"review\":true}");
    try mp4.write(a, io, try std.fmt.allocPrint(a, "{s}/tiny.mp4", .{src}), .{ .seconds = 200 });
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
    const sid = try send.begin(&cx, &t.db, a, "sent", "c8:t:thre-shor", "h");
    try send.setState(&cx, &t.db, sid, .posted, "ok", "1", "");
    try mp4.write(a, io, try std.fmt.allocPrint(a, "{s}/pend.mp4", .{src}), .{});
    try put(io, src, a, "pend.json", "{\"car\":\"c9\",\"template\":\"t\",\"mp4\":\"pend.mp4\"}");
    _ = try send.begin(&cx, &t.db, a, "pend", "c9:t:thre-shor", "h");
    const es = try scan(&cx, a, &t.db);
    try std.testing.expectEqual(Kind.ready, find(es, "good").?.kind);
    try std.testing.expectEqual(Kind.ready, find(es, "held").?.kind); // review:true changes nothing
    try std.testing.expectEqual(Kind.invalid, find(es, "tiny").?.kind);
    try std.testing.expect(std.mem.indexOf(u8, find(es, "tiny").?.reason, "too long") != null);
    try std.testing.expectEqual(Kind.invalid, find(es, "nomp4").?.kind);
    try std.testing.expectEqual(Kind.skipped, find(es, "rej").?.kind);
    try std.testing.expectEqual(Kind.skipped, find(es, "stl").?.kind);
    try std.testing.expectEqual(Kind.invalid, find(es, "bad").?.kind);
    try std.testing.expectEqual(Kind.invalid, find(es, "evil").?.kind);
    try std.testing.expectEqual(Kind.done, find(es, "sent").?.kind);
    try std.testing.expectEqualStrings("posted", find(es, "sent").?.reason);
    try std.testing.expectEqual(Kind.pending, find(es, "pend").?.kind);
    // read-only: no file in the source folder changed or appeared
    var dir = try Io.Dir.cwd().openDir(io, src, .{ .iterate = true });
    defer dir.close(io);
    var n: usize = 0;
    var itr = dir.iterate();
    while (try itr.next(io)) |_| n += 1;
    try std.testing.expectEqual(@as(usize, 19), n);
}

test "Threads spec checks: length, width, shape, fps, codecs, audio, faststart, edit list, bit rate" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = cfgm.Video{};
    const ok = probe.Facts{ .seconds = 30, .width = 1080, .height = 1920, .fps = 30, .vcodec = "avc1", .acodec = "mp4a", .channels = 2, .rate = 48000, .has_audio = true, .faststart = true, .edit_list = false };
    const sz: u64 = 5 * 1024 * 1024;
    try std.testing.expect((try validate(a, v, ok, .{}, sz)).reason == null);
    var f = ok;
    f.seconds = 0.2;
    try std.testing.expect(std.mem.indexOf(u8, (try validate(a, v, f, .{}, sz)).reason.?, "too short") != null);
    f.seconds = 91;
    try std.testing.expect(std.mem.indexOf(u8, (try validate(a, v, f, .{}, sz)).reason.?, "too long") != null);
    f = ok;
    f.width = 2160;
    f.height = 3840;
    try std.testing.expect(std.mem.indexOf(u8, (try validate(a, v, f, .{}, sz)).reason.?, "too wide") != null);
    f = ok;
    f.width = 1000;
    f.height = 200000;
    try std.testing.expect(std.mem.indexOf(u8, (try validate(a, v, f, .{}, sz)).reason.?, "wrong shape") != null);
    f = ok;
    f.width = 1080;
    f.height = 1080; // square: valid, but not 9:16
    const sq_v = try validate(a, v, f, .{}, sz);
    try std.testing.expect(sq_v.reason == null);
    try std.testing.expect(std.mem.indexOf(u8, sq_v.note, "not 9:16") != null);
    f = ok;
    f.fps = 12;
    try std.testing.expect(std.mem.indexOf(u8, (try validate(a, v, f, .{}, sz)).reason.?, "frame rate") != null);
    f = ok;
    f.vcodec = "vp09";
    try std.testing.expect(std.mem.indexOf(u8, (try validate(a, v, f, .{}, sz)).reason.?, "video codec") != null);
    f = ok;
    f.vcodec = "hvc1"; // HEVC is accepted
    try std.testing.expect((try validate(a, v, f, .{}, sz)).reason == null);
    f = ok;
    f.has_audio = false; // silent video: allowed, said so
    try std.testing.expect(std.mem.indexOf(u8, (try validate(a, v, f, .{}, sz)).note, "no audio") != null);
    f = ok;
    f.channels = 6;
    try std.testing.expect(std.mem.indexOf(u8, (try validate(a, v, f, .{}, sz)).reason.?, "channels") != null);
    f = ok;
    f.rate = 96000;
    try std.testing.expect(std.mem.indexOf(u8, (try validate(a, v, f, .{}, sz)).reason.?, "96000") != null);
    f = ok;
    f.faststart = false;
    try std.testing.expect(std.mem.indexOf(u8, (try validate(a, v, f, .{}, sz)).reason.?, "+faststart") != null);
    f = ok;
    f.edit_list = true;
    try std.testing.expect(std.mem.indexOf(u8, (try validate(a, v, f, .{}, sz)).reason.?, "edit list") != null);
    f = ok;
    try std.testing.expect(std.mem.indexOf(u8, (try validate(a, v, f, .{}, 1000 * 1024 * 1024)).reason.?, "bit rate") != null); // ~270 Mbps over 30 s
    // unknown facts fall back to the json and say so
    const unk = probe.Facts{ .source = "json" };
    const r = try validate(a, v, unk, .{ .seconds = 20, .width = 1080, .height = 1920 }, sz);
    try std.testing.expect(r.reason == null);
    try std.testing.expect(std.mem.indexOf(u8, r.note, "json trusted") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.note, "faststart unknown") != null);
}
