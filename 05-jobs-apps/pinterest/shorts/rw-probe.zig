// Facts about an .mp4, read from the file itself: std-only box reader (duration, size, resolution, fps, codecs), or ffprobe when the config names one.
// Anything the file does not tell stays null; the caller then trusts the pair's json and says so.
const std = @import("std");
const Io = std.Io;

pub const Facts = struct {
    seconds: ?f64 = null,
    width: ?u32 = null,
    height: ?u32 = null,
    fps: ?f64 = null,
    vcodec: []const u8 = "",
    acodec: []const u8 = "",
    channels: ?u32 = null,
    rate: ?u32 = null,
    has_audio: bool = false,
    size: u64 = 0,
    source: []const u8 = "boxes",
};

const CF = .{ .moov_cap = 16 * 1024 * 1024 };

fn be32(b: []const u8) u32 {
    return std.mem.readInt(u32, b[0..4], .big);
}
fn be64(b: []const u8) u64 {
    return std.mem.readInt(u64, b[0..8], .big);
}

const Box = struct { kind: [4]u8, start: usize, hdr: usize, end: usize }; // end exclusive

fn nextBox(b: []const u8, at: usize) ?Box {
    if (at + 8 > b.len) return null;
    var size: u64 = be32(b[at..]);
    var hdr: usize = 8;
    if (size == 1) {
        if (at + 16 > b.len) return null;
        size = be64(b[at + 8 ..]);
        hdr = 16;
    } else if (size == 0) size = b.len - at;
    if (size < hdr or size > b.len - at) return null;
    return .{ .kind = b[at + 4 ..][0..4].*, .start = at, .hdr = hdr, .end = at + @as(usize, @intCast(size)) };
}

fn find(b: []const u8, from: usize, to: usize, kind: *const [4]u8) ?Box {
    var at = from;
    while (at < to) {
        const bx = nextBox(b[0..to], at) orelse return null;
        if (std.mem.eql(u8, &bx.kind, kind)) return bx;
        at = bx.end;
    }
    return null;
}

// mvhd / mdhd: (timescale, duration)
fn timeHdr(b: []const u8, bx: Box) ?struct { ts: u32, dur: u64 } {
    const p = b[bx.start + bx.hdr .. bx.end];
    if (p.len < 20) return null;
    if (p[0] == 1) {
        if (p.len < 32) return null;
        return .{ .ts = be32(p[20..]), .dur = be64(p[24..]) };
    }
    return .{ .ts = be32(p[12..]), .dur = be32(p[16..]) };
}

fn parseMoov(a: std.mem.Allocator, b: []const u8, f: *Facts) void {
    _ = a;
    if (find(b, 0, b.len, "mvhd")) |mv| if (timeHdr(b, mv)) |t| if (t.ts > 0) {
        f.seconds = @as(f64, @floatFromInt(t.dur)) / @as(f64, @floatFromInt(t.ts));
    };
    var at: usize = 0;
    while (at < b.len) {
        const tr = nextBox(b, at) orelse break;
        at = tr.end;
        if (!std.mem.eql(u8, &tr.kind, "trak")) continue;
        const ti = tr.start + tr.hdr;
        const mdia = find(b, ti, tr.end, "mdia") orelse continue;
        const mi = mdia.start + mdia.hdr;
        const hdlr = find(b, mi, mdia.end, "hdlr") orelse continue;
        const hp = b[hdlr.start + hdlr.hdr .. hdlr.end];
        if (hp.len < 12) continue;
        const is_vid = std.mem.eql(u8, hp[8..12], "vide");
        const is_aud = std.mem.eql(u8, hp[8..12], "soun");
        if (!is_vid and !is_aud) continue;
        const minf = find(b, mi, mdia.end, "minf") orelse continue;
        const stbl = find(b, minf.start + minf.hdr, minf.end, "stbl") orelse continue;
        const si = stbl.start + stbl.hdr;
        if (find(b, si, stbl.end, "stsd")) |sd| {
            const p = b[sd.start + sd.hdr .. sd.end];
            if (p.len >= 16) {
                const fmt = p[12..16];
                if (is_vid) {
                    f.vcodec = fmtName(fmt);
                    if (p.len >= 8 + 8 + 28 + 4) { // entry: size4 fmt4 reserved6 dref2 predef2 res2 predef12 w2 h2
                        const e = p[8..];
                        f.width = std.mem.readInt(u16, e[8 + 8 + 16 ..][0..2], .big);
                        f.height = std.mem.readInt(u16, e[8 + 8 + 18 ..][0..2], .big);
                    }
                } else {
                    f.acodec = fmtName(fmt);
                    f.has_audio = true;
                    if (p.len >= 8 + 36) {
                        const e = p[8..];
                        f.channels = std.mem.readInt(u16, e[8 + 16 ..][0..2], .big);
                        f.rate = std.mem.readInt(u16, e[8 + 8 + 16 ..][0..2], .big);
                    }
                }
            }
        }
        if (is_vid) {
            // tkhd width/height (16.16) are the display size: prefer them when the sample entry gave nothing
            if (find(b, ti, tr.end, "tkhd")) |tk| {
                const p = b[tk.start + tk.hdr .. tk.end];
                if (p.len >= 8 and f.width == null) {
                    f.width = be32(p[p.len - 8 ..]) >> 16;
                    f.height = be32(p[p.len - 4 ..]) >> 16;
                }
            }
            var ts: u32 = 0;
            if (find(b, mi, mdia.end, "mdhd")) |mh| if (timeHdr(b, mh)) |t| {
                ts = t.ts;
            };
            if (find(b, si, stbl.end, "stts")) |st| {
                const p = b[st.start + st.hdr .. st.end];
                if (p.len >= 8 and ts > 0) {
                    const n = be32(p[4..]);
                    var samples: u64 = 0;
                    var dur: u64 = 0;
                    var i: usize = 0;
                    while (i < n and 8 + (i + 1) * 8 <= p.len) : (i += 1) {
                        const cnt = be32(p[8 + i * 8 ..]);
                        const dl = be32(p[12 + i * 8 ..]);
                        samples +|= cnt;
                        dur +|= @as(u64, cnt) * dl;
                    }
                    if (dur > 0) f.fps = @as(f64, @floatFromInt(samples)) * @as(f64, @floatFromInt(ts)) / @as(f64, @floatFromInt(dur));
                }
            }
        }
    }
}

