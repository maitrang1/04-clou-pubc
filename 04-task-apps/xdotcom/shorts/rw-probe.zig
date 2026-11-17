// =====================================================================
// Des: Reads the facts of an MP4 file with no outside tool - size, duration, width, height, frame rate, the video and audio codec, the AAC profile (LC or not), the channel count, and whether the index (moov) comes before the data (mdat)
// Flo: walk top-level boxes (header reads only) > read moov into memory (capped) > mvhd timescale+duration > per track: handler, stsd codec, mdhd+stts frame rate, mp4a channels, esds AAC object type
// Cre: 2026-11-16                          - | Mod: 2026-11-16
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: io, file path
// Out: Facts {size, ms, width, height, faststart, vcodec, acodec, aac_lc, channels, fps_x100} | error NotMp4 / NoMoov / NoVideo / Cut
// Run: not run directly - imported by rw-pair
// =====================================================================
const std = @import("std");

pub const Err = error{ NotMp4, NoMoov, NoVideo, Cut, OutOfMemory, Read };

// codec fields are fourcc ([4]u8, all zero = not found); aac_lc: null = unknown; fps_x100: 0 = unknown (3000 = 30 fps)
pub const Facts = struct {
    size: u64,
    ms: u64,
    width: u32,
    height: u32,
    faststart: bool,
    vcodec: [4]u8 = @splat(0),
    acodec: [4]u8 = @splat(0),
    aac_lc: ?bool = null,
    channels: u32 = 0,
    fps_x100: u32 = 0,
};

const CF = .{ .moov_cap = 8 * 1024 * 1024 };

fn be32(b: []const u8) u32 {
    return std.mem.readInt(u32, b[0..4], .big);
}
fn be64(b: []const u8) u64 {
    return std.mem.readInt(u64, b[0..8], .big);
}

const Box = struct { kind: [4]u8, start: u64, head: u64, size: u64 }; // size = whole box incl header

// box header at an offset inside a memory slice
fn memBox(buf: []const u8, off: usize) ?Box {
    if (off + 8 > buf.len) return null;
    var size: u64 = be32(buf[off..]);
    var head: u64 = 8;
    if (size == 1) {
        if (off + 16 > buf.len) return null;
        size = be64(buf[off + 8 ..]);
        head = 16;
    } else if (size == 0) size = buf.len - off;
    if (size < head or size > buf.len - off) return null;
    return .{ .kind = buf[off + 4 ..][0..4].*, .start = off, .head = head, .size = size };
}

// find the first child box of a kind inside [from,to) of buf
fn child(buf: []const u8, from: usize, to: usize, kind: *const [4]u8) ?Box {
    var off = from;
    while (off + 8 <= to) {
        const b = memBox(buf[0..to], off) orelse return null;
        if (std.mem.eql(u8, &b.kind, kind)) return b;
        off += @intCast(b.size);
    }
    return null;
}

// stbl box (sample table) of a track's mdia: minf > stbl
fn stblOf(buf: []const u8, m_from: usize, m_to: usize) ?Box {
    const minf = child(buf, m_from, m_to, "minf") orelse return null;
    return child(buf, @intCast(minf.start + minf.head), @intCast(minf.start + minf.size), "stbl");
}

fn stblKid(buf: []const u8, stbl: Box, kind: *const [4]u8) ?Box {
    return child(buf, @intCast(stbl.start + stbl.head), @intCast(stbl.start + stbl.size), kind);
}

// fourcc of the first sample entry in stsd (avc1, hvc1, mp4a ...)
fn entryKind(buf: []const u8, stbl: Box) ?[4]u8 {
    const stsd = stblKid(buf, stbl, "stsd") orelse return null;
    const p: usize = @intCast(stsd.start + stsd.head);
    if (p + 16 > buf.len) return null;
    return buf[p + 12 ..][0..4].*;
}

