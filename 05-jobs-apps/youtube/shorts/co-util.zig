// =====================================================================
// Des: Small std-only helpers - time, sleep, hashing, hex, printing, safe file read/write, secret files (mode 600), dir listing and random numbers
// Flo: callers pass io > helper does one tiny job > returns value or error
// Cre: 2026-11-15                          - | Mod: 2026-11-15
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: io, allocator, paths, bytes
// Out: values, written files, printed lines
// Run: not run directly - imported by every file
// =====================================================================
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

// random u64 from the OS
pub fn randU64(io: std.Io) u64 {
    var b: [8]u8 = undefined;
    io.random(&b);
    return std.mem.readInt(u64, &b, .little);
}

// uniform-ish number in lo..=hi
pub fn randRange(io: std.Io, lo: u64, hi: u64) u64 {
    if (hi <= lo) return lo;
    return lo + randU64(io) % (hi - lo + 1);
}

pub fn sha256Hex(data: []const u8) [64]u8 {
    var h: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &h, .{});
    return std.fmt.bytesToHex(h, .lower);
}

// tests set this: the test runner talks over stdout, so code under test stays silent
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

// best-effort chmod on a file or folder (nothing on Windows)
pub fn restrict(io: std.Io, path: []const u8, mode: u32) void {
    if (comptime @import("builtin").os.tag == .windows) return;
    std.Io.Dir.cwd().setFilePermissions(io, path, .fromMode(@intCast(mode)), .{}) catch {};
}

// a folder only the owner can open (data and secrets folders)
pub fn mkdirPrivate(io: std.Io, path: []const u8) !void {
    try mkdirp(io, path);
    restrict(io, path, 0o700);
}

pub fn exists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

pub fn readAll(alloc: std.mem.Allocator, io: std.Io, path: []const u8, max: usize) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(max));
}

// file size in bytes
pub fn fileSize(io: std.Io, path: []const u8) !u64 {
    const st = try std.Io.Dir.cwd().statFile(io, path, .{});
    return st.size;
}

// last-modified time, ms since 1970
pub fn mtimeMs(io: std.Io, path: []const u8) !i64 {
    const st = try std.Io.Dir.cwd().statFile(io, path, .{});
    return st.mtime.toMilliseconds();
}

// write p.part then rename over p: a crash leaves the old file or the new one, never half
pub fn writeAtomic(alloc: std.mem.Allocator, io: std.Io, path: []const u8, data: []const u8) !void {
    return writeAtomicMode(alloc, io, path, data, 0o644);
}

// same, with a file mode (secrets use 0o600; ignored on Windows)
pub fn writeAtomicMode(alloc: std.mem.Allocator, io: std.Io, path: []const u8, data: []const u8, mode: u32) !void {
    const tmp = try std.fmt.allocPrint(alloc, "{s}.part", .{path});
    defer alloc.free(tmp);
    const cwd = std.Io.Dir.cwd();
    {
        var f = if (comptime @import("builtin").os.tag != .windows) try cwd.createFile(io, tmp, .{ .permissions = .fromMode(@intCast(mode)) }) else try cwd.createFile(io, tmp, .{});
        defer f.close(io);
        try f.writePositionalAll(io, data, 0);
        f.sync(io) catch {}; // a power cut must not leave an empty token or kill file
    }
    try cwd.rename(tmp, cwd, path, io);
}

// append one line (adds \n); creates the file when missing
pub fn appendLine(io: std.Io, path: []const u8, line: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    var f = try cwd.createFile(io, path, .{ .read = true, .truncate = false });
    defer f.close(io);
    const off = try f.length(io);
    try f.writePositionalAll(io, line, off);
    try f.writePositionalAll(io, "\n", off + line.len);
}

// copy a file (used by backup); never overwrites the source
pub fn copyFile(io: std.Io, from: []const u8, to: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    try cwd.copyFile(from, cwd, to, io, .{});
}

pub fn jsonStr(alloc: std.mem.Allocator, v: anytype) ![]u8 {
    return std.json.Stringify.valueAlloc(alloc, v, .{ .emit_null_optional_fields = false });
}

// base64url without padding (PKCE, state)
pub fn b64url(alloc: std.mem.Allocator, b: []const u8) ![]u8 {
    const enc = std.base64.url_safe_no_pad.Encoder;
    const out = try alloc.alloc(u8, enc.calcSize(b.len));
    _ = enc.encode(out, b);
    return out;
}

// percent-encode for query values (unreserved stay)
pub fn pct(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var o: std.ArrayList(u8) = .empty;
    for (s) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') {
            try o.append(alloc, c);
        } else {
            try o.print(alloc, "%{X:0>2}", .{c});
        }
    }
    return o.toOwnedSlice(alloc);
}

// percent-decode (also '+' as space); returns null on a bad escape
pub fn unpct(alloc: std.mem.Allocator, s: []const u8) ?[]u8 {
    var o: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c == '%') {
            if (i + 2 >= s.len) return null;
            const v = std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16) catch return null;
            o.append(alloc, v) catch return null;
            i += 2;
        } else if (c == '+') {
            o.append(alloc, ' ') catch return null;
        } else o.append(alloc, c) catch return null;
    }
    return o.toOwnedSlice(alloc) catch null;
}

