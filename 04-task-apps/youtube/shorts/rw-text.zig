// =====================================================================
// Des: Builds the YouTube title, description and tags from the producer's json fields - strips angle brackets, cuts to the real limits (characters for the title, BYTES for the description) and never cuts the AI notice
// Flo: clean fields > title ("{brand} {model} {year}. {hook}", Title Case, only the hook is cut) > description parts + notice (budget in bytes) > hashtags normalized and capped > tags by the 500-character rule
// Cre: 2026-11-15                          - | Mod: 2026-11-16
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: brand, model, year, hooks, description, hashtags, listing_url, ai_notice, config post limits
// Out: Text {title, description, tags} (arena-owned) | error NoTitle / NoNotice / NoticeTooLong
// Run: not run directly - imported by rw-pair, cm-publish
// =====================================================================
const std = @import("std");
const cfg_mod = @import("co-cfg.zig");

pub const Err = error{ NoTitle, NoNotice, NoticeTooLong, OutOfMemory };

pub const Fields = struct {
    brand: []const u8 = "",
    model: []const u8 = "",
    year: u32 = 0,
    hooks: []const []const u8 = &.{},
    description: []const u8 = "",
    hashtags: []const []const u8 = &.{},
    listing_url: []const u8 = "",
    ai_notice: []const u8 = "",
    title: []const u8 = "",
};

pub const Name = struct { brand: []const u8 = "", model: []const u8 = "", year: u32 = 0 };

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

// lowercase letter > capital for Latin incl. Vietnamese (ă â đ ê ô ơ ư, tone marks); anything else unchanged
fn upperCp(c: u21) u21 {
    return switch (c) {
        'a'...'z' => c - 32,
        0xE0...0xF6, 0xF8...0xFE => c - 32,
        0xFF => 0x178,
        0x101...0x12F, 0x133...0x137, 0x14B...0x177, 0x1E01...0x1E95, 0x1EA1...0x1EF9 => if (c & 1 == 1) c - 1 else c,
        0x13A...0x148, 0x17A...0x17E => if (c & 1 == 0) c - 1 else c,
        0x1A1, 0x1B0 => c - 1,
        else => c,
    };
}

// first letter of every word upper, the rest as written (SUV, VF3, CR-V, VinFast stay); a leading ( or " is skipped
const units = [_][]const u8{ "km", "kg", "cc", "kw", "hp", "mm", "cm", "l" };
const number_words = [_][]const u8{ "không", "một", "hai", "ba", "bốn", "sáu", "bảy", "tám", "chín", "mười", "mươi", "trăm", "nghìn", "ngàn", "triệu", "tỷ", "lăm" };

fn core(w: []const u8) []const u8 {
    return std.mem.trim(u8, w, ",.;:!?()\"");
}

fn hasDigit(w: []const u8) bool {
    for (w) |c| if (c >= '0' and c <= '9') return true;
    return false;
}

fn lowerEq(w: []const u8, list: []const []const u8) bool {
    var buf: [32]u8 = undefined;
    if (w.len == 0 or w.len > buf.len) return false;
    const lw = std.ascii.lowerString(&buf, w);
    for (list) |x| if (std.mem.eql(u8, lw, x)) return true;
    return false;
}

// how many spelled-out number words a hook has ("Ba mươi hai nghìn km" = 4); 2 or more = voice-over text, not a title
pub fn spelledNumbers(s: []const u8) usize {
    var n: usize = 0;
    var it = std.mem.tokenizeScalar(u8, s, ' ');
    while (it.next()) |w| if (lowerEq(core(w), &number_words)) {
        n += 1;
    };
    return n;
}

// the first (cleaned) hook that reads like a title (no spelled-out number); else the first hook
fn pickHook(a: std.mem.Allocator, hooks: []const []const u8) ![]const u8 {
    var first: []const u8 = "";
    for (hooks) |h| {
        const t = try cleanLine(a, h);
        if (t.len == 0) continue;
        if (first.len == 0) first = t;
        if (spelledNumbers(t) < 2) return t;
    }
    return first;
}