// frame rate x100 from the video track: stts sample count * mdhd timescale / mdhd duration
fn fpsOf(buf: []const u8, m_from: usize, m_to: usize, stbl: Box) u32 {
    const mdhd = child(buf, m_from, m_to, "mdhd") orelse return 0;
    const mp: usize = @intCast(mdhd.start + mdhd.head);
    if (mp >= buf.len) return 0;
    var ts: u64 = 0;
    var dur: u64 = 0;
    if (buf[mp] == 1) {
        if (mp + 32 > buf.len) return 0;
        ts = be32(buf[mp + 20 ..]);
        dur = be64(buf[mp + 24 ..]);
    } else {
        if (mp + 20 > buf.len) return 0;
        ts = be32(buf[mp + 12 ..]);
        dur = be32(buf[mp + 16 ..]);
    }
    if (ts == 0 or dur == 0) return 0;
    const stts = stblKid(buf, stbl, "stts") orelse return 0;
    const sp: usize = @intCast(stts.start + stts.head);
    if (sp + 8 > buf.len) return 0;
    const n: u64 = be32(buf[sp + 4 ..]);
    var samples: u64 = 0;
    var i: u64 = 0;
    while (i < n) : (i += 1) {
        const at: usize = sp + 8 + @as(usize, @intCast(i)) * 8;
        if (at + 8 > buf.len) return 0;
        samples +|= be32(buf[at..]);
    }
    const x = std.math.mul(u64, samples, ts) catch return 0;
    const y = std.math.mul(u64, x, 100) catch return 0;
    return @intCast(@min(y / dur, std.math.maxInt(u32)));
}

// mp4a entry: channel count, and the AAC object type from esds (2 = LC; 5 / 29 = HE-AAC)
fn audioDetail(buf: []const u8, stbl: Box, channels: *u32, aac_lc: *?bool) void {
    const stsd = stblKid(buf, stbl, "stsd") orelse return;
    const e: usize = @intCast(stsd.start + stsd.head + 8); // first sample entry
    if (e + 36 > buf.len) return;
    channels.* = std.mem.readInt(u16, buf[e + 24 ..][0..2], .big);
    const esize: usize = be32(buf[e..]);
    const eto = @min(buf.len, e + esize);
    const esds = child(buf, e + 36, eto, "esds") orelse return;
    const p: usize = @intCast(esds.start + esds.head + 4);
    const end: usize = @intCast(esds.start + esds.size);
    if (p >= end or end > buf.len) return;
    aac_lc.* = aacLc(buf[p..end]);
}

// walk the MPEG-4 descriptors: 0x03 ES, 0x04 decoder config, 0x05 decoder specific info (first 5 bits = audio object type)
fn aacLc(d: []const u8) ?bool {
    var i: usize = 0;
    while (i < d.len) {
        const tag = d[i];
        i += 1;
        var len: usize = 0;
        var k: usize = 0;
        while (k < 4 and i < d.len) : (k += 1) {
            const b = d[i];
            i += 1;
            len = (len << 7) | (b & 0x7f);
            if (b & 0x80 == 0) break;
        }
        switch (tag) {
            0x03 => {
                if (i + 3 > d.len) return null;
                const fl = d[i + 2];
                i += 3;
                if (fl & 0x80 != 0) i += 2;
                if (fl & 0x40 != 0) {
                    if (i >= d.len) return null;
                    i += 1 + d[i];
                }
                if (fl & 0x20 != 0) i += 2;
            },
            0x04 => i += 13,
            0x05 => {
                if (len == 0 or i >= d.len) return null;
                const aot = d[i] >> 3;
                return aot == 2;
            },
            else => i += len,
        }
    }
    return null;
}

