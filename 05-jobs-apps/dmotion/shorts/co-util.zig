// Small std-only helpers: files (atomic), hashing, hex, output, time.
const std = @import("std");

pub fn nowMs(io: std.Io) i64 {
    return std.Io.Clock.real.now(io).toMilliseconds();
}
pub fn monoMs(io: std.Io) i64 {
    return std.Io.Clock.awake.now(io).toMilliseconds();
}
pub fn sleepMs(io: std.Io, ms: i64) void {
    if (ms <= 0) return;
    std.Io.sleep(io, .fromMilliseconds(ms), .awake) catch {};
}

pub fn sha256Hex(data: []const u8) [64]u8 {
    var h: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &h, .{});
    return std.fmt.bytesToHex(h, .lower);
}

// tests set this: the test runner talks over stdout, so code under test must stay silent
pub var quiet = false;

pub fn print(io: std.Io, comptime fmt: []const u8, args: anytype) void {
    if (quiet) return;
    var buf: [4096]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch buf[0..];
    std.Io.File.stdout().writeStreamingAll(io, s) catch {};
}
pub fn eprint(io: std.Io, comptime fmt: []const u8, args: anytype) void {
    if (quiet) return;
    var buf: [4096]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch buf[0..];
    std.Io.File.stderr().writeStreamingAll(io, s) catch {};
}
pub fn printAll(io: std.Io, s: []const u8) void {
    if (quiet) return;
    std.Io.File.stdout().writeStreamingAll(io, s) catch {};
}

pub fn mkdirp(io: std.Io, path: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(io, path);
}

pub fn exists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

pub fn readAll(alloc: std.mem.Allocator, io: std.Io, path: []const u8, max: usize) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(max));
}

// write p.part then rename over p: a crash leaves the old file or the new one, never half.
pub fn writeAtomic(alloc: std.mem.Allocator, io: std.Io, path: []const u8, data: []const u8) !void {
    const tmp = try std.fmt.allocPrint(alloc, "{s}.part", .{path});
    defer alloc.free(tmp);
    const cwd = std.Io.Dir.cwd();
    try cwd.writeFile(io, .{ .sub_path = tmp, .data = data });
    try cwd.rename(tmp, cwd, path, io);
}

// append one line (adds \n); creates the file when missing.
pub fn appendLine(io: std.Io, path: []const u8, line: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    var f = try cwd.createFile(io, path, .{ .read = true, .truncate = false });
    defer f.close(io);
    const off = try f.length(io);
    try f.writePositionalAll(io, line, off);
    try f.writePositionalAll(io, "\n", off + line.len);
}

pub fn jsonStr(alloc: std.mem.Allocator, v: anytype) ![]u8 {
    return std.json.Stringify.valueAlloc(alloc, v, .{ .emit_null_optional_fields = false });
}

// ms since epoch -> 2026-11-15T10:00:00Z (UTC)
pub fn isoUtc(alloc: std.mem.Allocator, ms: i64) ![]u8 {
    const secs: u64 = @intCast(@max(0, @divTrunc(ms, 1000)));
    const es = std.time.epoch.EpochSeconds{ .secs = secs };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.allocPrint(alloc, "{d}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{ yd.year, md.month.numeric(), md.day_index + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute() });
}

// 2026-11-15T10:00:00Z (or with +00:00 / fractions) -> ms since epoch; null when it does not look like a date
pub fn parseIso(s: []const u8) ?i64 {
    if (s.len < 19 or s[4] != '-' or s[7] != '-' or (s[10] != 'T' and s[10] != ' ') or s[13] != ':' or s[16] != ':') return null;
    const y = std.fmt.parseInt(i64, s[0..4], 10) catch return null;
    const mo = std.fmt.parseInt(u8, s[5..7], 10) catch return null;
    const d = std.fmt.parseInt(u8, s[8..10], 10) catch return null;
    const h = std.fmt.parseInt(i64, s[11..13], 10) catch return null;
    const mi = std.fmt.parseInt(i64, s[14..16], 10) catch return null;
    const se = std.fmt.parseInt(i64, s[17..19], 10) catch return null;
    if (mo < 1 or mo > 12 or d < 1 or d > 31 or y < 1970) return null;
    // days from civil (Howard Hinnant)
    const yy = if (mo <= 2) y - 1 else y;
    const era = @divFloor(yy, 400);
    const yoe = yy - era * 400;
    const mp: i64 = @intCast((@as(i64, mo) + 9) % 12);
    const doy = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    const days = era * 146097 + doe - 719468;
    return (days * 86400 + h * 3600 + mi * 60 + se) * 1000;
}

pub fn hexEncode(alloc: std.mem.Allocator, b: []const u8) ![]u8 {
    const out = try alloc.alloc(u8, b.len * 2);
    const d = "0123456789abcdef";
    for (b, 0..) |c, i| {
        out[i * 2] = d[c >> 4];
        out[i * 2 + 1] = d[c & 15];
    }
    return out;
}

pub fn hexDecode(out: []u8, hex: []const u8) !void {
    if (hex.len != out.len * 2) return error.BadHex;
    _ = std.fmt.hexToBytes(out, hex) catch return error.BadHex;
}

test "atomic write + append + hash" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pb: [256]u8 = undefined;
    const base = try std.fmt.bufPrint(&pb, ".zig-cache/tmp/{s}/f.txt", .{&tmp.sub_path});
    try writeAtomic(std.testing.allocator, std.testing.io, base, "hello");
    const got = try readAll(std.testing.allocator, std.testing.io, base, 100);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("hello", got);
    var lb: [256]u8 = undefined;
    const lp = try std.fmt.bufPrint(&lb, ".zig-cache/tmp/{s}/l.txt", .{&tmp.sub_path});
    try appendLine(std.testing.io, lp, "a");
    try appendLine(std.testing.io, lp, "b");
    const l = try readAll(std.testing.allocator, std.testing.io, lp, 100);
    defer std.testing.allocator.free(l);
    try std.testing.expectEqualStrings("a\nb\n", l);
    try std.testing.expectEqual(@as(usize, 64), sha256Hex("x").len);
}

test "iso time round trip" {
    const a = std.testing.allocator;
    const t: i64 = 1_763_200_800_000; // 2025-11-15T10:00:00Z
    const s = try isoUtc(a, t);
    defer a.free(s);
    try std.testing.expectEqualStrings("2025-11-15T10:00:00Z", s);
    try std.testing.expectEqual(t, parseIso(s).?);
    try std.testing.expectEqual(t, parseIso("2025-11-15T10:00:00.123+00:00").?);
    try std.testing.expect(parseIso("nope") == null);
}
