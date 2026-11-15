// Test helper: writes a tiny valid-looking .mp4 (ftyp + mdat + moov with real mvhd/tkhd/mdhd/hdlr/stsd/stts) so the probe and the validator can be tested without ffmpeg.
const std = @import("std");
const Io = std.Io;

pub const Spec = struct { seconds: u32 = 10, w: u16 = 1080, h: u16 = 1920, fps: u32 = 30, vfmt: *const [4]u8 = "avc1", audio: bool = true, afmt: *const [4]u8 = "mp4a", channels: u16 = 2, rate: u16 = 48000, mdat_mb: u64 = 0, moov_first: bool = true, edit_list: bool = false };

fn w32(l: *std.ArrayList(u8), a: std.mem.Allocator, v: u32) !void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .big);
    try l.appendSlice(a, &b);
}
fn w16(l: *std.ArrayList(u8), a: std.mem.Allocator, v: u16) !void {
    var b: [2]u8 = undefined;
    std.mem.writeInt(u16, &b, v, .big);
    try l.appendSlice(a, &b);
}
fn zeros(l: *std.ArrayList(u8), a: std.mem.Allocator, n: usize) !void {
    try l.appendNTimes(a, 0, n);
}
// box: size placeholder patched when closed
fn open(l: *std.ArrayList(u8), a: std.mem.Allocator, kind: *const [4]u8) !usize {
    const at = l.items.len;
    try w32(l, a, 0);
    try l.appendSlice(a, kind);
    return at;
}
fn close(l: *std.ArrayList(u8), at: usize) void {
    std.mem.writeInt(u32, l.items[at..][0..4], @intCast(l.items.len - at), .big);
}

fn trak(l: *std.ArrayList(u8), a: std.mem.Allocator, s: Spec, video: bool) !void {
    const tr = try open(l, a, "trak");
    const tk = try open(l, a, "tkhd");
    try w32(l, a, 7); // v0, flags
    try zeros(l, a, 8 + 4 + 4 + 4 + 8 + 4 + 4 + 36); // times, id, res, dur, res, layer/alt/vol/res, matrix
    try w32(l, a, if (video) @as(u32, s.w) << 16 else 0);
    try w32(l, a, if (video) @as(u32, s.h) << 16 else 0);
    close(l, tk);
    if (s.edit_list and video) { // edts > elst (one entry): a track with an edit list
        const ed = try open(l, a, "edts");
        const el = try open(l, a, "elst");
        try w32(l, a, 0);
        try w32(l, a, 1);
        try w32(l, a, s.seconds * 1000);
        try w32(l, a, 0);
        try w32(l, a, 0x00010000);
        close(l, el);
        close(l, ed);
    }
    const md = try open(l, a, "mdia");
    const mh = try open(l, a, "mdhd");
    try w32(l, a, 0);
    try w32(l, a, 0);
    try w32(l, a, 0);
    try w32(l, a, if (video) 15360 else s.rate);
    try w32(l, a, if (video) s.seconds * 15360 else s.seconds * s.rate);
    try w32(l, a, 0);
    close(l, mh);
    const hd = try open(l, a, "hdlr");
    try w32(l, a, 0);
    try w32(l, a, 0);
    try l.appendSlice(a, if (video) "vide" else "soun");
    try zeros(l, a, 12);
    close(l, hd);
    const mi = try open(l, a, "minf");
    const sb = try open(l, a, "stbl");
    const sd = try open(l, a, "stsd");
    try w32(l, a, 0);
    try w32(l, a, 1);
    const en = try open(l, a, if (video) s.vfmt else s.afmt);
    try zeros(l, a, 6);
    try w16(l, a, 1);
    if (video) {
        try zeros(l, a, 16);
        try w16(l, a, s.w);
        try w16(l, a, s.h);
        try zeros(l, a, 50);
    } else {
        try zeros(l, a, 8);
        try w16(l, a, s.channels);
        try w16(l, a, 16);
        try zeros(l, a, 4);
        try w16(l, a, s.rate);
        try w16(l, a, 0);
    }
    close(l, en);
    close(l, sd);
    if (video) {
        const st = try open(l, a, "stts");
        try w32(l, a, 0);
        try w32(l, a, 1);
        try w32(l, a, s.seconds * s.fps);
        try w32(l, a, 15360 / s.fps);
        close(l, st);
    }
    close(l, sb);
    close(l, mi);
    close(l, md);
    close(l, tr);
}

