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

const Cand = struct { rel: []const u8, sha: []const u8, data: []const u8, used: bool = false };

// min_bytes: smaller files are never matched; min_sim: % of shared text for a rename + edit (same file name; another name needs +20); max_bytes: bigger files skip the similarity step; cand_max: most candidates per side in the similarity step ----
pub const Opts = struct { min_bytes: u32, min_sim: u32 = 60, max_bytes: u32 = 262144, cand_max: u32 = 200 };

const LEAD: u32 = 15;
const OTHER_NAME_PLUS: u32 = 20;

fn lessMove(_: void, x: Move, y: Move) bool {
    return std.mem.lessThan(u8, x.old, y.old);
}

fn lessCand(_: void, x: Cand, y: Cand) bool {
    const c = std.mem.order(u8, x.sha, y.sha);
    return if (c == .eq) std.mem.lessThan(u8, x.rel, y.rel) else c == .lt;
}

fn leaf(rel: []const u8) []const u8 {
    return std.fs.path.basename(rel);
}

// the same content under many names: pair by file name, only when each name is unique on both sides; every member of the group is used up either way ----
fn pairGroup(a: std.mem.Allocator, os: []Cand, ns: []Cand, out: *std.ArrayList(Move)) MovesErro!void {
    for (os) |*c| c.used = true;
    for (ns) |*c| c.used = true;
    if (os.len == 1 and ns.len == 1) return out.append(a, .{ .sha = os[0].sha, .old = os[0].rel, .new = ns[0].rel });
    if (os.len != ns.len) return;
    for (os) |o| {
        var on: u32 = 0;
        for (os) |x| on += @intFromBool(std.mem.eql(u8, leaf(x.rel), leaf(o.rel)));
        if (on != 1) continue;
        var nn: u32 = 0;
        var hit: usize = 0;
        for (ns, 0..) |x, k| {
            if (std.mem.eql(u8, leaf(x.rel), leaf(o.rel))) {
                nn += 1;
                hit = k;
            }
        }
        if (nn == 1) try out.append(a, .{ .sha = o.sha, .old = o.rel, .new = ns[hit].rel });
    }
}

// text fingerprint: the hash and length of every non-blank line, sorted ----
const Line = struct { h: u64, n: u32 };
const Fp = struct { lines: []Line, total: u64 };

fn lessLine(_: void, x: Line, y: Line) bool {
    return x.h < y.h;
}

fn fingerprint(a: std.mem.Allocator, data: []const u8) MovesErro!Fp {
    var out: std.ArrayList(Line) = .empty;
    var total: u64 = 0;
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |raw| {
        const ln = std.mem.trim(u8, raw, " \t\r");
        if (ln.len == 0) continue;
        try out.append(a, .{ .h = std.hash.Wyhash.hash(0, ln), .n = @intCast(ln.len) });
        total += ln.len;
    }
    std.mem.sort(Line, out.items, {}, lessLine);
    return .{ .lines = out.items, .total = total };
}

// % of text the two files share (matching lines, counted by length, over the longer file) ----
fn score(x: Fp, y: Fp) u32 {
    const big = @max(x.total, y.total);
    if (big == 0) return 0;
    var i: usize = 0;
    var j: usize = 0;
    var shared: u64 = 0;
    while (i < x.lines.len and j < y.lines.len) {
        if (x.lines[i].h == y.lines[j].h) {
            shared += x.lines[i].n;
            i += 1;
            j += 1;
        } else if (x.lines[i].h < y.lines[j].h) i += 1 else j += 1;
    }
    return @intCast(shared * 100 / big);
}

fn eligible(a: std.mem.Allocator, list: []const Cand, o: Opts) MovesErro![]usize {
    var out: std.ArrayList(usize) = .empty;
    for (list, 0..) |c, k| {
        if (c.used or c.data.len > o.max_bytes or std.mem.indexOfScalar(u8, c.data, 0) != null) continue;
        try out.append(a, k);
    }
    return out.items;
}

