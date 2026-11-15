// =====================================================================
// Des: Builds the YouTube title, description and tags from the producer's json fields - strips angle brackets, cuts to the real limits (characters for the title, BYTES for the description) and never cuts the AI notice
// Flo: clean fields > title (cut at a word) > description parts + notice (budget in bytes) > hashtags normalized and capped > tags by the 500-character rule
// Cre: 2026-11-15                          - | Mod: 2026-11-15
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: hooks, description, hashtags, listing_url, ai_notice, config post limits
// Out: Text {title, description, tags} (arena-owned) | error NoTitle / NoNotice / NoticeTooLong
// Run: not run directly - imported by rw-pair, cm-publish
// =====================================================================
const std = @import("std");
const cfg_mod = @import("co-cfg.zig");

pub const Err = error{ NoTitle, NoNotice, NoticeTooLong, OutOfMemory };

pub const Fields = struct {
    hooks: []const []const u8 = &.{},
    description: []const u8 = "",
    hashtags: []const []const u8 = &.{},
    listing_url: []const u8 = "",
    ai_notice: []const u8 = "",
};

pub const Text = struct { title: []const u8, description: []const u8, tags: []const []const u8 };

// drop < and > (YouTube refuses them), turn line breaks into spaces, collapse spaces
fn cleanLine(a: std.mem.Allocator, s: []const u8) ![]u8 {
    var o: std.ArrayList(u8) = .empty;
    var last_space = true;
    for (s) |ch| {
        if (ch == '<' or ch == '>') continue;
        const sp = ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r';
        if (sp) {
            if (!last_space) try o.append(a, ' ');
            last_space = true;
        } else {
            try o.append(a, ch);
            last_space = false;
        }
    }
    while (o.items.len > 0 and o.items[o.items.len - 1] == ' ') _ = o.pop();
    return o.toOwnedSlice(a);
}

// description keeps its line breaks; only < > are removed and CR dropped
fn cleanBlock(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    var o: std.ArrayList(u8) = .empty;
    for (s) |ch| {
        if (ch == '<' or ch == '>' or ch == '\r') continue;
        try o.append(a, ch);
    }
    return std.mem.trim(u8, try o.toOwnedSlice(a), " \n\t");
}

// byte length of the longest prefix that is <= max_bytes, ends on a UTF-8 boundary and (when it must cut) on a space
fn cutBytes(s: []const u8, max_bytes: usize) []const u8 {
    if (s.len <= max_bytes) return s;
    var n = max_bytes;
    while (n > 0 and (s[n] & 0xC0) == 0x80) n -= 1; // never inside a character
    const head = s[0..n];
    if (std.mem.lastIndexOfAny(u8, head, " \n")) |sp| if (sp > 0) return std.mem.trimEnd(u8, head[0..sp], " \n");
    return std.mem.trimEnd(u8, head, " \n");
}

// longest prefix of at most max_chars characters, cut at a space when it must cut
fn cutChars(s: []const u8, max_chars: usize) []const u8 {
    var count: usize = 0;
    var i: usize = 0;
    var last_space: usize = 0;
    while (i < s.len) {
        const l = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        if (count == max_chars) break;
        if (s[i] == ' ') last_space = i;
        i += @min(l, s.len - i);
        count += 1;
    }
    if (i >= s.len) return s;
    const head = s[0..i];
    if (s[i] == ' ') return std.mem.trimEnd(u8, head, " "); // the cut already falls between words
    if (last_space > 0) return std.mem.trimEnd(u8, s[0..last_space], " ");
    return std.mem.trimEnd(u8, head, " ");
}

// hashtag: no '#', no spaces or angle brackets, no duplicates (case-insensitive)
fn normTags(a: std.mem.Allocator, raw: []const []const u8, max_n: u32) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (raw) |r| {
        if (out.items.len >= max_n) break;
        var t: std.ArrayList(u8) = .empty;
        for (r) |ch| {
            if (ch == '#' or ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r' or ch == '<' or ch == '>' or ch == ',') continue;
            try t.append(a, ch);
        }
        if (t.items.len == 0) continue;
        var dup = false;
        for (out.items) |o| if (std.ascii.eqlIgnoreCase(o, t.items)) {
            dup = true;
            break;
        };
        if (!dup) try out.append(a, try t.toOwnedSlice(a));
    }
    return out.toOwnedSlice(a);
}