// trim whitespace and newlines (secret files end with \n)
pub fn trimSecret(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n");
}

pub const Civil = struct { y: i64, m: u8, d: u8 };

// days since 1970-01-01 to a calendar date (proleptic Gregorian)
pub fn civilFromDays(z0: i64) Civil {
    const z = z0 + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m: i64 = if (mp < 10) mp + 3 else mp - 9;
    const y = yoe + era * 400 + (if (m <= 2) @as(i64, 1) else 0);
    return .{ .y = y, .m = @intCast(m), .d = @intCast(d) };
}

// calendar date to days since 1970-01-01
pub fn daysFromCivil(y0: i64, m: u8, d: u8) i64 {
    const y = if (m <= 2) y0 - 1 else y0;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mm: i64 = m;
    const mp = if (mm > 2) mm - 3 else mm + 9;
    const doy = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

// "2026-11-15 20:41:03" in the given UTC offset
pub fn fmtTs(buf: []u8, ms: i64, tz_h: i32) []const u8 {
    const s = @divFloor(ms, 1000) + @as(i64, tz_h) * 3600;
    const days = @divFloor(s, 86400);
    const sod = s - days * 86400;
    const c = civilFromDays(days);
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{ @as(u64, @intCast(c.y)), c.m, c.d, @as(u64, @intCast(@divFloor(sod, 3600))), @as(u64, @intCast(@divFloor(@mod(sod, 3600), 60))), @as(u64, @intCast(@mod(sod, 60))) }) catch buf[0..0];
}

test "civil dates round trip and format" {
    try std.testing.expectEqual(@as(i64, 0), daysFromCivil(1970, 1, 1));
    try std.testing.expectEqual(@as(i64, 20426), daysFromCivil(2025, 12, 4));
    const c = civilFromDays(daysFromCivil(2026, 11, 15));
    try std.testing.expect(c.y == 2026 and c.m == 11 and c.d == 15);
    const l = civilFromDays(daysFromCivil(2024, 2, 29));
    try std.testing.expect(l.y == 2024 and l.m == 2 and l.d == 29);
    var b: [32]u8 = undefined;
    try std.testing.expectEqualStrings("2026-11-15 20:41:03", fmtTs(&b, (daysFromCivil(2026, 11, 15) * 86400 + 20 * 3600 + 41 * 60 + 3) * 1000, 0));
    try std.testing.expectEqualStrings("2026-11-16 03:41:03", fmtTs(&b, (daysFromCivil(2026, 11, 15) * 86400 + 20 * 3600 + 41 * 60 + 3) * 1000, 7));
}

test "atomic write + append + hash + mode" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pb: [256]u8 = undefined;
    const base = try std.fmt.bufPrint(&pb, ".zig-cache/tmp/{s}/f.txt", .{&tmp.sub_path});
    try writeAtomic(std.testing.allocator, std.testing.io, base, "hello");
    const got = try readAll(std.testing.allocator, std.testing.io, base, 100);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("hello", got);
    try std.testing.expectEqual(@as(u64, 5), try fileSize(std.testing.io, base));
    var lb: [256]u8 = undefined;
    const lp = try std.fmt.bufPrint(&lb, ".zig-cache/tmp/{s}/l.txt", .{&tmp.sub_path});
    try appendLine(std.testing.io, lp, "a");
    try appendLine(std.testing.io, lp, "b");
    const l = try readAll(std.testing.allocator, std.testing.io, lp, 100);
    defer std.testing.allocator.free(l);
    try std.testing.expectEqualStrings("a\nb\n", l);
    try std.testing.expectEqual(@as(usize, 64), sha256Hex("x").len);
    var sb: [256]u8 = undefined;
    const sp = try std.fmt.bufPrint(&sb, ".zig-cache/tmp/{s}/s.txt", .{&tmp.sub_path});
    try writeAtomicMode(std.testing.allocator, std.testing.io, sp, "sec", 0o600);
    const st = try std.Io.Dir.cwd().statFile(std.testing.io, sp, .{});
    if (@import("builtin").os.tag != .windows) try std.testing.expectEqual(@as(u32, 0o600), @as(u32, @intCast(st.permissions.toMode() & 0o777)));
}

test "pct round trip and b64url" {
    const a = std.testing.allocator;
    const e = try pct(a, "a b&c=d/é");
    defer a.free(e);
    try std.testing.expectEqualStrings("a%20b%26c%3Dd%2F%C3%A9", e);
    const d = unpct(a, e).?;
    defer a.free(d);
    try std.testing.expectEqualStrings("a b&c=d/é", d);
    try std.testing.expect(unpct(a, "%zz") == null);
    try std.testing.expect(unpct(a, "%4") == null);
    const b = try b64url(a, "\xfb\xff\xfe");
    defer a.free(b);
    try std.testing.expectEqualStrings("-__-", b);
    try std.testing.expectEqualStrings("tok", trimSecret(" tok\n"));
}
// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