// rename + edit: a vanished file and a new file that share most of their text, same extension, each the clear best match of the other ----
fn similar(a: std.mem.Allocator, olds: []Cand, news: []Cand, o: Opts, out: *std.ArrayList(Move)) MovesErro!void {
    const oi = try eligible(a, olds, o);
    const ni = try eligible(a, news, o);
    if (oi.len == 0 or ni.len == 0 or oi.len > o.cand_max or ni.len > o.cand_max) return;
    const ofp = try a.alloc(Fp, oi.len);
    const nfp = try a.alloc(Fp, ni.len);
    for (oi, 0..) |k, x| ofp[x] = try fingerprint(a, olds[k].data);
    for (ni, 0..) |k, x| nfp[x] = try fingerprint(a, news[k].data);
    const sc = try a.alloc(u8, oi.len * ni.len);
    @memset(sc, 0);
    for (oi, 0..) |ok, x| {
        for (ni, 0..) |nk, y| {
            const od = olds[ok].data;
            const nd = news[nk].data;
            if (!std.mem.eql(u8, std.fs.path.extension(olds[ok].rel), std.fs.path.extension(news[nk].rel))) continue;
            const lo: u64 = @min(od.len, nd.len);
            const hi: u64 = @max(od.len, nd.len);
            if (lo * 100 < hi * o.min_sim) continue;
            sc[x * ni.len + y] = @intCast(@min(score(ofp[x], nfp[y]), 100));
        }
    }
    for (oi, 0..) |ok, x| {
        var best: u32 = 0;
        var best_y: usize = 0;
        var second: u32 = 0;
        for (0..ni.len) |y| {
            const v: u32 = sc[x * ni.len + y];
            if (v > best) {
                second = best;
                best = v;
                best_y = y;
            } else if (v > second) second = v;
        }
        if (best == 0 or best - second < LEAD) continue;
        var nb: u32 = 0;
        var nb_x: usize = 0;
        var nsec: u32 = 0;
        for (0..oi.len) |x2| {
            const v: u32 = sc[x2 * ni.len + best_y];
            if (v > nb) {
                nsec = nb;
                nb = v;
                nb_x = x2;
            } else if (v > nsec) nsec = v;
        }
        if (nb_x != x or nb - nsec < LEAD) continue;
        const nw = news[ni[best_y]];
        const need: u32 = if (std.mem.eql(u8, leaf(olds[ok].rel), leaf(nw.rel))) o.min_sim else @min(100, o.min_sim + OTHER_NAME_PLUS);
        if (best < need) continue;
        try out.append(a, .{ .sha = olds[ok].sha, .old = olds[ok].rel, .new = nw.rel });
    }
}