pub fn build(a: std.mem.Allocator, f: Fields, p: cfg_mod.Post) Err!Text {
    const notice = try cleanBlock(a, f.ai_notice);
    if (p.ai_notice_required and notice.len == 0) return Err.NoNotice;
    // title: first hook, else first line of the description; never invented
    var raw_title: []const u8 = "";
    for (f.hooks) |h| {
        const t = try cleanLine(a, h);
        if (t.len > 0) {
            raw_title = t;
            break;
        }
    }
    if (raw_title.len == 0) {
        const first = std.mem.sliceTo(f.description, '\n');
        raw_title = try cleanLine(a, first);
    }
    if (raw_title.len == 0) return Err.NoTitle;
    const tag_suffix: []const u8 = if (p.shorts_tag) " #Shorts" else "";
    const room: usize = if (p.title_max > tag_suffix.len + 1) p.title_max - tag_suffix.len else p.title_max;
    const cut_title = cutChars(raw_title, room);
    const title = try std.fmt.allocPrint(a, "{s}{s}", .{ cut_title, tag_suffix });

    // hashtags + tags
    const tags_n = try normTags(a, f.hashtags, p.hashtags_max);
    var tag_line: std.ArrayList(u8) = .empty;
    for (tags_n, 0..) |t, i| {
        if (i > 0) try tag_line.append(a, ' ');
        try tag_line.print(a, "#{s}", .{t});
    }
    var tags: std.ArrayList([]const u8) = .empty;
    var used: usize = 0;
    for (tags_n) |t| {
        const chars = std.unicode.utf8CountCodepoints(t) catch t.len;
        const cost = chars + (if (std.mem.indexOfScalar(u8, t, ' ') != null) @as(usize, 2) else 0) + (if (tags.items.len > 0) @as(usize, 1) else 0);
        if (used + cost > p.tags_max_chars) break;
        used += cost;
        try tags.append(a, t);
    }

    // description: [body] [hashtags] [url] then the notice, which is never cut
    const body = try cleanBlock(a, f.description);
    const url = try cleanLine(a, f.listing_url);
    var tail: std.ArrayList(u8) = .empty;
    if (notice.len > 0) try tail.print(a, "\n\n{s}", .{notice});
    if (tail.items.len > p.desc_max_bytes) return Err.NoticeTooLong;
    var head: std.ArrayList(u8) = .empty;
    try head.appendSlice(a, body);
    if (tag_line.items.len > 0) {
        if (head.items.len > 0) try head.appendSlice(a, "\n\n");
        try head.appendSlice(a, tag_line.items);
    }
    if (url.len > 0) {
        if (head.items.len > 0) try head.appendSlice(a, "\n\n");
        try head.appendSlice(a, url);
    }
    const budget = p.desc_max_bytes - tail.items.len;
    const head_cut = cutBytes(head.items, budget);
    var desc: std.ArrayList(u8) = .empty;
    if (head_cut.len > 0) {
        try desc.appendSlice(a, head_cut);
        try desc.appendSlice(a, tail.items);
    } else {
        try desc.appendSlice(a, std.mem.trimStart(u8, tail.items, "\n"));
    }
    return .{ .title = title, .description = try desc.toOwnedSlice(a), .tags = try tags.toOwnedSlice(a) };
}

fn arenaT() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(std.testing.allocator);
}

test "title: first hook, angle brackets gone, cut at a word within 100 chars" {
    var ar = arenaT();
    defer ar.deinit();
    const a = ar.allocator();
    const t = try build(a, .{ .hooks = &.{ "<b>Xe đẹp</b>  giá   tốt", "other" }, .ai_notice = "AI" }, .{});
    try std.testing.expectEqualStrings("bXe đẹp/b giá tốt", t.title);
    const long = "word " ** 40;
    const t2 = try build(a, .{ .hooks = &.{long}, .ai_notice = "AI" }, .{});
    try std.testing.expect((std.unicode.utf8CountCodepoints(t2.title) catch 999) <= 100);
    try std.testing.expect(std.mem.endsWith(u8, t2.title, "word"));
    // multi-byte: 100 characters is not 100 bytes
    const vn = "đ" ** 150;
    const t3 = try build(a, .{ .hooks = &.{vn}, .ai_notice = "AI" }, .{});
    try std.testing.expectEqual(@as(usize, 100), std.unicode.utf8CountCodepoints(t3.title) catch 0);
    try std.testing.expectError(Err.NoTitle, build(a, .{ .ai_notice = "AI" }, .{}));
}

