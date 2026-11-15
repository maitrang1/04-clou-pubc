// The owner's own public video folder (decision D002): copy the mp4 into host.dir under a random name, check the public URL, later RENAME it into host.done_dir (never unlink).
// Threads downloads video_url itself; the app runs no server. Copy = name.part, flushed, then rename: the host never serves half a file.
const std = @import("std");
const Io = std.Io;
const Ctx = @import("co-ctx.zig").Ctx;
const util = @import("co-util.zig");
const guard = @import("co-guard.zig");
const net = @import("co-net.zig");

pub const Err = error{ NoHost, Copy, Rename, OutOfMemory };
pub const Staged = struct { file: []const u8, url: []const u8 };

pub fn configured(cx: *const Ctx) bool {
    return cx.cfg.host.dir.len > 0 and cx.cfg.host.done_dir.len > 0 and cx.cfg.host.base_url.len > 0;
}

// 32 hex chars from the OS random source + .mp4: unguessable, says nothing about the car or the plate
pub fn randomName(cx: *const Ctx, a: std.mem.Allocator) ![]u8 {
    var r: [16]u8 = undefined;
    cx.io.random(&r);
    const hx = try util.hexEncode(a, &r);
    defer a.free(hx);
    return std.fmt.allocPrint(a, "{s}.mp4", .{hx});
}

pub fn urlOf(cx: *const Ctx, a: std.mem.Allocator, file: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "{s}/{s}", .{ std.mem.trimEnd(u8, cx.cfg.host.base_url, "/"), file });
}

// copy src_path into host.dir/<random>.part (chunked, flushed), then rename to <random>.mp4
pub fn stage(cx: *const Ctx, a: std.mem.Allocator, src_path: []const u8) Err!Staged {
    if (!configured(cx)) return Err.NoHost;
    const dir = cx.path(a, cx.cfg.host.dir) catch return Err.OutOfMemory;
    util.mkdirp(cx.io, std.mem.trimEnd(u8, dir, "/")) catch return Err.Copy;
    const file = randomName(cx, a) catch return Err.OutOfMemory;
    const final = std.fmt.allocPrint(a, "{s}/{s}", .{ std.mem.trimEnd(u8, dir, "/"), file }) catch return Err.OutOfMemory;
    const part = std.fmt.allocPrint(a, "{s}.part", .{final}) catch return Err.OutOfMemory;
    const cwd = Io.Dir.cwd();
    var src = cwd.openFile(cx.io, src_path, .{}) catch return Err.Copy;
    defer src.close(cx.io);
    var dst = cwd.createFile(cx.io, part, .{ .truncate = true }) catch return Err.Copy;
    var dst_open = true;
    defer if (dst_open) dst.close(cx.io);
    const buf = a.alloc(u8, @as(usize, cx.cfg.net.copy_chunk_kb) * 1024) catch return Err.OutOfMemory;
    defer a.free(buf);
    var off: u64 = 0;
    while (true) {
        const n = src.readPositional(cx.io, &.{buf}, off) catch return Err.Copy;
        if (n == 0) break;
        dst.writePositionalAll(cx.io, buf[0..n], off) catch return Err.Copy;
        off += n;
    }
    dst.sync(cx.io) catch return Err.Copy;
    dst.close(cx.io);
    dst_open = false;
    cwd.rename(part, cwd, final, cx.io) catch return Err.Rename;
    return .{ .file = file, .url = urlOf(cx, a, file) catch return Err.OutOfMemory };
}

// Threads is done with the file: RENAME it into done_dir (same volume expected). Best effort; the caller logs a failure. Nothing is unlinked.
pub fn finish(cx: *const Ctx, a: std.mem.Allocator, file: []const u8) Err!void {
    if (file.len == 0) return;
    if (std.mem.indexOfAny(u8, file, "/\\") != null or std.mem.indexOf(u8, file, "..") != null) return Err.Rename; // ledger text is never trusted as a path
    if (!configured(cx)) return Err.NoHost;
    const dir = cx.path(a, cx.cfg.host.dir) catch return Err.OutOfMemory;
    const done = cx.path(a, cx.cfg.host.done_dir) catch return Err.OutOfMemory;
    util.mkdirp(cx.io, std.mem.trimEnd(u8, done, "/")) catch return Err.Rename;
    const from = std.fmt.allocPrint(a, "{s}/{s}", .{ std.mem.trimEnd(u8, dir, "/"), file }) catch return Err.OutOfMemory;
    if (!util.exists(cx.io, from)) return; // already moved
    const to = std.fmt.allocPrint(a, "{s}/{s}", .{ std.mem.trimEnd(u8, done, "/"), file }) catch return Err.OutOfMemory;
    const cwd = Io.Dir.cwd();
    cwd.rename(from, cwd, to, cx.io) catch return Err.Rename;
}