pub fn write(a: std.mem.Allocator, io: Io, path: []const u8, s: Spec) !void {
    var l: std.ArrayList(u8) = .empty;
    defer l.deinit(a);
    const ft = try open(&l, a, "ftyp");
    try l.appendSlice(a, "isom");
    try w32(&l, a, 512);
    try l.appendSlice(a, "isomiso2avc1mp41");
    close(&l, ft);
    var moov: std.ArrayList(u8) = .empty;
    defer moov.deinit(a);
    const mv = try open(&moov, a, "moov");
    const mh = try open(&moov, a, "mvhd");
    try w32(&moov, a, 0);
    try w32(&moov, a, 0);
    try w32(&moov, a, 0);
    try w32(&moov, a, 1000);
    try w32(&moov, a, s.seconds * 1000);
    try zeros(&moov, a, 80);
    close(&moov, mh);
    try trak(&moov, a, s, true);
    if (s.audio) try trak(&moov, a, s, false);
    close(&moov, mv);
    var f = try Io.Dir.cwd().createFile(io, path, .{ .truncate = true, .read = true });
    defer f.close(io);
    var off: u64 = 0;
    try f.writePositionalAll(io, l.items, off);
    off += l.items.len;
    if (s.moov_first) {
        try f.writePositionalAll(io, moov.items, off);
        off += moov.items.len;
    }
    // mdat: header + sparse zero payload (mdat_mb MB, 16 bytes minimum)
    const payload: u64 = @max(16, s.mdat_mb * 1024 * 1024);
    var hdr: [8]u8 = undefined;
    std.mem.writeInt(u32, hdr[0..4], @intCast(payload + 8), .big);
    @memcpy(hdr[4..8], "mdat");
    try f.writePositionalAll(io, &hdr, off);
    off += 8;
    try f.setLength(io, off + payload);
    off += payload;
    if (!s.moov_first) try f.writePositionalAll(io, moov.items, off);
}

test "box reader reads what the builder wrote (moov last and first)" {
    const probe = @import("rw-probe.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/a.mp4", .{&tmp.sub_path});
    for ([_]bool{ false, true }) |mf| {
        try write(a, std.testing.io, p, .{ .seconds = 12, .w = 1080, .h = 1920, .fps = 30, .moov_first = mf });
        const f = try probe.boxes(a, std.testing.io, p);
        try std.testing.expectEqual(mf, f.faststart.?);
        try std.testing.expectEqual(false, f.edit_list.?);
        try std.testing.expectApproxEqAbs(@as(f64, 12), f.seconds.?, 0.01);
        try std.testing.expectEqual(@as(u32, 1080), f.width.?);
        try std.testing.expectEqual(@as(u32, 1920), f.height.?);
        try std.testing.expectApproxEqAbs(@as(f64, 30), f.fps.?, 0.01);
        try std.testing.expectEqualStrings("avc1", f.vcodec);
        try std.testing.expectEqualStrings("mp4a", f.acodec);
        try std.testing.expectEqual(@as(u32, 2), f.channels.?);
        try std.testing.expectEqual(@as(u32, 48000), f.rate.?);
    }
    try write(a, std.testing.io, p, .{ .audio = false, .vfmt = "hvc1" });
    const f2 = try probe.boxes(a, std.testing.io, p);
    try std.testing.expect(!f2.has_audio);
    try std.testing.expectEqualStrings("hvc1", f2.vcodec);
}

test "an edit list in a track is seen" {
    const probe = @import("rw-probe.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/e.mp4", .{&tmp.sub_path});
    try write(a, std.testing.io, p, .{ .edit_list = true });
    const f = try probe.boxes(a, std.testing.io, p);
    try std.testing.expectEqual(true, f.edit_list.?);
    // the rest of the facts still read fine behind the edts box
    try std.testing.expectEqual(@as(u32, 1080), f.width.?);
    try std.testing.expectEqualStrings("avc1", f.vcodec);
}

test "garbage and truncated files are refused, not crashed on" {
    const probe = @import("rw-probe.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/g.mp4", .{&tmp.sub_path});
    try Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = p, .data = "this is not an mp4 file at all, just text" });
    try std.testing.expectError(error.BadMp4, probe.boxes(a, std.testing.io, p));
    try Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = p, .data = "" });
    try std.testing.expectError(error.BadMp4, probe.boxes(a, std.testing.io, p));
    try write(a, std.testing.io, p, .{ .moov_first = false }); // moov last, so cutting the end cuts the moov
    const f = try Io.Dir.cwd().openFile(std.testing.io, p, .{ .mode = .read_write });
    const len = try f.length(std.testing.io);
    try f.setLength(std.testing.io, len - 40); // moov cut short
    f.close(std.testing.io);
    try std.testing.expectError(error.BadMp4, probe.boxes(a, std.testing.io, p));
}

test "hostile boxes: 64-bit giant size and huge stts do not overflow" {
    const probe = @import("rw-probe.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/h.mp4", .{&tmp.sub_path});
    // ftyp, then a box that claims a 2^64-1 largesize
    var b: [40]u8 = undefined;
    @memset(&b, 0);
    std.mem.writeInt(u32, b[0..4], 20, .big);
    @memcpy(b[4..8], "ftyp");
    std.mem.writeInt(u32, b[20..24], 1, .big);
    @memcpy(b[24..28], "moov");
    std.mem.writeInt(u64, b[28..36], std.math.maxInt(u64), .big);
    try Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = p, .data = &b });
    try std.testing.expectError(error.BadMp4, probe.boxes(a, std.testing.io, p));
}