// Title Case per word; a unit after a number stays lowercase (30.000 km)
fn titleCase(a: std.mem.Allocator, s: []const u8) ![]u8 {
    var o: std.ArrayList(u8) = .empty;
    var words = std.mem.splitScalar(u8, s, ' ');
    var first = true;
    var prev_digit = false;
    while (words.next()) |w| {
        if (!first) try o.append(a, ' ');
        first = false;
        defer prev_digit = hasDigit(w);
        if (prev_digit and lowerEq(core(w), &units)) {
            for (w) |c| try o.append(a, std.ascii.toLower(c));
        } else {
            const t = try titleWord(a, w);
            try o.appendSlice(a, t);
        }
    }
    return o.toOwnedSlice(a);
}

fn titleWord(a: std.mem.Allocator, s: []const u8) ![]u8 {
    var o: std.ArrayList(u8) = .empty;
    var start = true;
    var i: usize = 0;
    while (i < s.len) {
        const l = @min(std.unicode.utf8ByteSequenceLength(s[i]) catch 1, s.len - i);
        const cp = std.unicode.utf8Decode(s[i .. i + l]) catch {
            try o.appendSlice(a, s[i .. i + l]);
            start = false;
            i += l;
            continue;
        };
        if (cp == ' ') {
            start = true;
            try o.append(a, ' ');
        } else if (start and cp < 0x80 and !std.ascii.isAlphanumeric(@intCast(cp))) {
            try o.append(a, @intCast(cp));
        } else {
            const u = if (start) upperCp(cp) else cp;
            start = false;
            var buf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(u, &buf) catch 0;
            try o.appendSlice(a, if (n > 0) buf[0..n] else s[i .. i + l]);
        }
        i += l;
    }
    return o.toOwnedSlice(a);
}

fn charCount(s: []const u8) usize {
    return std.unicode.utf8CountCodepoints(s) catch s.len;
}

// one side of the pattern with {brand} {model} {year} filled in; null when one of them is missing
fn expandSide(a: std.mem.Allocator, seg: []const u8, nm: Name) !?[]u8 {
    var o: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < seg.len) {
        if (seg[i] != '{') {
            try o.append(a, seg[i]);
            i += 1;
            continue;
        }
        const e = std.mem.indexOfScalarPos(u8, seg, i, '}') orelse return null;
        const key = seg[i + 1 .. e];
        if (std.mem.eql(u8, key, "year")) {
            if (nm.year == 0) return null;
            try o.print(a, "{d}", .{nm.year});
        } else {
            const v = if (std.mem.eql(u8, key, "brand")) nm.brand else if (std.mem.eql(u8, key, "model")) nm.model else "";
            if (v.len == 0) return null;
            try o.appendSlice(a, v);
        }
        i = e + 1;
    }
    return try o.toOwnedSlice(a);
}

// drop a trailing separator left by a cut: space , . ; : - / | and the long dashes
fn trimSep(s: []const u8) []const u8 {
    var e = s.len;
    while (e > 0) {
        if (std.mem.indexOfScalar(u8, " ,.;:-/|", s[e - 1]) != null) e -= 1 else if (std.mem.endsWith(u8, s[0..e], "\u{2013}") or std.mem.endsWith(u8, s[0..e], "\u{2014}")) e -= 3 else break;
    }
    return s[0..e];
}

pub const TitleIn = struct { pattern: []const u8, case: bool, max: usize, reserve: usize = 0, name: Name = .{}, hook: []const u8 };

