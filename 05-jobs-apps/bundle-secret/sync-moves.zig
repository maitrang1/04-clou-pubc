// =====================================================================
// Des: Auto-detects a renamed or moved file (same content, new path) and keeps a tombstone list in the vault, so every device follows the move instead of bringing the old path back
// Flo: old path = agreed before, vault copy unchanged, gone here > new path = only here, never agreed > same sha, exactly one of each = a move > tombstone `sha, old, new` rides inside the bundle under a reserved name
// Cre: 2026-11-16                          - | Mod: 2026-11-16
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: base hashes, near files, far files, retired globs, tombstone text
// Out: Move list | tombstone text | BadFormat
// Run: not run directly - imported by sync-flow.zig
// Exe: n/a
// =====================================================================
const std = @import("std");
const arc = @import("bundle-archive.zig");
const pick = @import("bundle-pick.zig");
const gm = @import("glob-match.zig");
const sbase = @import("sync-base.zig");

// reserved bundle item: never picked from disk, never written to disk ----
pub const KEY = pick.MOVES_KEY;

pub const Move = struct { sha: []const u8, old: []const u8, new: []const u8 };

pub const MovesErro = error{ BadFormat, OutOfMemory };

const Map = std.StringHashMapUnmanaged([]const u8);

pub fn isKey(rel: []const u8) bool {
    return std.mem.eql(u8, rel, KEY);
}

// a name that would break the one-line text format is never a move ----
fn nameOk(rel: []const u8) bool {
    return arc.safePath(rel) and std.mem.indexOfAny(u8, rel, "\t\r\n") == null and !isKey(rel);
}

// lines: `M<TAB>sha<TAB>old<TAB>new` ----
pub fn parse(a: std.mem.Allocator, text: []const u8) MovesErro![]Move {
    var out: std.ArrayList(Move) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |ln| {
        if (ln.len == 0) continue;
        var f = std.mem.splitScalar(u8, ln, '\t');
        const tag = f.next() orelse return error.BadFormat;
        if (!std.mem.eql(u8, tag, "M")) return error.BadFormat;
        const sha = f.next() orelse return error.BadFormat;
        const old = f.next() orelse return error.BadFormat;
        const new = f.next() orelse return error.BadFormat;
        if (f.next() != null or sha.len != 64 or !nameOk(old) or !nameOk(new)) return error.BadFormat;
        for (sha) |c| if (!std.ascii.isHex(c) or std.ascii.isUpper(c)) return error.BadFormat;
        try out.append(a, .{ .sha = try a.dupe(u8, sha), .old = try a.dupe(u8, old), .new = try a.dupe(u8, new) });
    }
    return out.toOwnedSlice(a);
}

pub fn render(a: std.mem.Allocator, moves: []const Move) MovesErro![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (moves) |m| try out.print(a, "M\t{s}\t{s}\t{s}\n", .{ m.sha, m.old, m.new });
    return out.toOwnedSlice(a);
}

// the live tombstone for an old path (the newest one wins) ----
pub fn find(moves: []const Move, old: []const u8) ?Move {
    var i = moves.len;
    while (i > 0) {
        i -= 1;
        if (std.mem.eql(u8, moves[i].old, old)) return moves[i];
    }
    return null;
}

// a path that lives again (moved back) loses its old tombstone; one tombstone per old path ----
pub fn add(a: std.mem.Allocator, list: *std.ArrayList(Move), m: Move) MovesErro!void {
    var i: usize = 0;
    while (i < list.items.len) {
        const x = list.items[i];
        if (std.mem.eql(u8, x.old, m.old) or std.mem.eql(u8, x.old, m.new)) {
            _ = list.orderedRemove(i);
        } else i += 1;
    }
    try list.append(a, m);
}

const Seen = struct { n: u32, rel: []const u8 };
const SeenMap = std.StringHashMapUnmanaged(Seen);

fn tally(a: std.mem.Allocator, m: *SeenMap, sha: []const u8, rel: []const u8) MovesErro!void {
    const got = try m.getOrPut(a, sha);
    if (got.found_existing) got.value_ptr.n += 1 else got.value_ptr.* = .{ .n = 1, .rel = rel };
}

fn lessMove(_: void, x: Move, y: Move) bool {
    return std.mem.lessThan(u8, x.old, y.old);
}

// a move needs exactly one vanished old path and exactly one new path with the same content; anything unclear is not a move (the old path then just comes back) ----
pub fn detect(a: std.mem.Allocator, base: *const Map, near: Map, far: Map, retired: []const []const u8, min_bytes: u32) MovesErro![]Move {
    var olds: SeenMap = .empty;
    var news: SeenMap = .empty;
    var bit = base.iterator();
    while (bit.next()) |kv| {
        const rel = kv.key_ptr.*;
        if (near.contains(rel) or !nameOk(rel) or gm.hitAny(retired, rel)) continue;
        const f = far.get(rel) orelse continue;
        if (f.len < min_bytes) continue;
        const h = try a.dupe(u8, &sbase.hexOf(f));
        if (!std.mem.eql(u8, h, kv.value_ptr.*)) continue;
        try tally(a, &olds, h, rel);
    }
    var nit = near.iterator();
    while (nit.next()) |kv| {
        const rel = kv.key_ptr.*;
        if (far.contains(rel) or base.contains(rel) or !nameOk(rel) or gm.hitAny(retired, rel)) continue;
        if (kv.value_ptr.*.len < min_bytes) continue;
        try tally(a, &news, try a.dupe(u8, &sbase.hexOf(kv.value_ptr.*)), rel);
    }
    var out: std.ArrayList(Move) = .empty;
    var oit = olds.iterator();
    while (oit.next()) |kv| {
        if (kv.value_ptr.n != 1) continue;
        const nw = news.get(kv.key_ptr.*) orelse continue;
        if (nw.n != 1) continue;
        try out.append(a, .{ .sha = kv.key_ptr.*, .old = kv.value_ptr.rel, .new = nw.rel });
    }
    std.mem.sort(Move, out.items, {}, lessMove);
    return out.toOwnedSlice(a);
}

