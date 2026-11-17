// =====================================================================
// Des: Builds the X post text from the producer's json fields - hook, description, up to N hashtags inside the text, the AI notice that is never cut and (only when configured) the listing link; counts with X's weights from a data file (tone-marked Vietnamese letters weigh 2), cuts at a word and refuses text that looks like a link
// Flo: clean fields > tags normalized > compose > weigh > shrink the description, then the tags, then the hook > URL guard > Text {text, weight, has_url}
// Cre: 2026-11-16                          - | Mod: 2026-11-16
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: hooks, description, hashtags, listing_url, ai_notice, config post limits
// Out: Text {text, weight, has_url} (arena-owned) | error NoText / NoNotice / NoticeTooLong / LooksLikeUrl
// Run: not run directly - imported by rw-pair, cm-publish
// =====================================================================
const std = @import("std");
const cfg_mod = @import("co-cfg.zig");

pub const Err = error{ NoText, NoNotice, NoticeTooLong, LooksLikeUrl, OutOfMemory };

pub const Fields = struct {
    hooks: []const []const u8 = &.{},
    description: []const u8 = "",
    hashtags: []const []const u8 = &.{},
    listing_url: []const u8 = "",
    ai_notice: []const u8 = "",
};

pub const Text = struct { text: []const u8, weight: u32, has_url: bool };

const Rule = struct { scale: u32 = 100, default: u32 = 200, url_len: u32 = 23, ranges: []const [3]u32 = &.{} };
const rule_json = @embedFile("df-xdot-weights.json");

// X's weights: a code point in a listed range weighs `w`, any other `default` (scale 100 = one character)
fn weightCp(r: Rule, cp: u21) u32 {
    for (r.ranges) |rg| if (cp >= rg[0] and cp <= rg[1]) return rg[2];
    return r.default;
}

fn loadRule(a: std.mem.Allocator) Err!Rule {
    return std.json.parseFromSliceLeaky(Rule, a, rule_json, .{ .ignore_unknown_fields = true }) catch return Err.OutOfMemory;
}

// weight in whole characters (text counted as given, no normalization: NFD never weighs less than NFC)
pub fn weightOf(r: Rule, s: []const u8) u32 {
    var total: u64 = 0;
    var it = std.unicode.Utf8View.initUnchecked(s).iterator();
    while (it.nextCodepoint()) |cp| total += weightCp(r, cp);
    return @intCast((total + r.scale - 1) / r.scale);
}

// longest prefix whose weight is <= max, cut at a space when it must cut
fn cutWeight(r: Rule, s: []const u8, max: u32) []const u8 {
    if (weightOf(r, s) <= max) return s;
    var total: u64 = 0;
    var i: usize = 0;
    var last_space: usize = 0;
    var it = std.unicode.Utf8View.initUnchecked(s).iterator();
    while (it.nextCodepoint()) |cp| {
        const w = weightCp(r, cp);
        if ((total + w + r.scale - 1) / r.scale > max) break;
        total += w;
        i = it.i;
        if (cp == ' ' or cp == '\n') last_space = it.i - 1;
    }
    const head = s[0..i];
    if (i < s.len and (s[i] == ' ' or s[i] == '\n')) return std.mem.trimEnd(u8, head, " \n");
    if (last_space > 0) return std.mem.trimEnd(u8, s[0..last_space], " \n");
    return std.mem.trimEnd(u8, head, " \n");
}

