// =====================================================================
// Des: Finds renamed or moved files: a file that vanished from one side and a new file on that side with the same content (unique, or paired by file name) or mostly the same text (rename + edit)
// Flo: same hash: one old + one new = a pair; several = pair by unique file name > the rest: line-fingerprint score, same extension, each the clear best match of the other
// Cre: 2026-11-17                          - | Mod: 2026-11-17
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: the vanished files (path, agreed content) and the new files (path, content)
// Out: pairs (index of old, index of new); anything unclear is not a pair
// Run: not run directly - imported by cm-plan.zig
// Exe: n/a
// =====================================================================
const std = @import("std");
const cb = @import("cm-base.zig");

pub const File = struct { rel: []const u8, data: []const u8 };
pub const Pair = struct { old: usize, new: usize };

// min_bytes: smaller files are never matched; min_sim: % of shared text for a rename + edit (same file name; another name needs +20); max_bytes: bigger files skip the similarity step; cand_max: most candidates per side there ----
pub const Opts = struct { min_bytes: u32 = 16, min_sim: u32 = 60, max_bytes: u32 = 262144, cand_max: u32 = 200 };

const LEAD: u32 = 15;
const OTHER_NAME_PLUS: u32 = 20;

const Cand = struct { i: usize, rel: []const u8, sha: []const u8, data: []const u8, used: bool = false };

fn lessCand(_: void, x: Cand, y: Cand) bool {
    const c = std.mem.order(u8, x.sha, y.sha);
    return if (c == .eq) std.mem.lessThan(u8, x.rel, y.rel) else c == .lt;
}

fn leaf(rel: []const u8) []const u8 {
    return std.fs.path.basename(rel);
}

fn cands(a: std.mem.Allocator, list: []const File, o: Opts) ![]Cand {
    var out: std.ArrayList(Cand) = .empty;
    for (list, 0..) |f, i| {
        if (f.data.len < o.min_bytes) continue;
        try out.append(a, .{ .i = i, .rel = f.rel, .sha = try a.dupe(u8, &cb.hexOf(f.data)), .data = f.data });
    }
    std.mem.sort(Cand, out.items, {}, lessCand);
    return out.items;
}

// the same content under many names: pair by file name, only when each name is unique on both sides; every member is used up either way ----
fn pairGroup(a: std.mem.Allocator, os: []Cand, ns: []Cand, out: *std.ArrayList(Pair)) !void {
    for (os) |*c| c.used = true;
    for (ns) |*c| c.used = true;
    if (os.len == 1 and ns.len == 1) return out.append(a, .{ .old = os[0].i, .new = ns[0].i });
    if (os.len != ns.len) return;
    for (os) |o| {
        var on: u32 = 0;
        for (os) |x| on += @intFromBool(std.mem.eql(u8, leaf(x.rel), leaf(o.rel)));
        if (on != 1) continue;
        var nn: u32 = 0;
        var hit: usize = 0;
        for (ns) |x| {
            if (std.mem.eql(u8, leaf(x.rel), leaf(o.rel))) {
                nn += 1;
                hit = x.i;
            }
        }
        if (nn == 1) try out.append(a, .{ .old = o.i, .new = hit });
    }
}

const Line = struct { h: u64, n: u32 };
const Fp = struct { lines: []Line, total: u64 };

fn lessLine(_: void, x: Line, y: Line) bool {
    return x.h < y.h;
}

fn fingerprint(a: std.mem.Allocator, data: []const u8) !Fp {
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

fn eligible(a: std.mem.Allocator, list: []const Cand, o: Opts) ![]usize {
    var out: std.ArrayList(usize) = .empty;
    for (list, 0..) |c, k| {
        if (c.used or c.data.len > o.max_bytes or std.mem.indexOfScalar(u8, c.data, 0) != null) continue;
        try out.append(a, k);
    }
    return out.items;
}

fn similar(a: std.mem.Allocator, olds: []Cand, news: []Cand, o: Opts, out: *std.ArrayList(Pair)) !void {
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
        try out.append(a, .{ .old = olds[ok].i, .new = nw.i });
    }
}

fn lessPair(_: void, x: Pair, y: Pair) bool {
    return x.old < y.old;
}

pub fn find(a: std.mem.Allocator, olds: []const File, news: []const File, o: Opts) ![]Pair {
    const oc = try cands(a, olds, o);
    const nc = try cands(a, news, o);
    var out: std.ArrayList(Pair) = .empty;
    var i: usize = 0;
    var j: usize = 0;
    while (i < oc.len and j < nc.len) {
        const c = std.mem.order(u8, oc[i].sha, nc[j].sha);
        if (c == .lt) {
            i += 1;
            continue;
        }
        if (c == .gt) {
            j += 1;
            continue;
        }
        const sha = oc[i].sha;
        var ie = i;
        while (ie < oc.len and std.mem.eql(u8, oc[ie].sha, sha)) ie += 1;
        var je = j;
        while (je < nc.len and std.mem.eql(u8, nc[je].sha, sha)) je += 1;
        try pairGroup(a, oc[i..ie], nc[j..je], &out);
        i = ie;
        j = je;
    }
    try similar(a, oc, nc, o, &out);
    std.mem.sort(Pair, out.items, {}, lessPair);
    return out.items;
}