// a move needs a vanished old path (agreed before, vault copy unchanged) and a new path (never agreed): the same content (unique, or paired by file name), else mostly the same text; anything unclear is not a move (the old path then just comes back) ----
pub fn detect(a: std.mem.Allocator, bs: *const Map, near: Map, far: Map, retired: []const []const u8, o: Opts) MovesErro![]Move {
    var olds: std.ArrayList(Cand) = .empty;
    var news: std.ArrayList(Cand) = .empty;
    var bit = bs.iterator();
    while (bit.next()) |kv| {
        const rel = kv.key_ptr.*;
        if (near.contains(rel) or !nameOk(rel) or gm.hitAny(retired, rel)) continue;
        const f = far.get(rel) orelse continue;
        if (f.len < o.min_bytes) continue;
        const h = try a.dupe(u8, &sbase.hexOf(f));
        if (!std.mem.eql(u8, h, kv.value_ptr.*)) continue;
        try olds.append(a, .{ .rel = rel, .sha = h, .data = f });
    }
    var nit = near.iterator();
    while (nit.next()) |kv| {
        const rel = kv.key_ptr.*;
        if (far.contains(rel) or bs.contains(rel) or !nameOk(rel) or gm.hitAny(retired, rel)) continue;
        if (kv.value_ptr.*.len < o.min_bytes) continue;
        try news.append(a, .{ .rel = rel, .sha = try a.dupe(u8, &sbase.hexOf(kv.value_ptr.*)), .data = kv.value_ptr.* });
    }
    std.mem.sort(Cand, olds.items, {}, lessCand);
    std.mem.sort(Cand, news.items, {}, lessCand);
    var out: std.ArrayList(Move) = .empty;
    var i: usize = 0;
    var j: usize = 0;
    while (i < olds.items.len and j < news.items.len) {
        const c = std.mem.order(u8, olds.items[i].sha, news.items[j].sha);
        if (c == .lt) {
            i += 1;
            continue;
        }
        if (c == .gt) {
            j += 1;
            continue;
        }
        const sha = olds.items[i].sha;
        var ie = i;
        while (ie < olds.items.len and std.mem.eql(u8, olds.items[ie].sha, sha)) ie += 1;
        var je = j;
        while (je < news.items.len and std.mem.eql(u8, news.items[je].sha, sha)) je += 1;
        try pairGroup(a, olds.items[i..ie], news.items[j..je], &out);
        i = ie;
        j = je;
    }
    try similar(a, olds.items, news.items, o, &out);
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
    const one = try detect(a, &base, near, far, &.{}, .{ .min_bytes = 16 });
    try std.testing.expectEqual(@as(usize, 1), one.len);
    try std.testing.expectEqualStrings("d/old.md", one[0].old);
    try std.testing.expectEqualStrings("d/new.md", one[0].new);
    // the vault copy changed since it was agreed: not an unchanged move
    try far.put(a, "d/old.md", body2);
    try std.testing.expectEqual(@as(usize, 0), (try detect(a, &base, near, far, &.{}, .{ .min_bytes = 16 })).len);
    try far.put(a, "d/old.md", body);
    // two new paths with the same content: ambiguous
    try near.put(a, "d/copy.md", body);
    try std.testing.expectEqual(@as(usize, 0), (try detect(a, &base, near, far, &.{}, .{ .min_bytes = 16 })).len);
    _ = near.remove("d/copy.md");
    // the old path is still here: not a move
    try near.put(a, "d/old.md", body);
    try std.testing.expectEqual(@as(usize, 0), (try detect(a, &base, near, far, &.{}, .{ .min_bytes = 16 })).len);
    _ = near.remove("d/old.md");
    // a tiny file is never matched; a retired old path is left alone
    try std.testing.expectEqual(@as(usize, 0), (try detect(a, &base, near, far, &.{}, .{ .min_bytes = 4096 })).len);
    try std.testing.expectEqual(@as(usize, 0), (try detect(a, &base, near, far, &.{"d/old*"}, .{ .min_bytes = 16 })).len);
    // the new path is already in the vault or already agreed: not new
    try far.put(a, "d/new.md", body);
    try std.testing.expectEqual(@as(usize, 0), (try detect(a, &base, near, far, &.{}, .{ .min_bytes = 16 })).len);
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
    const got = try detect(a, &base, near, far, &.{}, .{ .min_bytes = 16 });
    try std.testing.expectEqual(@as(usize, 3), got.len);
    try std.testing.expectEqualStrings(".old/one.md", got[0].old);
    try std.testing.expectEqualStrings(".new/one.md", got[0].new);
}
fn lines(a: std.mem.Allocator, tag: []const u8, n: usize, edit: usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (0..n) |k| {
        if (k < edit) try out.print(a, "{s} changed line {d} with new words\n", .{ tag, k }) else try out.print(a, "{s} common line number {d} of the document\n", .{ tag, k });
    }
    return out.items;
}

