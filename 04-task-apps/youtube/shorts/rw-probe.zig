// =====================================================================
// Des: Reads the facts of an MP4 file with no outside tool - size, duration, width, height, and whether the index (moov) comes before the data (mdat) for fast start
// Flo: walk top-level boxes (header reads only) > read moov into memory (capped) > mvhd timescale+duration > video track tkhd width/height
// Cre: 2026-11-15                          - | Mod: 2026-11-15
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: io, file path
// Out: Facts {size, ms, width, height, faststart} | error NotMp4 / NoMoov / NoVideo / Cut
// Run: not run directly - imported by rw-pair
// =====================================================================
const std = @import("std");

pub const Err = error{ NotMp4, NoMoov, NoVideo, Cut, OutOfMemory, Read };

pub const Facts = struct { size: u64, ms: u64, width: u32, height: u32, faststart: bool };

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
    // first video track
    var w: u32 = 0;
    var h: u32 = 0;
    var pos: usize = inner_from;
    while (pos + 8 <= inner_to) {
        const t = memBox(buf[0..inner_to], pos) orelse break;
        pos += @intCast(t.size);
        if (!std.mem.eql(u8, &t.kind, "trak")) continue;
        const t_from: usize = @intCast(t.start + t.head);
        const t_to: usize = @intCast(t.start + t.size);
        const mdia = child(buf, t_from, t_to, "mdia") orelse continue;
        const hdlr = child(buf, @intCast(mdia.start + mdia.head), @intCast(mdia.start + mdia.size), "hdlr") orelse continue;
        const hp: usize = @intCast(hdlr.start + hdlr.head);
        if (hp + 12 > buf.len or !std.mem.eql(u8, buf[hp + 8 ..][0..4], "vide")) continue;
        const tkhd = child(buf, t_from, t_to, "tkhd") orelse continue;
        const tp: usize = @intCast(tkhd.start + tkhd.head);
        if (tp >= buf.len) return Err.Cut;
        const wo: usize = if (buf[tp] == 1) 88 else 76;
        if (tp + wo + 8 > buf.len) return Err.Cut;
        w = be32(buf[tp + wo ..]) >> 16;
        h = be32(buf[tp + wo + 4 ..]) >> 16;
        break;
    }
    if (w == 0 or h == 0) return Err.NoVideo;
    return .{ .size = total, .ms = ms, .width = w, .height = h, .faststart = if (mdat_at) |d| mo < d else true };
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

// ftyp + moov (index first = fast start) for a w x h video of `secs` seconds
pub fn testHead(a: std.mem.Allocator, w: u32, h: u32, secs: u32) ![]u8 {
    var mvhd = [_]u8{0} ** 100;
    std.mem.writeInt(u32, mvhd[12..16], 1000, .big); // timescale
    std.mem.writeInt(u32, mvhd[16..20], secs * 1000, .big); // duration
    var tkhd = [_]u8{0} ** 84;
    std.mem.writeInt(u32, tkhd[76..80], w << 16, .big);
    std.mem.writeInt(u32, tkhd[80..84], h << 16, .big);
    var hdlr = [_]u8{0} ** 24;
    @memcpy(hdlr[8..12], "vide");
    const trak = try box(a, "trak", try cat(a, &.{ try box(a, "tkhd", &tkhd), try box(a, "mdia", try box(a, "hdlr", &hdlr)) }));
    const moov = try box(a, "moov", try cat(a, &.{ try box(a, "mvhd", &mvhd), trak }));
    const ftyp = try box(a, "ftyp", "isom\x00\x00\x02\x00isomiso2");
    return cat(a, &.{ ftyp, moov });
}

pub fn testMp4Pad(a: std.mem.Allocator, w: u32, h: u32, secs: u32, faststart: bool, extra: usize) ![]u8 {
    const head = try testHead(a, w, h, secs);
    const payload = try a.alloc(u8, 16 + extra);
    @memcpy(payload[0..16], "0123456789abcdef");
    for (payload[16..], 0..) |*b, i| b.* = @truncate(i *% 31 +% 7);
    const mdat = try box(a, "mdat", payload);
    if (faststart) return cat(a, &.{ head, mdat });
    // index last: ftyp, mdat, moov
    const ft_len: usize = std.mem.readInt(u32, head[0..4], .big);
    return cat(a, &.{ head[0..ft_len], mdat, head[ft_len..] });
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