test "shorts_tag reserves room inside the title limit" {
    var ar = arenaT();
    defer ar.deinit();
    const a = ar.allocator();
    const t = try build(a, .{ .hooks = &.{"word " ** 40}, .ai_notice = "AI" }, .{ .shorts_tag = true });
    try std.testing.expect(std.mem.endsWith(u8, t.title, " #Shorts"));
    try std.testing.expect((std.unicode.utf8CountCodepoints(t.title) catch 999) <= 100);
}

test "description limit is in BYTES, the notice survives, the cut is on a character" {
    var ar = arenaT();
    defer ar.deinit();
    const a = ar.allocator();
    const notice = "Video tạo bằng AI.";
    const big = "Xe rất đẹp, giá tốt. " ** 400; // far over 5000 bytes, multi-byte
    const t = try build(a, .{ .hooks = &.{"h"}, .description = big, .hashtags = &.{ "#xe", "gia tot" }, .ai_notice = notice }, .{});
    try std.testing.expect(t.description.len <= 5000);
    try std.testing.expect(std.mem.endsWith(u8, t.description, notice));
    try std.testing.expect(std.unicode.utf8ValidateSlice(t.description));
    // small description keeps everything in order
    const s = try build(a, .{ .hooks = &.{"h"}, .description = "Body", .hashtags = &.{"xe"}, .listing_url = "https://a.b/c", .ai_notice = "N" }, .{});
    try std.testing.expectEqualStrings("Body\n\n#xe\n\nhttps://a.b/c\n\nN", s.description);
    // a notice that cannot fit is an error, not a silent cut
    try std.testing.expectError(Err.NoticeTooLong, build(a, .{ .hooks = &.{"h"}, .ai_notice = "x" ** 5001 }, .{}));
    try std.testing.expectError(Err.NoNotice, build(a, .{ .hooks = &.{"h"} }, .{}));
}

test "tags: no hash or spaces, dedup, count cap, 500 char rule with commas" {
    var ar = arenaT();
    defer ar.deinit();
    const a = ar.allocator();
    const t = try build(a, .{ .hooks = &.{"h"}, .hashtags = &.{ "#Xe", "xe", "gia tot", "<b>", "a,b" }, .ai_notice = "N" }, .{});
    try std.testing.expectEqual(@as(usize, 4), t.tags.len);
    try std.testing.expectEqualStrings("Xe", t.tags[0]);
    try std.testing.expectEqualStrings("giatot", t.tags[1]);
    try std.testing.expectEqualStrings("b", t.tags[2]);
    try std.testing.expectEqualStrings("ab", t.tags[3]);
    var many: [30][]const u8 = undefined;
    for (&many, 0..) |*m, i| m.* = std.fmt.allocPrint(a, "tag{d}", .{i}) catch "x";
    const t2 = try build(a, .{ .hooks = &.{"h"}, .hashtags = &many, .ai_notice = "N" }, .{ .hashtags_max = 15 });
    try std.testing.expectEqual(@as(usize, 15), t2.tags.len);
    const t3 = try build(a, .{ .hooks = &.{"h"}, .hashtags = &.{ "aaaaaaaaaa", "bbbbbbbbbb" }, .ai_notice = "N" }, .{ .tags_max_chars = 15 });
    try std.testing.expectEqual(@as(usize, 1), t3.tags.len); // 10 + (10+1 comma) = 21 > 15
}

test "never invents: title falls back to the description's first line only" {
    var ar = arenaT();
    defer ar.deinit();
    const a = ar.allocator();
    const t = try build(a, .{ .description = "First line\nSecond", .ai_notice = "N" }, .{});
    try std.testing.expectEqualStrings("First line", t.title);
}
// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