test "detect: rename + edit is a move when most of the text stays; an unrelated file is not" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const old = try lines(a, "x", 20, 0);
    var base: Map = .empty;
    var near: Map = .empty;
    var far: Map = .empty;
    try base.put(a, "d/old.md", try hex(a, old));
    try far.put(a, "d/old.md", old);
    // 2 of 20 lines edited, same file name in another folder
    try near.put(a, "e/old.md", try lines(a, "x", 20, 2));
    const o: Opts = .{ .min_bytes = 16 };
    const one = try detect(a, &base, near, far, &.{}, o);
    try std.testing.expectEqual(@as(usize, 1), one.len);
    try std.testing.expectEqualStrings("d/old.md", one[0].old);
    try std.testing.expectEqualStrings("e/old.md", one[0].new);
    try std.testing.expectEqualStrings(try hex(a, old), one[0].sha);
    // another name needs more shared text: 90% passes, 70% does not
    _ = near.remove("e/old.md");
    try near.put(a, "d/new.md", try lines(a, "x", 20, 2));
    try std.testing.expectEqual(@as(usize, 1), (try detect(a, &base, near, far, &.{}, o)).len);
    try near.put(a, "d/new.md", try lines(a, "x", 20, 6));
    try std.testing.expectEqual(@as(usize, 0), (try detect(a, &base, near, far, &.{}, o)).len);
    // the same low score passes when the file name is the same
    _ = near.remove("d/new.md");
    try near.put(a, "e/old.md", try lines(a, "x", 20, 6));
    try std.testing.expectEqual(@as(usize, 1), (try detect(a, &base, near, far, &.{}, o)).len);
    // an unrelated file, another extension, a binary file and a too-big file: no move
    try near.put(a, "e/old.md", try lines(a, "y", 20, 0));
    try std.testing.expectEqual(@as(usize, 0), (try detect(a, &base, near, far, &.{}, o)).len);
    _ = near.remove("e/old.md");
    try near.put(a, "e/old.txt", try lines(a, "x", 20, 2));
    try std.testing.expectEqual(@as(usize, 0), (try detect(a, &base, near, far, &.{}, o)).len);
    _ = near.remove("e/old.txt");
    try near.put(a, "e/old.md", try lines(a, "x", 20, 2));
    try std.testing.expectEqual(@as(usize, 0), (try detect(a, &base, near, far, &.{}, .{ .min_bytes = 16, .max_bytes = 100 })).len);
    try std.testing.expectEqual(@as(usize, 0), (try detect(a, &base, near, far, &.{}, .{ .min_bytes = 16, .cand_max = 0 })).len);
    try near.put(a, "e/old.md", try std.fmt.allocPrint(a, "{s}\x00bin", .{try lines(a, "x", 20, 2)}));
    try std.testing.expectEqual(@as(usize, 0), (try detect(a, &base, near, far, &.{}, o)).len);
}

test "detect: two vanished files that both look like one new file are not a move" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const o1 = try lines(a, "x", 20, 0);
    const o2 = try lines(a, "x", 20, 1);
    var base: Map = .empty;
    var near: Map = .empty;
    var far: Map = .empty;
    try base.put(a, "d/a.md", try hex(a, o1));
    try far.put(a, "d/a.md", o1);
    try base.put(a, "d/b.md", try hex(a, o2));
    try far.put(a, "d/b.md", o2);
    try near.put(a, "d/c.md", try lines(a, "x", 20, 2));
    try std.testing.expectEqual(@as(usize, 0), (try detect(a, &base, near, far, &.{}, .{ .min_bytes = 16 })).len);
}

test "detect: identical files moved together are paired by file name; a clash is not a move" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const body = "the very same content in several files, long enough";
    var base: Map = .empty;
    var near: Map = .empty;
    var far: Map = .empty;
    for ([_][]const u8{ "x.md", "y.md", "z.md" }) |n| {
        const o = try std.fmt.allocPrint(a, ".old/{s}", .{n});
        try base.put(a, o, try hex(a, body));
        try far.put(a, o, body);
        try near.put(a, try std.fmt.allocPrint(a, ".new/{s}", .{n}), body);
    }
    const got = try detect(a, &base, near, far, &.{}, .{ .min_bytes = 16 });
    try std.testing.expectEqual(@as(usize, 3), got.len);
    try std.testing.expectEqualStrings(".old/x.md", got[0].old);
    try std.testing.expectEqualStrings(".new/x.md", got[0].new);
    try std.testing.expectEqualStrings(".new/z.md", got[2].new);
    // a new name that matches no old name: only the unique pairs move
    _ = near.remove(".new/z.md");
    try near.put(a, ".new/other.md", body);
    const part = try detect(a, &base, near, far, &.{}, .{ .min_bytes = 16 });
    try std.testing.expectEqual(@as(usize, 2), part.len);
    // the same file name twice on one side: that name is ambiguous
    try base.put(a, ".old/sub/x.md", try hex(a, body));
    try far.put(a, ".old/sub/x.md", body);
    try near.put(a, ".new/sub/x.md", body);
    try near.put(a, ".new/z.md", body);
    const amb = try detect(a, &base, near, far, &.{}, .{ .min_bytes = 16 });
    for (amb) |m| try std.testing.expect(!std.mem.endsWith(u8, m.old, "x.md"));
    // different counts on the two sides: a copy was made, nothing moves
    _ = near.remove(".new/sub/x.md");
    _ = near.remove(".new/z.md");
    try std.testing.expectEqual(@as(usize, 0), (try detect(a, &base, near, far, &.{}, .{ .min_bytes = 16 })).len);
}
// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