fn hex(a: std.mem.Allocator, data: []const u8) ![]const u8 {
    return a.dupe(u8, &sbase.hexOf(data));
}

test "tombstones: parse and render round trip; a bad line is refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sha = try hex(a, "content");
    const text = try render(a, &.{.{ .sha = sha, .old = "d/old.md", .new = "d/new.md" }});
    const back = try parse(a, text);
    try std.testing.expectEqual(@as(usize, 1), back.len);
    try std.testing.expectEqualStrings("d/old.md", back[0].old);
    try std.testing.expectEqualStrings("d/new.md", back[0].new);
    try std.testing.expectEqualStrings(sha, back[0].sha);
    try std.testing.expectError(error.BadFormat, parse(a, "M\tshort\ta\tb\n"));
    try std.testing.expectError(error.BadFormat, parse(a, try std.fmt.allocPrint(a, "M\t{s}\t../x\tb\n", .{sha})));
    try std.testing.expectError(error.BadFormat, parse(a, try std.fmt.allocPrint(a, "X\t{s}\ta\tb\n", .{sha})));
    try std.testing.expectEqual(@as(usize, 0), (try parse(a, "")).len);
}

test "tombstones: one per old path; a path that lives again loses its tombstone (moved back)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sha = try hex(a, "content");
    var l: std.ArrayList(Move) = .empty;
    try add(a, &l, .{ .sha = sha, .old = "a", .new = "b" });
    try add(a, &l, .{ .sha = sha, .old = "b", .new = "c" });
    try std.testing.expectEqual(@as(usize, 2), l.items.len);
    try std.testing.expectEqualStrings("b", find(l.items, "a").?.new);
    try add(a, &l, .{ .sha = sha, .old = "c", .new = "a" });
    try std.testing.expect(find(l.items, "a") == null);
    try std.testing.expect(find(l.items, "c") != null);
}

test "detect: one vanished path and one new path with the same content is a move; anything unclear is not" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const body = "this content is long enough to count as a real file";
    const body2 = "another long enough content for the second pair here";
    var base: Map = .empty;
    var near: Map = .empty;
    var far: Map = .empty;
    try base.put(a, "d/old.md", try hex(a, body));
    try far.put(a, "d/old.md", body);
    try near.put(a, "d/new.md", body);
    const one = try detect(a, &base, near, far, &.{}, 16);
    try std.testing.expectEqual(@as(usize, 1), one.len);
    try std.testing.expectEqualStrings("d/old.md", one[0].old);
    try std.testing.expectEqualStrings("d/new.md", one[0].new);
    // the vault copy changed since it was agreed: not an unchanged move
    try far.put(a, "d/old.md", body2);
    try std.testing.expectEqual(@as(usize, 0), (try detect(a, &base, near, far, &.{}, 16)).len);
    try far.put(a, "d/old.md", body);
    // two new paths with the same content: ambiguous
    try near.put(a, "d/copy.md", body);
    try std.testing.expectEqual(@as(usize, 0), (try detect(a, &base, near, far, &.{}, 16)).len);
    _ = near.remove("d/copy.md");
    // the old path is still here: not a move
    try near.put(a, "d/old.md", body);
    try std.testing.expectEqual(@as(usize, 0), (try detect(a, &base, near, far, &.{}, 16)).len);
    _ = near.remove("d/old.md");
    // a tiny file is never matched; a retired old path is left alone
    try std.testing.expectEqual(@as(usize, 0), (try detect(a, &base, near, far, &.{}, 4096)).len);
    try std.testing.expectEqual(@as(usize, 0), (try detect(a, &base, near, far, &.{"d/old*"}, 16)).len);
    // the new path is already in the vault or already agreed: not new
    try far.put(a, "d/new.md", body);
    try std.testing.expectEqual(@as(usize, 0), (try detect(a, &base, near, far, &.{}, 16)).len);
}

test "detect: a folder renamed holds one move per file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var base: Map = .empty;
    var near: Map = .empty;
    var far: Map = .empty;
    const names = [_][]const u8{ "one", "two", "three" };
    for (names) |n| {
        const body = try std.fmt.allocPrint(a, "body of the file called {s}, long enough", .{n});
        try base.put(a, try std.fmt.allocPrint(a, ".old/{s}.md", .{n}), try hex(a, body));
        try far.put(a, try std.fmt.allocPrint(a, ".old/{s}.md", .{n}), body);
        try near.put(a, try std.fmt.allocPrint(a, ".new/{s}.md", .{n}), body);
    }
    const got = try detect(a, &base, near, far, &.{}, 16);
    try std.testing.expectEqual(@as(usize, 3), got.len);
    try std.testing.expectEqualStrings(".old/one.md", got[0].old);
    try std.testing.expectEqualStrings(".new/one.md", got[0].new);
}
// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