fn lines(a: std.mem.Allocator, tag: []const u8, n: usize, edit: usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (0..n) |k| {
        if (k < edit) try out.print(a, "{s} changed line {d} with new words\n", .{ tag, k }) else try out.print(a, "{s} common line number {d} of the document\n", .{ tag, k });
    }
    return out.items;
}

test "find: same content is a pair; copies are not; a tiny file is never matched" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const body = "this content is long enough to count as a real file";
    const one = try find(a, &.{.{ .rel = "a.md", .data = body }}, &.{.{ .rel = "b.md", .data = body }}, .{});
    try std.testing.expectEqual(@as(usize, 1), one.len);
    try std.testing.expectEqual(@as(usize, 0), one[0].new);
    const copy = try find(a, &.{.{ .rel = "a.md", .data = body }}, &.{ .{ .rel = "b.md", .data = body }, .{ .rel = "c.md", .data = body } }, .{});
    try std.testing.expectEqual(@as(usize, 0), copy.len);
    try std.testing.expectEqual(@as(usize, 0), (try find(a, &.{.{ .rel = "a.md", .data = "tiny" }}, &.{.{ .rel = "b.md", .data = "tiny" }}, .{})).len);
}

test "find: identical files moved together are paired by file name; a name clash is not a pair" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const body = "the very same content in several files, long enough";
    const olds = [_]File{ .{ .rel = "o/x.md", .data = body }, .{ .rel = "o/y.md", .data = body } };
    const news = [_]File{ .{ .rel = "n/y.md", .data = body }, .{ .rel = "n/x.md", .data = body } };
    const got = try find(a, &olds, &news, .{});
    try std.testing.expectEqual(@as(usize, 2), got.len);
    try std.testing.expectEqual(@as(usize, 1), got[0].new);
    try std.testing.expectEqual(@as(usize, 0), got[1].new);
    const clash = [_]File{ .{ .rel = "o/x.md", .data = body }, .{ .rel = "o/s/x.md", .data = body } };
    try std.testing.expectEqual(@as(usize, 0), (try find(a, &clash, &news, .{})).len);
}

test "find: rename + edit is a pair when most of the text stays; unrelated, other extension, binary and too big are not" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const old = try lines(a, "x", 20, 0);
    const olds = [_]File{.{ .rel = "d/old.md", .data = old }};
    try std.testing.expectEqual(@as(usize, 1), (try find(a, &olds, &.{.{ .rel = "e/old.md", .data = try lines(a, "x", 20, 2) }}, .{})).len);
    try std.testing.expectEqual(@as(usize, 1), (try find(a, &olds, &.{.{ .rel = "d/new.md", .data = try lines(a, "x", 20, 2) }}, .{})).len);
    // another name needs more shared text than the same name
    try std.testing.expectEqual(@as(usize, 0), (try find(a, &olds, &.{.{ .rel = "d/new.md", .data = try lines(a, "x", 20, 6) }}, .{})).len);
    try std.testing.expectEqual(@as(usize, 1), (try find(a, &olds, &.{.{ .rel = "e/old.md", .data = try lines(a, "x", 20, 6) }}, .{})).len);
    try std.testing.expectEqual(@as(usize, 0), (try find(a, &olds, &.{.{ .rel = "e/old.md", .data = try lines(a, "y", 20, 0) }}, .{})).len);
    try std.testing.expectEqual(@as(usize, 0), (try find(a, &olds, &.{.{ .rel = "e/old.txt", .data = try lines(a, "x", 20, 2) }}, .{})).len);
    try std.testing.expectEqual(@as(usize, 0), (try find(a, &olds, &.{.{ .rel = "e/old.md", .data = try lines(a, "x", 20, 2) }}, .{ .max_bytes = 100 })).len);
    const bin = try std.fmt.allocPrint(a, "{s}\x00bin", .{try lines(a, "x", 20, 2)});
    try std.testing.expectEqual(@as(usize, 0), (try find(a, &olds, &.{.{ .rel = "e/old.md", .data = bin }}, .{})).len);
}

test "find: two vanished files that both look like one new file are not a pair" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const olds = [_]File{ .{ .rel = "d/a.md", .data = try lines(a, "x", 20, 0) }, .{ .rel = "d/b.md", .data = try lines(a, "x", 20, 1) } };
    try std.testing.expectEqual(@as(usize, 0), (try find(a, &olds, &.{.{ .rel = "d/c.md", .data = try lines(a, "x", 20, 2) }}, .{})).len);
}
// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