pub fn probe(io: std.Io, a: std.mem.Allocator, path: []const u8) Err!Facts {
    var f = std.Io.Dir.cwd().openFile(io, path, .{}) catch return Err.Read;
    defer f.close(io);
    const total = f.length(io) catch return Err.Read;
    var off: u64 = 0;
    var moov_at: ?u64 = null;
    var moov_size: u64 = 0;
    var mdat_at: ?u64 = null;
    var saw_ftyp = false;
    var hdr: [16]u8 = undefined;
    while (off + 8 <= total) {
        const n = f.readPositionalAll(io, hdr[0..16], off) catch return Err.Read;
        if (n < 8) break;
        var size: u64 = be32(hdr[0..]);
        if (size == 1) {
            if (n < 16) return Err.Cut;
            size = be64(hdr[8..]);
            if (size < 16) return Err.Cut;
        } else if (size == 0) size = total - off;
        const kind = hdr[4..8];
        if (off == 0 and !std.mem.eql(u8, kind, "ftyp")) return Err.NotMp4;
        if (size < 8 or size > total - off) return Err.Cut;
        if (std.mem.eql(u8, kind, "ftyp")) saw_ftyp = true;
        if (std.mem.eql(u8, kind, "moov") and moov_at == null) {
            moov_at = off;
            moov_size = size;
        }
        if (std.mem.eql(u8, kind, "mdat") and mdat_at == null) mdat_at = off;
        off += size;
    }
    if (!saw_ftyp) return Err.NotMp4;
    const mo = moov_at orelse return Err.NoMoov;
    if (moov_size > CF.moov_cap) return Err.Cut;
    const buf = a.alloc(u8, @intCast(moov_size)) catch return Err.OutOfMemory;
    const got = f.readPositionalAll(io, buf, mo) catch return Err.Read;
    if (got != buf.len) return Err.Cut;
    const mb = memBox(buf, 0) orelse return Err.Cut;
    const inner_from: usize = @intCast(mb.head);
    const inner_to: usize = buf.len;
    // duration
    var ms: u64 = 0;
    if (child(buf, inner_from, inner_to, "mvhd")) |h| {
        const p: usize = @intCast(h.start + h.head);
        if (p >= buf.len) return Err.Cut;
        const ver = buf[p];
        var ts: u64 = 0;
        var dur: u64 = 0;
        if (ver == 1) {
            if (p + 32 > buf.len) return Err.Cut;
            ts = be32(buf[p + 20 ..]);
            dur = be64(buf[p + 24 ..]);
        } else {
            if (p + 20 > buf.len) return Err.Cut;
            ts = be32(buf[p + 12 ..]);
            dur = be32(buf[p + 16 ..]);
        }
        if (ts != 0) ms = (std.math.mul(u64, dur, 1000) catch std.math.maxInt(u64)) / ts;
    }
    // tracks: the first video track gives size, codec and frame rate; the first audio track gives codec, channels, AAC profile
    var w: u32 = 0;
    var h: u32 = 0;
    var vcodec: [4]u8 = @splat(0);
    var acodec: [4]u8 = @splat(0);
    var aac_lc: ?bool = null;
    var channels: u32 = 0;
    var fps_x100: u32 = 0;
    var have_audio = false;
    var pos: usize = inner_from;
    while (pos + 8 <= inner_to) {
        const t = memBox(buf[0..inner_to], pos) orelse break;
        pos += @intCast(t.size);
        if (!std.mem.eql(u8, &t.kind, "trak")) continue;
        const t_from: usize = @intCast(t.start + t.head);
        const t_to: usize = @intCast(t.start + t.size);
        const mdia = child(buf, t_from, t_to, "mdia") orelse continue;
        const m_from: usize = @intCast(mdia.start + mdia.head);
        const m_to: usize = @intCast(mdia.start + mdia.size);
        const hdlr = child(buf, m_from, m_to, "hdlr") orelse continue;
        const hp: usize = @intCast(hdlr.start + hdlr.head);
        if (hp + 12 > buf.len) continue;
        const kind4 = buf[hp + 8 ..][0..4];
        if (std.mem.eql(u8, kind4, "vide") and w == 0) {
            const tkhd = child(buf, t_from, t_to, "tkhd") orelse continue;
            const tp: usize = @intCast(tkhd.start + tkhd.head);
            if (tp >= buf.len) return Err.Cut;
            const wo: usize = if (buf[tp] == 1) 88 else 76;
            if (tp + wo + 8 > buf.len) return Err.Cut;
            w = be32(buf[tp + wo ..]) >> 16;
            h = be32(buf[tp + wo + 4 ..]) >> 16;
            if (stblOf(buf, m_from, m_to)) |stbl| {
                vcodec = entryKind(buf, stbl) orelse vcodec;
                fps_x100 = fpsOf(buf, m_from, m_to, stbl);
            }
        } else if (std.mem.eql(u8, kind4, "soun") and !have_audio) {
            have_audio = true;
            if (stblOf(buf, m_from, m_to)) |stbl| {
                acodec = entryKind(buf, stbl) orelse acodec;
                if (std.mem.eql(u8, &acodec, "mp4a")) audioDetail(buf, stbl, &channels, &aac_lc);
            }
        }
    }
    if (w == 0 or h == 0) return Err.NoVideo;
    return .{ .size = total, .ms = ms, .width = w, .height = h, .faststart = if (mdat_at) |d| mo < d else true, .vcodec = vcodec, .acodec = acodec, .aac_lc = aac_lc, .channels = channels, .fps_x100 = fps_x100 };
}