pub const Check = struct { ok: bool, note: []const u8 };

fn hostOf(a: std.mem.Allocator, url: []const u8) ![]const u8 {
    const t = guard.parseUrl(a, url, .{ .allow_hosts = &.{}, .any_host = true, .mock = true }) catch return error.BadUrl;
    return t.host;
}

// GET with Range 0-1 on the public URL: expects 200/206 and the right size, never a redirect. A server that ignores Range and sends the whole file is fine (noted).
pub fn selfCheck(cx: *const Ctx, a: std.mem.Allocator, url: []const u8, size: u64) Check {
    const host = hostOf(a, url) catch return .{ .ok = false, .note = "host.base_url is not a usable address" };
    const hosts = [_][]const u8{host};
    const t = guard.parseUrl(a, url, .{ .allow_hosts = &hosts, .mock = cx.mock }) catch |e| return .{ .ok = false, .note = std.fmt.allocPrint(a, "public url refused: {s}", .{@errorName(e)}) catch "public url refused" };
    const ip = guard.pin(cx.io, cx.resolver, t) catch |e| return .{ .ok = false, .note = std.fmt.allocPrint(a, "public url does not resolve to a public address: {s}", .{@errorName(e)}) catch "dns problem" };
    const hs = [_]std.http.Header{.{ .name = "Range", .value = "bytes=0-1" }};
    const r = net.call(cx.io, a, t, ip, .{ .ua = cx.cfg.net.user_agent, .timeout_s = cx.cfg.net.timeout_s, .cap_bytes = 4096, .headers = &hs, .method = "GET" }) catch |e| {
        if (e == net.Err.TooBig) return .{ .ok = true, .note = "host ignores Range and sent the whole file (fine)" };
        return .{ .ok = false, .note = std.fmt.allocPrint(a, "public url not reachable: {s}", .{@errorName(e)}) catch "public url not reachable" };
    };
    if (r.status >= 300 and r.status < 400) return .{ .ok = false, .note = "public url redirects: the host must serve the file directly" };
    if (r.status == 206) {
        const cr = net.headerValue(r.headers, "content-range");
        if (std.mem.lastIndexOfScalar(u8, cr, '/')) |sl| {
            const total = std.fmt.parseInt(u64, cr[sl + 1 ..], 10) catch 0;
            if (total != size) return .{ .ok = false, .note = std.fmt.allocPrint(a, "public url serves {d} bytes, the file has {d}", .{ total, size }) catch "wrong size at the public url" };
        }
        return .{ .ok = true, .note = "reachable" };
    }
    if (r.status == 200) {
        if (@as(u64, r.body.len) != size and r.body.len < 4096 and size > 4096) return .{ .ok = false, .note = "public url answered 200 with the wrong size" };
        return .{ .ok = true, .note = "reachable" };
    }
    return .{ .ok = false, .note = std.fmt.allocPrint(a, "public url answered http {d}", .{r.status}) catch "public url answered an error" };
}

test "random names are 32 hex + .mp4, different each time" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    const cx = @import("co-ctx.zig").testCtx(arena.allocator(), &env, "/h");
    const n1 = try randomName(&cx, arena.allocator());
    const n2 = try randomName(&cx, arena.allocator());
    try std.testing.expectEqual(@as(usize, 36), n1.len);
    try std.testing.expect(std.mem.endsWith(u8, n1, ".mp4"));
    try std.testing.expect(!std.mem.eql(u8, n1, n2));
}

test "finish refuses a path that is not a bare file name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var cx = @import("co-ctx.zig").testCtx(arena.allocator(), &env, "/h");
    cx.cfg.host = .{ .dir = "/h/a", .done_dir = "/h/b", .base_url = "https://x.example/v" };
    try std.testing.expectError(Err.Rename, finish(&cx, arena.allocator(), "../evil.mp4"));
    try std.testing.expectError(Err.Rename, finish(&cx, arena.allocator(), "a/b.mp4"));
    try finish(&cx, arena.allocator(), ""); // nothing hosted: nothing to do
}
