// Reads the producer's hand-off folder (read-only!) and judges every <name>.json + <name>.mp4 pair: ready / held / invalid / skipped / done. A bad pair is skipped with a plain reason, never published.
const std = @import("std");
const Io = std.Io;
const Ctx = @import("co-ctx.zig").Ctx;
const cfgm = @import("co-cfg.zig");
const probe = @import("rw-probe.zig");
const send = @import("rw-send.zig");
const sq = @import("rw-sqlite.zig");

const CF = .{ .plat = "inst-shor", .day_ms = 24 * 3600 * 1000, .json_cap = 256 * 1024 };

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
    review: bool = false,
    plates: []const u8 = "",
    made_at: []const u8 = "",
    listing_url: []const u8 = "",
};
pub const Kind = enum { ready, held, invalid, skipped, done };
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

// what a person approved: this exact file (size + mtime). A re-render under the same name needs a new approval.
pub fn approvalSig(a: std.mem.Allocator, e: Entry) ![]u8 {
    return std.fmt.allocPrint(a, "approved:{d}:{d}", .{ e.size, e.mp4_mtime_ms });
}

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
    if (w > v.max_w) return .{ .reason = try std.fmt.allocPrint(a, "too wide: {d} px (Instagram max {d})", .{ w, v.max_w }) };
    const want = @as(u64, h) * v.aspect_w;
    const have = @as(u64, w) * v.aspect_h;
    const diff = if (want > have) want - have else have - want;
    if (diff * 100 > want * v.aspect_tol_pct) return .{ .reason = try std.fmt.allocPrint(a, "wrong shape: {d}x{d} is not {d}:{d} (tolerance {d}%)", .{ w, h, v.aspect_w, v.aspect_h, v.aspect_tol_pct }) };
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
        if (f.channels) |c| if (c < 1 or c > v.audio_channels_max) return .{ .reason = try std.fmt.allocPrint(a, "audio has {d} channels (need 1..{d})", .{ c, v.audio_channels_max }) };
        if (f.rate) |r| if (r > v.audio_rate_max) return .{ .reason = try std.fmt.allocPrint(a, "audio rate {d} Hz (max {d})", .{ r, v.audio_rate_max }) };
    }
    if (f.faststart) |fs| {
        if (!fs) return .{ .reason = "moov atom is after the video data: Instagram needs it at the front (producer: re-mux with -movflags +faststart)" };
    } else try notes.appendSlice(a, "moov position unknown; ");
    if (f.edit_list) |el| {
        if (el) return .{ .reason = "the mp4 has edit lists (edts): Instagram refuses them (producer: re-mux without edit lists)" };
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

fn entryFor(cx: *const Ctx, a: std.mem.Allocator, dir: Io.Dir, dir_path: []const u8, jname: []const u8, mtime: i64, db: ?*sq.Db, skip_done: bool) !Entry {
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
    if (!skip_done) if (db) |d| if (try send.byPkey(d, a, e.pkey)) |row| { // already sent: no need to probe it again
        e.kind = .done;
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
    const vd = try validate(a, cx.cfg.video, facts, j);
    e.note = vd.note;
    if (vd.reason) |r| {
        e.reason = r;
        return e;
    }
    e.kind = .ready;
    if (v_below(cx.cfg.video, facts, j)) e.note = try std.fmt.allocPrint(a, "{s}{s}below the recommended {d}x{d}", .{ e.note, if (e.note.len > 0) "; " else "", cx.cfg.video.rec_w, cx.cfg.video.rec_h });
    if (j.review and cx.cfg.approval.require_for_review) {
        var ok = false;
        if (db) |d| ok = std.mem.eql(u8, try send.approval(d, a, e.name), try approvalSig(a, e));
        if (!ok) {
            e.kind = .held;
            e.reason = "review:true, waiting for a person (approve)";
        }
    }
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
        try out.append(a, try entryFor(cx, a, dir, dp, e.name, st.mtime.toMilliseconds(), db, false));
    }
    std.mem.sort(Entry, out.items, {}, older);
    return out.items;
}

// one pair judged from scratch: the "already sent" shortcut is skipped (used before a person-approved retry)
pub fn scanOne(cx: *const Ctx, a: std.mem.Allocator, db: ?*sq.Db, name: []const u8) !Entry {
    if (cx.cfg.source.dir.len == 0) return error.NoSourceDir;
    const dp = try cx.path(a, cx.cfg.source.dir);
    var dir = Io.Dir.cwd().openDir(cx.io, dp, .{ .iterate = true }) catch return error.NoSourceDir;
    defer dir.close(cx.io);
    const jn = try std.fmt.allocPrint(a, "{s}.json", .{name});
    const st = try dir.statFile(cx.io, jn, .{});
    return entryFor(cx, a, dir, dp, jn, st.mtime.toMilliseconds(), db, true);
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

test "every verdict: ready held invalid skipped done, source folder untouched" {
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
    // good, held, bad size, missing mp4, rejected, stale, bad json, traversal, already sent
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
    _ = try send.begin(&cx, &t.db, a, "sent", "c8:t:inst-shor", "1", false);
    const es = try scan(&cx, a, &t.db);
    try std.testing.expectEqual(Kind.ready, find(es, "good").?.kind);
    try std.testing.expectEqual(Kind.held, find(es, "held").?.kind);
    try std.testing.expectEqual(Kind.invalid, find(es, "tiny").?.kind);
    try std.testing.expect(std.mem.indexOf(u8, find(es, "tiny").?.reason, "too small") != null);
    try std.testing.expectEqual(Kind.invalid, find(es, "nomp4").?.kind);
    try std.testing.expectEqual(Kind.skipped, find(es, "rej").?.kind);
    try std.testing.expectEqual(Kind.skipped, find(es, "stl").?.kind);
    try std.testing.expectEqual(Kind.invalid, find(es, "bad").?.kind);
    try std.testing.expectEqual(Kind.invalid, find(es, "evil").?.kind);
    try std.testing.expectEqual(Kind.done, find(es, "sent").?.kind);
    try std.testing.expectEqualStrings("sending", find(es, "sent").?.reason);
    // approving a held pair makes it ready
    try send.setApproval(&cx, &t.db, "held", try approvalSig(a, find(es, "held").?));
    const es2 = try scan(&cx, a, &t.db);
    try std.testing.expectEqual(Kind.ready, find(es2, "held").?.kind);
    // read-only: no file in the source folder changed or appeared
    var dir = try Io.Dir.cwd().openDir(io, src, .{ .iterate = true });
    defer dir.close(io);
    var n: usize = 0;
    var itr = dir.iterate();
    while (try itr.next(io)) |_| n += 1;
    try std.testing.expectEqual(@as(usize, 17), n);
}

test "spec checks: length, shape, fps, codecs, audio" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = cfgm.Video{};
    const ok = probe.Facts{ .seconds = 30, .width = 1080, .height = 1920, .fps = 30, .vcodec = "avc1", .acodec = "mp4a", .channels = 2, .rate = 48000, .has_audio = true, .faststart = true, .edit_list = false };
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
    f.fps = 23.976; // 23 is the Instagram floor
    try std.testing.expect((try validate(a, v, f, .{})).reason == null);
    f = ok;
    f.vcodec = "hvc1";
    try std.testing.expect(std.mem.indexOf(u8, (try validate(a, v, f, .{})).reason.?, "video codec") != null);
    f = ok;
    f.has_audio = false;
    try std.testing.expect(std.mem.indexOf(u8, (try validate(a, v, f, .{})).reason.?, "no audio") != null);
    f = ok;
    f.rate = 96000;
    try std.testing.expect(std.mem.indexOf(u8, (try validate(a, v, f, .{})).reason.?, "96000") != null);
    f = ok;
    f.rate = 44100; // anything up to 48 kHz is fine
    try std.testing.expect((try validate(a, v, f, .{})).reason == null);
    f = ok;
    f.channels = 1; // mono is fine, 6 channels is not
    try std.testing.expect((try validate(a, v, f, .{})).reason == null);
    f.channels = 6;
    try std.testing.expect(std.mem.indexOf(u8, (try validate(a, v, f, .{})).reason.?, "channels") != null);
    f = ok;
    f.width = 2160;
    f.height = 3840;
    try std.testing.expect(std.mem.indexOf(u8, (try validate(a, v, f, .{})).reason.?, "too wide") != null);
    f = ok;
    f.faststart = false;
    try std.testing.expect(std.mem.indexOf(u8, (try validate(a, v, f, .{})).reason.?, "moov") != null);
    f = ok;
    f.faststart = true;
    f.edit_list = true;
    try std.testing.expect(std.mem.indexOf(u8, (try validate(a, v, f, .{})).reason.?, "edit lists") != null);
    f = ok;
    f.width = 1080;
    f.height = 1800; // near 9:16 but outside the 2% tolerance
    try std.testing.expect(std.mem.indexOf(u8, (try validate(a, v, f, .{})).reason.?, "wrong shape") != null);
    // unknown facts fall back to the json and say so
    const unk = probe.Facts{ .source = "json" };
    const r = try validate(a, v, unk, .{ .seconds = 20, .width = 1080, .height = 1920 });
    try std.testing.expect(r.reason == null);
    try std.testing.expect(std.mem.indexOf(u8, r.note, "json trusted") != null);
}