// ---- test helpers: a tiny valid-enough MP4 built in memory ----
fn box(a: std.mem.Allocator, kind: []const u8, payload: []const u8) ![]u8 {
    const out = try a.alloc(u8, 8 + payload.len);
    std.mem.writeInt(u32, out[0..4], @intCast(out.len), .big);
    @memcpy(out[4..8], kind);
    @memcpy(out[8..], payload);
    return out;
}

fn cat(a: std.mem.Allocator, parts: []const []const u8) ![]u8 {
    var o: std.ArrayList(u8) = .empty;
    for (parts) |p| try o.appendSlice(a, p);
    return o.toOwnedSlice(a);
}

pub const TestOpts = struct { vcodec: []const u8 = "avc1", acodec: []const u8 = "mp4a", aot: u8 = 2, channels: u16 = 2, fps: u32 = 30 };

fn trackBoxes(a: std.mem.Allocator, kind: []const u8, w: u32, h: u32, secs: u32, o: TestOpts) ![]u8 {
    const is_v = std.mem.eql(u8, kind, "vide");
    var tkhd = [_]u8{0} ** 84;
    if (is_v) {
        std.mem.writeInt(u32, tkhd[76..80], w << 16, .big);
        std.mem.writeInt(u32, tkhd[80..84], h << 16, .big);
    }
    var hdlr = [_]u8{0} ** 24;
    @memcpy(hdlr[8..12], kind);
    var mdhd = [_]u8{0} ** 24;
    std.mem.writeInt(u32, mdhd[12..16], 1000, .big);
    std.mem.writeInt(u32, mdhd[16..20], secs * 1000, .big);
    // stsd: version/flags, count 1, then one sample entry
    var entry: []u8 = undefined;
    if (is_v) {
        var ent = [_]u8{0} ** 78;
        entry = try box(a, o.vcodec, &ent);
    } else {
        var ent = [_]u8{0} ** 28;
        std.mem.writeInt(u16, ent[16..18], o.channels, .big);
        // esds: version/flags, ES_Descr(03) > DecoderConfig(04) > DecSpecificInfo(05, 2 bytes)
        const dsi = [_]u8{ 0x05, 0x02, @as(u8, o.aot) << 3, 0x10 };
        const dcd = [_]u8{ 0x04, 13 + dsi.len, 0x40, 0x15, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 } ++ dsi;
        const esd = [_]u8{ 0x03, 3 + dcd.len, 0, 1, 0 } ++ dcd;
        const esds = try box(a, "esds", &([_]u8{ 0, 0, 0, 0 } ++ esd));
        entry = try box(a, o.acodec, try cat(a, &.{ &ent, esds }));
    }
    const stsd = try box(a, "stsd", try cat(a, &.{ &[_]u8{ 0, 0, 0, 0, 0, 0, 0, 1 }, entry }));
    // stts: one entry (all frames), count = fps * secs, delta 1000/fps (timescale 1000)
    var stts = [_]u8{0} ** 16;
    std.mem.writeInt(u32, stts[4..8], 1, .big);
    std.mem.writeInt(u32, stts[8..12], o.fps * secs, .big);
    std.mem.writeInt(u32, stts[12..16], if (o.fps == 0) 0 else 1000 / o.fps, .big);
    const stbl = try box(a, "stbl", try cat(a, &.{ stsd, try box(a, "stts", &stts) }));
    const minf = try box(a, "minf", stbl);
    const mdia = try box(a, "mdia", try cat(a, &.{ try box(a, "mdhd", &mdhd), try box(a, "hdlr", &hdlr), minf }));
    return box(a, "trak", try cat(a, &.{ try box(a, "tkhd", &tkhd), mdia }));
}