fn fmtName(fmt: []const u8) []const u8 {
    if (std.mem.eql(u8, fmt, "avc1") or std.mem.eql(u8, fmt, "avc3")) return "avc1";
    if (std.mem.eql(u8, fmt, "hvc1") or std.mem.eql(u8, fmt, "hev1")) return "hvc1";
    if (std.mem.eql(u8, fmt, "vp09")) return "vp09";
    if (std.mem.eql(u8, fmt, "av01")) return "av01";
    if (std.mem.eql(u8, fmt, "mp4a")) return "mp4a";
    return "other";
}

// walk the top-level boxes by position (moov may sit at the end), read only moov
pub fn boxes(a: std.mem.Allocator, io: Io, path: []const u8) !Facts {
    var file = try Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const size = try file.length(io);
    var f = Facts{ .size = size };
    var at: u64 = 0;
    var hb: [16]u8 = undefined;
    var saw_ftyp = false;
    while (at + 8 <= size) {
        const n = try file.readPositionalAll(io, hb[0..16], at);
        if (n < 8) break;
        var bsz: u64 = be32(hb[0..]);
        var hdr: u64 = 8;
        if (bsz == 1 and n >= 16) {
            bsz = be64(hb[8..]);
            hdr = 16;
        } else if (bsz == 0) bsz = size - at;
        if (bsz < hdr or bsz > size - at) return error.BadMp4;
        if (std.mem.eql(u8, hb[4..8], "ftyp")) saw_ftyp = true;
        if (std.mem.eql(u8, hb[4..8], "moov")) {
            const plen = bsz - hdr;
            if (plen > CF.moov_cap) return error.BadMp4;
            const buf = try a.alloc(u8, @intCast(plen));
            const got = try file.readPositionalAll(io, buf, at + hdr);
            if (got != buf.len) return error.BadMp4;
            parseMoov(a, buf, &f);
            f.source = "boxes";
            return f;
        }
        at += bsz;
    }
    return error.BadMp4;
}

// ffprobe -print_format json: streams + format
pub fn ffprobe(a: std.mem.Allocator, io: Io, tool: []const u8, path: []const u8) !Facts {
    const r = std.process.run(a, io, .{ .argv = &.{ tool, "-v", "error", "-print_format", "json", "-show_streams", "-show_format", path }, .stdout_limit = .limited(4 * 1024 * 1024), .timeout = .{ .duration = .{ .raw = .fromSeconds(60), .clock = .awake } } }) catch return error.ToolMissing;
    if (r.term != .exited or r.term.exited != 0) return error.ProbeFailed;
    const js = @import("ap-json.zig");
    const root = js.parse(a, r.stdout) orelse return error.ProbeFailed;
    var f = Facts{ .source = "ffprobe" };
    if (js.obj(js.obj(root, "format"), "duration")) |d| if (d == .string) {
        f.seconds = std.fmt.parseFloat(f64, d.string) catch null;
    };
    if (js.obj(js.obj(root, "format"), "size")) |d| if (d == .string) {
        f.size = std.fmt.parseInt(u64, d.string, 10) catch 0;
    };
    const ss = js.obj(root, "streams") orelse return f;
    if (ss != .array) return f;
    for (ss.array.items) |s| {
        const kind = js.str(s, "codec_type");
        const name = js.str(s, "codec_name");
        if (std.mem.eql(u8, kind, "video")) {
            f.vcodec = if (std.mem.eql(u8, name, "h264")) "avc1" else if (std.mem.eql(u8, name, "hevc")) "hvc1" else name;
            f.width = @intCast(@max(0, js.int(s, "width")));
            f.height = @intCast(@max(0, js.int(s, "height")));
            const fr = js.str(s, "avg_frame_rate");
            if (std.mem.indexOfScalar(u8, fr, '/')) |sl| {
                const nu = std.fmt.parseFloat(f64, fr[0..sl]) catch 0;
                const de = std.fmt.parseFloat(f64, fr[sl + 1 ..]) catch 0;
                if (de > 0) f.fps = nu / de;
            }
        } else if (std.mem.eql(u8, kind, "audio")) {
            f.has_audio = true;
            f.acodec = if (std.mem.eql(u8, name, "aac")) "mp4a" else name;
            f.channels = @intCast(@max(0, js.int(s, "channels")));
            f.rate = std.fmt.parseInt(u32, js.str(s, "sample_rate"), 10) catch null;
        }
    }
    return f;
}

pub fn probe(a: std.mem.Allocator, io: Io, tool: []const u8, path: []const u8) !Facts {
    if (tool.len > 0) return ffprobe(a, io, tool, path);
    return boxes(a, io, path);
}
