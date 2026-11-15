// =====================================================================
// Des: The rotating login file - access token, refresh token and their times in one private file; X's refresh token is single-use, so a new one is written to login.new first (fsync) and only then renamed over the old file, and a start prefers the newer valid file after a crash
// Flo: read both files > pick the newer valid one (promote login.new) | save: write login.new atomically > rename over the login file
// Cre: 2026-11-16                          - | Mod: 2026-11-16
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: Ctx (secrets folder, account.login_file), a Login
// Out: Login | null; the login file (mode 600) - tokens are never printed or logged
// Run: not run directly - imported by ap-auth, cm-auth, cm-token, cm-doctor
// =====================================================================
const std = @import("std");
const ctx_mod = @import("co-ctx.zig");
const util = @import("co-util.zig");

pub const Login = struct {
    access: []const u8,
    refresh: []const u8,
    expires_ms: i64, // when the access token ends
    issued_ms: i64, // when this pair was issued (the newer pair wins after a crash)
};

pub fn parse(a: std.mem.Allocator, text: []const u8) ?Login {
    var access: []const u8 = "";
    var refresh: []const u8 = "";
    var expires: i64 = 0;
    var issued: i64 = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const k = line[0..eq];
        const v = line[eq + 1 ..];
        if (std.mem.eql(u8, k, "access")) access = a.dupe(u8, v) catch return null;
        if (std.mem.eql(u8, k, "refresh")) refresh = a.dupe(u8, v) catch return null;
        if (std.mem.eql(u8, k, "expires")) expires = std.fmt.parseInt(i64, v, 10) catch return null;
        if (std.mem.eql(u8, k, "issued")) issued = std.fmt.parseInt(i64, v, 10) catch return null;
    }
    if (access.len == 0 or refresh.len == 0 or issued == 0) return null;
    return .{ .access = access, .refresh = refresh, .expires_ms = expires, .issued_ms = issued };
}

pub fn serialize(a: std.mem.Allocator, l: Login) ![]u8 {
    return std.fmt.allocPrint(a, "v1\naccess={s}\nrefresh={s}\nexpires={d}\nissued={d}\n", .{ l.access, l.refresh, l.expires_ms, l.issued_ms });
}

pub fn path(cx: *const ctx_mod.Ctx, a: std.mem.Allocator) ![]u8 {
    return cx.secretPath(a, cx.cfg.account.login_file);
}

pub fn pathNew(cx: *const ctx_mod.Ctx, a: std.mem.Allocator) ![]u8 {
    return std.fmt.allocPrint(a, "{s}/{s}.new", .{ cx.secrets_dir, cx.cfg.account.login_file });
}

fn readOne(cx: *const ctx_mod.Ctx, a: std.mem.Allocator, p: []const u8) ?Login {
    const t = util.readAll(a, cx.io, p, 16 * 1024) catch return null;
    return parse(a, t);
}

// the best login on disk: login.new when it is newer and valid (a crash between the answer and the rename), else the main file
pub fn read(cx: *const ctx_mod.Ctx, a: std.mem.Allocator) ?Login {
    const main_p = path(cx, a) catch return null;
    const new_p = pathNew(cx, a) catch return null;
    const m = readOne(cx, a, main_p);
    const n = readOne(cx, a, new_p);
    if (n) |nn| {
        if (m == null or nn.issued_ms > m.?.issued_ms) {
            // finish the interrupted rename; if it fails the new one is still used from memory
            std.Io.Dir.cwd().rename(new_p, std.Io.Dir.cwd(), main_p, cx.io) catch {};
            return nn;
        }
    }
    return m;
}

pub const SaveErr = error{ NoDir, Write, OutOfMemory };

// login.new first (fsync inside writeAtomicMode), then the rename: a crash leaves one valid file or the other, never half
pub fn save(cx: *const ctx_mod.Ctx, a: std.mem.Allocator, l: Login) SaveErr!void {
    util.mkdirp(cx.io, cx.secrets_dir) catch return SaveErr.NoDir;
    const main_p = path(cx, a) catch return SaveErr.OutOfMemory;
    const new_p = pathNew(cx, a) catch return SaveErr.OutOfMemory;
    const body = serialize(a, l) catch return SaveErr.OutOfMemory;
    util.writeAtomicMode(a, cx.io, new_p, body, 0o600) catch return SaveErr.Write;
    std.Io.Dir.cwd().rename(new_p, std.Io.Dir.cwd(), main_p, cx.io) catch return SaveErr.Write;
}

// days since this pair was issued (the refresh token lives about 6 months from its issue)
pub fn ageDays(l: Login, now: i64) i64 {
    return @divFloor(now - l.issued_ms, 86_400_000);
}

test "serialize and parse round trip; junk and missing fields are refused" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const l = Login{ .access = "AT", .refresh = "RT", .expires_ms = 100, .issued_ms = 50 };
    const p = parse(a, try serialize(a, l)).?;
    try std.testing.expectEqualStrings("AT", p.access);
    try std.testing.expectEqualStrings("RT", p.refresh);
    try std.testing.expectEqual(@as(i64, 100), p.expires_ms);
    try std.testing.expect(parse(a, "garbage") == null);
    try std.testing.expect(parse(a, "access=a\nrefresh=\nissued=1\n") == null);
    try std.testing.expect(parse(a, "access=a\nrefresh=b\nissued=x\n") == null);
}

test "save writes login.new then renames; a leftover newer login.new wins after a crash" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    var env = std.process.Environ.Map.init(a);
    const cx = ctx_mod.testCtx(a, &env, dir);
    try std.testing.expect(read(&cx, a) == null);
    try save(&cx, a, .{ .access = "AT-1", .refresh = "RT-1", .expires_ms = 1000, .issued_ms = 10 });
    try std.testing.expectEqualStrings("RT-1", read(&cx, a).?.refresh);
    try std.testing.expect(!util.exists(cx.io, try pathNew(&cx, a))); // the rename consumed login.new
    // a crash after the refresh answer: login.new holds the newer pair, the main file the dead one
    try std.Io.Dir.cwd().writeFile(cx.io, .{ .sub_path = try pathNew(&cx, a), .data = "v1\naccess=AT-2\nrefresh=RT-2\nexpires=2000\nissued=20\n" });
    const r = read(&cx, a).?;
    try std.testing.expectEqualStrings("RT-2", r.refresh);
    try std.testing.expect(!util.exists(cx.io, try pathNew(&cx, a))); // promoted
    try std.testing.expectEqualStrings("RT-2", read(&cx, a).?.refresh);
    // an OLDER login.new (stale leftover) never beats the main file
    try std.Io.Dir.cwd().writeFile(cx.io, .{ .sub_path = try pathNew(&cx, a), .data = "v1\naccess=AT-0\nrefresh=RT-0\nexpires=1\nissued=5\n" });
    try std.testing.expectEqualStrings("RT-2", read(&cx, a).?.refresh);
    // a half-written login.new is ignored
    try std.Io.Dir.cwd().writeFile(cx.io, .{ .sub_path = try pathNew(&cx, a), .data = "v1\naccess=AT-9\nrefr" });
    try std.testing.expectEqualStrings("RT-2", read(&cx, a).?.refresh);
}
// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