// ftyp + moov (index first = fast start) for a w x h video of `secs` seconds, with a video and an audio track
pub fn testHeadWith(a: std.mem.Allocator, w: u32, h: u32, secs: u32, o: TestOpts) ![]u8 {
    var mvhd = [_]u8{0} ** 100;
    std.mem.writeInt(u32, mvhd[12..16], 1000, .big); // timescale
    std.mem.writeInt(u32, mvhd[16..20], secs * 1000, .big); // duration
    const vtrak = try trackBoxes(a, "vide", w, h, secs, o);
    const atrak = if (o.acodec.len == 4) try trackBoxes(a, "soun", 0, 0, secs, o) else try a.alloc(u8, 0);
    const moov = try box(a, "moov", try cat(a, &.{ try box(a, "mvhd", &mvhd), vtrak, atrak }));
    const ftyp = try box(a, "ftyp", "isom\x00\x00\x02\x00isomiso2");
    return cat(a, &.{ ftyp, moov });
}

pub fn testHead(a: std.mem.Allocator, w: u32, h: u32, secs: u32) ![]u8 {
    return testHeadWith(a, w, h, secs, .{});
}

pub fn testMp4Opts(a: std.mem.Allocator, w: u32, h: u32, secs: u32, faststart: bool, extra: usize, o: TestOpts) ![]u8 {
    const head = try testHeadWith(a, w, h, secs, o);
    const payload = try a.alloc(u8, 16 + extra);
    @memcpy(payload[0..16], "0123456789abcdef");
    for (payload[16..], 0..) |*b, i| b.* = @truncate(i *% 31 +% 7);
    const mdat = try box(a, "mdat", payload);
    if (faststart) return cat(a, &.{ head, mdat });
    // index last: ftyp, mdat, moov
    const ft_len: usize = std.mem.readInt(u32, head[0..4], .big);
    return cat(a, &.{ head[0..ft_len], mdat, head[ft_len..] });
}

pub fn testMp4Pad(a: std.mem.Allocator, w: u32, h: u32, secs: u32, faststart: bool, extra: usize) ![]u8 {
    return testMp4Opts(a, w, h, secs, faststart, extra, .{});
}

pub fn testMp4(a: std.mem.Allocator, w: u32, h: u32, secs: u32, faststart: bool) ![]u8 {
    return testMp4Pad(a, w, h, secs, faststart, 0);
}

fn writeTmp(a: std.mem.Allocator, tmp: *std.testing.TmpDir, name: []const u8, data: []const u8) ![]u8 {
    const p = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/{s}", .{ &tmp.sub_path, name });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = p, .data = data });
    return p;
}

test "probe reads size, duration, dimensions and fast start" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const good = try testMp4(a, 1080, 1920, 15, true);
    const f = try probe(std.testing.io, a, try writeTmp(a, &tmp, "g.mp4", good));
    try std.testing.expect(f.width == 1080 and f.height == 1920 and f.ms == 15000 and f.faststart);
    try std.testing.expectEqual(@as(u64, good.len), f.size);
    const slow = try testMp4(a, 720, 1280, 7, false);
    const f2 = try probe(std.testing.io, a, try writeTmp(a, &tmp, "s.mp4", slow));
    try std.testing.expect(!f2.faststart and f2.width == 720 and f2.ms == 7000);
}