fn cleanLine(a: std.mem.Allocator, s: []const u8) ![]u8 {
    var o: std.ArrayList(u8) = .empty;
    var last_space = true;
    for (s) |ch| {
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

// the description keeps its line breaks; CR dropped, runs of blank lines collapsed
fn cleanBlock(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    var o: std.ArrayList(u8) = .empty;
    var nl: u32 = 0;
    for (s) |ch| {
        if (ch == '\r') continue;
        if (ch == '\n') {
            nl += 1;
            if (nl > 2) continue;
        } else nl = 0;
        try o.append(a, ch);
    }
    return std.mem.trim(u8, try o.toOwnedSlice(a), " \n\t");
}

// hashtag body: letters, digits and underscore only (X), no duplicates (case-insensitive)
fn normTags(a: std.mem.Allocator, raw: []const []const u8, max_n: u32) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (raw) |r| {
        if (out.items.len >= max_n) break;
        var t: std.ArrayList(u8) = .empty;
        for (r) |ch| {
            if (std.ascii.isAlphanumeric(ch) or ch == '_' or ch >= 0x80) try t.append(a, ch);
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

// a token that X would turn into a link (and bill at the URL price): scheme, www., t.co/, or word.tld
pub fn looksLikeLink(text: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, text, " \t\r\n");
    while (it.next()) |raw| {
        const tok = std.mem.trim(u8, raw, ".,;:!?()[]{}\"'<>#@");
        if (tok.len == 0) continue;
        if (std.ascii.indexOfIgnoreCase(tok, "http://") != null or std.ascii.indexOfIgnoreCase(tok, "https://") != null) return true;
        if (std.ascii.startsWithIgnoreCase(tok, "www.") or std.ascii.indexOfIgnoreCase(tok, "t.co/") != null) return true;
        // word.tld : letters after the last dot (2 or more, ASCII only), something before it
        const dot = std.mem.lastIndexOfScalar(u8, tok, '.') orelse continue;
        if (dot == 0 or dot + 3 > tok.len) continue;
        const tld = tok[dot + 1 ..];
        var all_alpha = true;
        for (tld) |ch| if (!std.ascii.isAlphabetic(ch)) {
            all_alpha = false;
            break;
        };
        if (!all_alpha) continue;
        var left_ok = false;
        for (tok[0..dot]) |ch| if (std.ascii.isAlphanumeric(ch)) {
            left_ok = true;
            break;
        };
        if (left_ok) return true;
    }
    return false;
}

const Parts = struct { hook: []const u8, desc: []const u8, tags: []const []const u8, url: []const u8, notice: []const u8 };

fn compose(a: std.mem.Allocator, p: Parts) ![]u8 {
    var o: std.ArrayList(u8) = .empty;
    var first = true;
    inline for (.{ p.hook, p.desc }) |seg| {
        if (seg.len > 0) {
            if (!first) try o.appendSlice(a, "\n\n");
            try o.appendSlice(a, seg);
            first = false;
        }
    }
    if (p.tags.len > 0) {
        if (!first) try o.appendSlice(a, "\n\n");
        for (p.tags, 0..) |t, i| {
            if (i > 0) try o.append(a, ' ');
            try o.print(a, "#{s}", .{t});
        }
        first = false;
    }
    if (p.url.len > 0) {
        if (!first) try o.appendSlice(a, "\n\n");
        try o.appendSlice(a, p.url);
        first = false;
    }
    if (p.notice.len > 0) {
        if (!first) try o.appendSlice(a, "\n\n");
        try o.appendSlice(a, p.notice);
    }
    return o.toOwnedSlice(a);
}

// weight of the composed text; a URL counts url_len, whatever its length
fn weigh(r: Rule, p: Parts, composed: []const u8) u32 {
    if (p.url.len == 0) return weightOf(r, composed);
    return weightOf(r, composed) -| weightOf(r, p.url) +| r.url_len;
}

pub fn build(a: std.mem.Allocator, f: Fields, p: cfg_mod.Post) Err!Text {
    const r = try loadRule(a);
    const notice = try cleanLine(a, f.ai_notice);
    if (p.ai_notice_required and notice.len == 0) return Err.NoNotice;
    var hook: []const u8 = "";
    for (f.hooks) |h| {
        const t = try cleanLine(a, h);
        if (t.len > 0) {
            hook = t;
            break;
        }
    }
    var desc = try cleanBlock(a, f.description);
    if (hook.len == 0) {
        // never invent: the first line of the description becomes the hook
        hook = try cleanLine(a, std.mem.sliceTo(desc, '\n'));
        desc = if (std.mem.indexOfScalar(u8, desc, '\n')) |nl| std.mem.trim(u8, desc[nl..], " \n") else "";
    }
    if (hook.len == 0) return Err.NoText;
    const tags_all = try normTags(a, f.hashtags, p.tags_max);
    const url: []const u8 = if (p.url_in_text) try cleanLine(a, f.listing_url) else "";
    const budget: u32 = p.text_max - p.text_margin;
    var parts = Parts{ .hook = hook, .desc = desc, .tags = tags_all, .url = url, .notice = notice };
    // the notice (with the link, if any) must fit alone: it is never cut
    const base = Parts{ .hook = "", .desc = "", .tags = &.{}, .url = url, .notice = notice };
    if (weigh(r, base, try compose(a, base)) > budget) return Err.NoticeTooLong;
    var text = try compose(a, parts);
    // 1. cut the description
    if (weigh(r, parts, text) > budget and parts.desc.len > 0) {
        const no_desc = Parts{ .hook = parts.hook, .desc = "", .tags = parts.tags, .url = parts.url, .notice = parts.notice };
        const fixed = weigh(r, no_desc, try compose(a, no_desc));
        if (fixed + 3 < budget) {
            parts.desc = cutWeight(r, parts.desc, budget - fixed - 2);
        } else parts.desc = "";
        text = try compose(a, parts);
    }
    // 2. drop tags from the end
    while (weigh(r, parts, text) > budget and parts.tags.len > 0) {
        parts.tags = parts.tags[0 .. parts.tags.len - 1];
        text = try compose(a, parts);
    }
    // 3. cut the hook
    if (weigh(r, parts, text) > budget) {
        const only_notice = weigh(r, base, try compose(a, base));
        if (only_notice + 3 >= budget) return Err.NoticeTooLong;
        parts.hook = cutWeight(r, parts.hook, budget - only_notice - 2);
        if (parts.hook.len == 0) return Err.NoticeTooLong;
        text = try compose(a, parts);
    }
    if (p.url_guard and !p.url_in_text and looksLikeLink(text)) return Err.LooksLikeUrl;
    return .{ .text = text, .weight = weigh(r, parts, text), .has_url = url.len > 0 };
}

fn arenaT() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(std.testing.allocator);
}

test "weights: Latin and base Vietnamese letters weigh 1, tone-marked ones and emoji 2, a URL 23" {
    var ar = arenaT();
    defer ar.deinit();
    const r = try loadRule(ar.allocator());
    try std.testing.expectEqual(@as(u32, 5), weightOf(r, "hello"));
    try std.testing.expectEqual(@as(u32, 1), weightOf(r, "ă")); // U+0103
    try std.testing.expectEqual(@as(u32, 1), weightOf(r, "đ")); // U+0111
    try std.testing.expectEqual(@as(u32, 2), weightOf(r, "ệ")); // U+1EC7
    try std.testing.expectEqual(@as(u32, 2), weightOf(r, "ạ")); // U+1EA1
    try std.testing.expectEqual(@as(u32, 2), weightOf(r, "😀"));
    try std.testing.expectEqual(@as(u32, 2), weightOf(r, "車"));
    // NFD "ệ" = e + two combining marks, each U+03xx weighs 1: three, never fewer than NFC
    try std.testing.expectEqual(@as(u32, 3), weightOf(r, "e\u{0302}\u{0323}"));
}

test "text: hook, description, tags in the text, notice last; tags cleaned and capped" {
    var ar = arenaT();
    defer ar.deinit();
    const a = ar.allocator();
    const t = try build(a, .{ .hooks = &.{ "Xe  dep", "other" }, .description = "Mo ta", .hashtags = &.{ "#Xe", "xe", "gia tot", "a.b&c", "d", "e" }, .ai_notice = "Video AI" }, .{});
    try std.testing.expectEqualStrings("Xe dep\n\nMo ta\n\n#Xe #giatot #abc\n\nVideo AI", t.text);
    try std.testing.expect(!t.has_url);
}

test "limit 280 by weight: the notice survives, the description is cut at a word, tone marks cost double" {
    var ar = arenaT();
    defer ar.deinit();
    const a = ar.allocator();
    const notice = "Video tạo bằng AI";
    const big = "Xe rất đẹp giá tốt " ** 40;
    const t = try build(a, .{ .hooks = &.{"Hook"}, .description = big, .hashtags = &.{"xe"}, .ai_notice = notice }, .{});
    try std.testing.expect(t.weight <= 280 - 6);
    try std.testing.expect(std.mem.endsWith(u8, t.text, notice));
    try std.testing.expect(std.unicode.utf8ValidateSlice(t.text));
    try std.testing.expect(std.mem.startsWith(u8, t.text, "Hook\n\nXe rất"));
    // all-tone-marked text costs 2 per letter: 100 of them already fill 200 of the budget
    const heavy = "ệ" ** 150;
    const t2 = try build(a, .{ .hooks = &.{"H"}, .description = heavy, .ai_notice = "N" }, .{});
    try std.testing.expect(t2.weight <= 274);
    try std.testing.expect(std.mem.endsWith(u8, t2.text, "\n\nN"));
    // a notice that cannot fit is an error, not a silent cut
    try std.testing.expectError(Err.NoticeTooLong, build(a, .{ .hooks = &.{"h"}, .ai_notice = "x" ** 300 }, .{}));
    try std.testing.expectError(Err.NoNotice, build(a, .{ .hooks = &.{"h"} }, .{}));
}

test "shrink order: description first, then tags, then the hook" {
    var ar = arenaT();
    defer ar.deinit();
    const a = ar.allocator();
    const p: cfg_mod.Post = .{ .text_max = 60, .text_margin = 0 };
    const t = try build(a, .{ .hooks = &.{"Hook text here"}, .description = "d" ** 100, .hashtags = &.{ "aa", "bb" }, .ai_notice = "AI label" }, p);
    try std.testing.expect(t.weight <= 60);
    try std.testing.expect(std.mem.indexOf(u8, t.text, "#aa") != null); // tags kept while the description shrank
    try std.testing.expect(std.mem.endsWith(u8, t.text, "AI label"));
    const t2 = try build(a, .{ .hooks = &.{"Hook text here"}, .hashtags = &.{ "aaaaaaaaaaaaaaaa", "bbbbbbbbbbbbbbbbb" }, .ai_notice = "AI label here ok" }, .{ .text_max = 40, .text_margin = 0 });
    try std.testing.expect(t2.weight <= 40 and std.mem.endsWith(u8, t2.text, "AI label here ok"));
}

test "never invents: with no hook the first line of the description is the hook; nothing at all is an error" {
    var ar = arenaT();
    defer ar.deinit();
    const a = ar.allocator();
    const t = try build(a, .{ .description = "First line\nSecond", .ai_notice = "N" }, .{});
    try std.testing.expectEqualStrings("First line\n\nSecond\n\nN", t.text);
    try std.testing.expectError(Err.NoText, build(a, .{ .ai_notice = "N" }, .{}));
}

test "URL guard: a link or a domain is refused, numbers and sentences pass" {
    var ar = arenaT();
    defer ar.deinit();
    const a = ar.allocator();
    try std.testing.expectError(Err.LooksLikeUrl, build(a, .{ .hooks = &.{"see https://a.com/x"}, .ai_notice = "N" }, .{}));
    try std.testing.expectError(Err.LooksLikeUrl, build(a, .{ .hooks = &.{"xem www.abc.vn"}, .ai_notice = "N" }, .{}));
    try std.testing.expectError(Err.LooksLikeUrl, build(a, .{ .hooks = &.{"ghe example.com ngay"}, .ai_notice = "N" }, .{}));
    try std.testing.expectError(Err.LooksLikeUrl, build(a, .{ .hooks = &.{"h"}, .description = "t.co/abc", .ai_notice = "N" }, .{}));
    const ok = try build(a, .{ .hooks = &.{"Xe 2.0 v1.5 gia 1.2 ty."}, .description = "Het. Xong!", .ai_notice = "AI." }, .{});
    try std.testing.expect(std.mem.indexOf(u8, ok.text, "2.0") != null);
    // with the guard off a link is allowed
    _ = try build(a, .{ .hooks = &.{"a.com"}, .ai_notice = "N" }, .{ .url_guard = false });
}

test "the listing link is added only when configured, counts 23 and bills as a URL post" {
    var ar = arenaT();
    defer ar.deinit();
    const a = ar.allocator();
    const f: Fields = .{ .hooks = &.{"Hook"}, .listing_url = "https://example.com/a/very/long/listing/path/that/is/not/23/characters/long", .ai_notice = "AI" };
    const off = try build(a, f, .{});
    try std.testing.expect(std.mem.indexOf(u8, off.text, "example.com") == null and !off.has_url);
    const on = try build(a, f, .{ .url_in_text = true });
    try std.testing.expect(on.has_url and std.mem.indexOf(u8, on.text, "https://example.com") != null);
    try std.testing.expectEqual(@as(u32, 4 + 2 + 23 + 2 + 2), on.weight); // Hook, gap, link, gap, AI
}
// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