// "{brand} {model} {year}. {hook}": the name part is never cut, only the hook is (at a word, in characters). Missing name field > that side of the pattern is dropped
pub fn makeTitle(a: std.mem.Allocator, t: TitleIn) ![]const u8 {
    const hook0 = if (t.case) try titleCase(a, t.hook) else t.hook;
    const avail = if (t.max > t.reserve) t.max - t.reserve else t.max;
    var pre: []const u8 = "";
    var post: []const u8 = "";
    if (std.mem.indexOf(u8, t.pattern, "{hook}")) |ix| {
        if (try expandSide(a, t.pattern[0..ix], t.name)) |p| pre = if (t.case) try titleCase(a, p) else p;
        if (try expandSide(a, t.pattern[ix + 6 ..], t.name)) |p| post = if (t.case) try titleCase(a, p) else p;
    }
    if (charCount(pre) + charCount(post) >= avail) {
        pre = "";
        post = "";
    }
    const room = avail - charCount(pre) - charCount(post);
    var hook = cutChars(hook0, room);
    if (hook.len < hook0.len) hook = trimSep(hook);
    return std.fmt.allocPrint(a, "{s}{s}{s}", .{ pre, hook, post });
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
    // title: pattern + first hook; else first line of the description (no name part); never invented
    const own = try cleanLine(a, f.title); // the maker's own title wins; else the first hook that is not voice-style
    const raw_hook: []const u8 = if (own.len > 0) own else try pickHook(a, f.hooks);
    const tag_suffix: []const u8 = if (p.shorts_tag) " #Shorts" else "";
    const reserve: usize = if (p.title_max > tag_suffix.len + 1) tag_suffix.len else 0;
    var cut_title: []const u8 = "";
    if (raw_hook.len > 0) {
        const nm = Name{ .brand = try cleanLine(a, f.brand), .model = try cleanLine(a, f.model), .year = f.year };
        cut_title = try makeTitle(a, .{ .pattern = p.title_pattern, .case = p.title_case, .max = p.title_max, .reserve = reserve, .name = nm, .hook = raw_hook });
    } else {
        const first = try cleanLine(a, std.mem.sliceTo(f.description, '\n'));
        if (first.len == 0) return Err.NoTitle;
        cut_title = try makeTitle(a, .{ .pattern = "{hook}", .case = p.title_case, .max = p.title_max, .reserve = reserve, .hook = first });
    }
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
    const url = if (p.include_listing_url) try cleanLine(a, f.listing_url) else "";
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
    try std.testing.expectEqualStrings("BXe Đẹp/b Giá Tốt", t.title);
    const long = "word " ** 40;
    const t2 = try build(a, .{ .hooks = &.{long}, .ai_notice = "AI" }, .{});
    try std.testing.expect((std.unicode.utf8CountCodepoints(t2.title) catch 999) <= 100);
    try std.testing.expect(std.mem.endsWith(u8, t2.title, "Word"));
    // multi-byte: 100 characters is not 100 bytes
    const vn = "đ" ** 150;
    const t3 = try build(a, .{ .hooks = &.{vn}, .ai_notice = "AI" }, .{});
    try std.testing.expectEqual(@as(usize, 100), std.unicode.utf8CountCodepoints(t3.title) catch 0);
    try std.testing.expectError(Err.NoTitle, build(a, .{ .ai_notice = "AI" }, .{}));
}

test "title pattern: name part + hook, Title Case, acronyms and brand spelling kept" {
    var ar = arenaT();
    defer ar.deinit();
    const a = ar.allocator();
    const t1 = try build(a, .{ .brand = "Ford", .model = "Everest", .year = 2022, .hooks = &.{"SUV bảy chỗ máy dầu nhập khẩu"}, .ai_notice = "N" }, .{});
    try std.testing.expectEqualStrings("Ford Everest 2022. SUV Bảy Chỗ Máy Dầu Nhập Khẩu", t1.title);
    const t2 = try build(a, .{ .brand = "VinFast", .model = "VF3", .year = 2024, .hooks = &.{"VF3 chạy điện, odo 30.000 km"}, .ai_notice = "N" }, .{});
    try std.testing.expectEqualStrings("VinFast VF3 2024. VF3 Chạy Điện, Odo 30.000 km", t2.title);
    const t3 = try build(a, .{ .brand = "Honda", .model = "CR-V", .year = 2021, .hooks = &.{"SA2.0 và cr-v (bản l) \"đẹp\""}, .ai_notice = "N" }, .{});
    try std.testing.expectEqualStrings("Honda CR-V 2021. SA2.0 Và Cr-v (Bản L) \"Đẹp\"", t3.title);
}

test "title pattern: Vietnamese diacritics upper-cased, never a broken character" {
    var ar = arenaT();
    defer ar.deinit();
    const a = ar.allocator();
    const t = try build(a, .{ .hooks = &.{"đẹp ơi, ưu đãi ở đây ăn êm ôtô ế ỹ ạ"}, .ai_notice = "N" }, .{});
    try std.testing.expectEqualStrings("Đẹp Ơi, Ưu Đãi Ở Đây Ăn Êm Ôtô Ế Ỹ Ạ", t.title);
    try std.testing.expect(std.unicode.utf8ValidateSlice(t.title));
}