test "probe reads codecs, AAC profile, channels and frame rate" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const f = try probe(std.testing.io, a, try writeTmp(a, &tmp, "c1.mp4", try testMp4(a, 1080, 1920, 10, true)));
    try std.testing.expectEqualStrings("avc1", &f.vcodec);
    try std.testing.expectEqualStrings("mp4a", &f.acodec);
    try std.testing.expect(f.aac_lc.? and f.channels == 2 and f.fps_x100 == 3000);
    const he = try probe(std.testing.io, a, try writeTmp(a, &tmp, "c2.mp4", try testMp4Opts(a, 720, 1280, 10, true, 0, .{ .aot = 5, .channels = 6, .fps = 61, .vcodec = "vp09" })));
    try std.testing.expect(!he.aac_lc.? and he.channels == 6 and he.fps_x100 == 6100);
    try std.testing.expectEqualStrings("vp09", &he.vcodec);
    // no audio track: the codec stays unknown, the file is still readable
    const mute = try probe(std.testing.io, a, try writeTmp(a, &tmp, "c3.mp4", try testMp4Opts(a, 720, 1280, 10, true, 0, .{ .acodec = "" })));
    try std.testing.expect(mute.aac_lc == null and mute.acodec[0] == 0);
}

test "probe refuses what is not a usable mp4" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try std.testing.expectError(Err.NotMp4, probe(std.testing.io, a, try writeTmp(a, &tmp, "t.mp4", "this is a text file, not video")));
    try std.testing.expectError(Err.Read, probe(std.testing.io, a, "no/such.mp4"));
    const good = try testMp4(a, 1080, 1920, 5, true);
    try std.testing.expectError(Err.Cut, probe(std.testing.io, a, try writeTmp(a, &tmp, "c.mp4", good[0 .. good.len - 5])));
    const ftyp_only = try box(a, "ftyp", "isom\x00\x00\x02\x00");
    try std.testing.expectError(Err.NoMoov, probe(std.testing.io, a, try writeTmp(a, &tmp, "f.mp4", ftyp_only)));
}
test "probe survives hostile boxes: giant sizes, empty mvhd, huge duration, tiny largesize" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ftyp = try box(a, "ftyp", "isom\x00\x00\x02\x00");
    // a box whose 64-bit size is near 2^64 (would overflow off + size)
    var big: [16]u8 = undefined;
    std.mem.writeInt(u32, big[0..4], 1, .big);
    @memcpy(big[4..8], "moov");
    std.mem.writeInt(u64, big[8..16], std.math.maxInt(u64), .big);
    try std.testing.expectError(Err.Cut, probe(std.testing.io, a, try writeTmp(a, &tmp, "b1.mp4", try cat(a, &.{ ftyp, &big }))));
    // largesize smaller than its own header
    std.mem.writeInt(u64, big[8..16], 4, .big);
    try std.testing.expectError(Err.Cut, probe(std.testing.io, a, try writeTmp(a, &tmp, "b2.mp4", try cat(a, &.{ ftyp, &big }))));
    // moov with an empty mvhd (no payload) and no tracks
    const moov_empty = try box(a, "moov", try box(a, "mvhd", ""));
    try std.testing.expectError(Err.Cut, probe(std.testing.io, a, try writeTmp(a, &tmp, "b3.mp4", try cat(a, &.{ ftyp, moov_empty }))));
    // version-1 mvhd with a duration so large that duration*1000 overflows: no panic
    var mv = [_]u8{0} ** 100;
    mv[0] = 1;
    std.mem.writeInt(u32, mv[20..24], 1, .big);
    std.mem.writeInt(u64, mv[24..32], std.math.maxInt(u64), .big);
    const moov_big = try box(a, "moov", try box(a, "mvhd", &mv));
    try std.testing.expectError(Err.NoVideo, probe(std.testing.io, a, try writeTmp(a, &tmp, "b4.mp4", try cat(a, &.{ ftyp, moov_big }))));
}

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
