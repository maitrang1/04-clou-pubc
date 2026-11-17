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

// same, file mode 0600 on POSIX (tokens). Windows keeps its default ACL (owner folder).
pub fn writeAtomicPriv(alloc: std.mem.Allocator, io: std.Io, path: []const u8, data: []const u8) !void {
    const tmp = try std.fmt.allocPrint(alloc, "{s}.part", .{path});
    defer alloc.free(tmp);
    const cwd = std.Io.Dir.cwd();
    const perm: std.Io.File.Permissions = if (@import("builtin").os.tag == .windows) .default_file else @enumFromInt(0o600);
    try cwd.writeFile(io, .{ .sub_path = tmp, .data = data, .flags = .{ .permissions = perm } });
    try cwd.rename(tmp, cwd, path, io);
}

// percent-encode everything except unreserved characters
pub fn pct(a: std.mem.Allocator, s: []const u8) ![]u8 {
    var o: std.ArrayList(u8) = .empty;
    for (s) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') try o.append(a, c) else try o.print(a, "%{X:0>2}", .{c});
    }
    return o.items;
}

pub fn unpct(a: std.mem.Allocator, s: []const u8) ?[]u8 {
    var o: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '%') {
            if (i + 3 > s.len) return null;
            const v = std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16) catch return null;
            o.append(a, v) catch return null;
            i += 2;
        } else if (s[i] == '+') o.append(a, ' ') catch return null else o.append(a, s[i]) catch return null;
    }
    return o.items;
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