test "title pattern: long hook is cut at a word, the name part never; title_max and #Shorts respected" {
    var ar = arenaT();
    defer ar.deinit();
    const a = ar.allocator();
    const f = Fields{ .brand = "Ford", .model = "Everest", .year = 2022, .hooks = &.{"SUV bảy chỗ máy dầu nhập khẩu"}, .ai_notice = "N" };
    const t = try build(a, f, .{ .title_max = 40 });
    try std.testing.expectEqualStrings("Ford Everest 2022. SUV Bảy Chỗ Máy Dầu", t.title);
    try std.testing.expect(charCount(t.title) <= 40);
    const t2 = try build(a, f, .{ .title_max = 40, .shorts_tag = true });
    try std.testing.expectEqualStrings("Ford Everest 2022. SUV Bảy Chỗ #Shorts", t2.title);
    try std.testing.expect(charCount(t2.title) <= 40);
    // the cut leaves no trailing separator
    const t3 = try build(a, .{ .hooks = &.{"alpha beta, gamma delta"}, .ai_notice = "N" }, .{ .title_max = 11 });
    try std.testing.expectEqualStrings("Alpha Beta", t3.title);
    // name part alone does not fit: the hook is posted alone, never a cut name
    const t4 = try build(a, f, .{ .title_max = 15 });
    try std.testing.expectEqualStrings("SUV Bảy Chỗ Máy", t4.title);
}

test "title pattern: missing brand, model or year drops the name part; title_case=false and a custom pattern" {
    var ar = arenaT();
    defer ar.deinit();
    const a = ar.allocator();
    const h: []const []const u8 = &.{"xe đẹp giá tốt"};
    try std.testing.expectEqualStrings("Xe Đẹp Giá Tốt", (try build(a, .{ .brand = "Ford", .model = "", .year = 2022, .hooks = h, .ai_notice = "N" }, .{})).title);
    try std.testing.expectEqualStrings("Xe Đẹp Giá Tốt", (try build(a, .{ .brand = "Ford", .model = "X", .year = 0, .hooks = h, .ai_notice = "N" }, .{})).title);
    try std.testing.expectEqualStrings("Xe Đẹp Giá Tốt", (try build(a, .{ .model = "X", .year = 2020, .hooks = h, .ai_notice = "N" }, .{})).title);
    try std.testing.expectEqualStrings("Ford X 2020. xe đẹp giá tốt", (try build(a, .{ .brand = "Ford", .model = "X", .year = 2020, .hooks = h, .ai_notice = "N" }, .{ .title_case = false })).title);
    try std.testing.expectEqualStrings("2020 Ford | Xe Đẹp Giá Tốt", (try build(a, .{ .brand = "Ford", .model = "X", .year = 2020, .hooks = h, .ai_notice = "N" }, .{ .title_pattern = "{year} {brand} | {hook}" })).title);
}

test "include_listing_url=false leaves the link out" {
    var ar = arenaT();
    defer ar.deinit();
    const a = ar.allocator();
    const t = try build(a, .{ .hooks = &.{"h"}, .description = "Body", .listing_url = "https://a.b/c", .ai_notice = "N" }, .{ .include_listing_url = false });
    try std.testing.expect(std.mem.indexOf(u8, t.description, "https://") == null);
    const t2 = try build(a, .{ .hooks = &.{"h"}, .description = "Body", .listing_url = "https://a.b/c", .ai_notice = "N" }, .{});
    try std.testing.expect(std.mem.indexOf(u8, t2.description, "https://a.b/c") != null);
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
    try std.testing.expectEqualStrings("First Line", t.title);
}
test "title source: own title first, else the first hook without spelled-out numbers" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const honda = try build(a, .{ .brand = "Honda", .model = "CR-V", .year = 2021, .hooks = &.{ "Ba mươi hai nghìn km, đời 2021", "CR-V L 1.5Turbo nhập khẩu" }, .ai_notice = "N" }, .{});
    try std.testing.expectEqualStrings("Honda CR-V 2021. CR-V L 1.5Turbo Nhập Khẩu", honda.title);
    const own = try build(a, .{ .brand = "Honda", .model = "CR-V", .year = 2021, .title = "32.000 km, đời 2021", .hooks = &.{"Ba mươi hai nghìn km"}, .ai_notice = "N" }, .{});
    try std.testing.expectEqualStrings("Honda CR-V 2021. 32.000 km, Đời 2021", own.title);
    try std.testing.expectEqual(@as(usize, 1), spelledNumbers("SUV bảy chỗ máy dầu"));
    try std.testing.expectEqual(@as(usize, 0), spelledNumbers("SUV năm chỗ, máy tăng áp"));
}

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
