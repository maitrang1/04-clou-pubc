// =====================================================================
// Des: Builds the Telegram caption from the producer's json fields - plain text (no markup), cut to the caption limit in UTF-16 units (the safe count), hashtags dropped first, then the description; the hook and the AI notice are never cut
// Flo: clean fields > hook + notice must fit > add link > description (cut at a word) > hashtags that still fit > join with blank lines
// Cre: 2026-11-16                          - | Mod: 2026-11-16
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: hooks, description, hashtags, listing_url, ai_notice, config post limits
// Out: Text {caption} (arena-owned) | error NoTitle / NoNotice / TooLong
// Run: not run directly - imported by rw-pair, cm-publish
// =====================================================================
const std = @import("std");
const cfg_mod = @import("co-cfg.zig");

pub const Err = error{ NoTitle, NoNotice, TooLong, OutOfMemory };

pub const Fields = struct {
    hooks: []const []const u8 = &.{},
    description: []const u8 = "",
    hashtags: []const []const u8 = &.{},
    listing_url: []const u8 = "",
    ai_notice: []const u8 = "",
};

pub const Text = struct { caption: []const u8 };

const sep = "\n\n";

// length in UTF-16 units: a character outside the BMP counts 2. Telegram does not say which unit its 1024 means, so the larger count is used.
pub fn units(s: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const l = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        const end = @min(i + l, s.len);
        n += if (l == 4) 2 else 1;
        i = end;
    }
    return n;
}

// plain text: drop control characters and CR; a line break stays only when keep_nl; collapse spaces
fn clean(a: std.mem.Allocator, s: []const u8, keep_nl: bool) ![]u8 {
    var o: std.ArrayList(u8) = .empty;
    var last_space = true;
    for (s) |ch| {
        if (ch == '\r' or (ch < 0x20 and ch != '\n' and ch != '\t') or ch == 0x7f) continue;
        if (ch == '\n' and keep_nl) {
            while (o.items.len > 0 and o.items[o.items.len - 1] == ' ') _ = o.pop();
            // at most one blank line in a row
            const n = o.items.len;
            if (n >= 2 and o.items[n - 1] == '\n' and o.items[n - 2] == '\n') continue;
            try o.append(a, '\n');
            last_space = true;
            continue;
        }
        const sp = ch == ' ' or ch == '\t' or ch == '\n';
        if (sp) {
            if (!last_space) try o.append(a, ' ');
            last_space = true;
        } else {
            try o.append(a, ch);
            last_space = false;
        }
    }
    while (o.items.len > 0 and (o.items[o.items.len - 1] == ' ' or o.items[o.items.len - 1] == '\n')) _ = o.pop();
    var start: usize = 0;
    while (start < o.items.len and (o.items[start] == ' ' or o.items[start] == '\n')) start += 1;
    return a.dupe(u8, o.items[start..]);
}

// longest prefix of at most max units, cut at a space/newline when it must cut, never inside a character
fn cutUnits(s: []const u8, max: usize) []const u8 {
    var n: usize = 0;
    var i: usize = 0;
    var last_break: usize = 0;
    while (i < s.len) {
        const l = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        const w: usize = if (l == 4) 2 else 1;
        if (n + w > max) break;
        if (s[i] == ' ' or s[i] == '\n') last_break = i;
        n += w;
        i = @min(i + l, s.len);
    }
    if (i >= s.len) return s;
    if (s[i] == ' ' or s[i] == '\n') return std.mem.trimEnd(u8, s[0..i], " \n");
    if (last_break > 0) return std.mem.trimEnd(u8, s[0..last_break], " \n");
    return std.mem.trimEnd(u8, s[0..i], " \n");
}

// hashtag: no '#', no spaces, no duplicates (case-insensitive)
fn normTags(a: std.mem.Allocator, raw: []const []const u8, max_n: u32) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (raw) |r| {
        if (out.items.len >= max_n) break;
        var t: std.ArrayList(u8) = .empty;
        for (r) |ch| {
            if (ch == '#' or ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r' or ch == ',' or ch < 0x20) continue;
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
    const max: usize = p.caption_max;
    const notice = try clean(a, f.ai_notice, true);
    if (p.ai_notice_required and notice.len == 0) return Err.NoNotice;
    // hook: first non-empty hook, else the first line of the description; never invented
    var hook: []const u8 = "";
    for (f.hooks) |h| {
        const t = try clean(a, h, false);
        if (t.len > 0) {
            hook = t;
            break;
        }
    }
    var desc = try clean(a, f.description, true);
    if (hook.len == 0) {
        const nl = std.mem.indexOfScalar(u8, desc, '\n') orelse desc.len;
        hook = try clean(a, desc[0..nl], false);
        desc = std.mem.trim(u8, desc[nl..], " \n");
    }
    if (hook.len == 0) return Err.NoTitle;
    var used = units(hook) + sep.len + units(notice);
    if (used > max) return Err.TooLong;

    // optional parts, in the order they are dropped: tags, then the description is cut
    var url = try clean(a, f.listing_url, false);
    if (url.len > 0) {
        const need = sep.len + units(url);
        if (used + need <= max) used += need else url = "";
    }
    var desc_use: []const u8 = "";
    var tags_ok = true;
    if (desc.len > 0) {
        const room = max - used;
        if (room > sep.len) {
            const avail = room - sep.len;
            if (units(desc) <= avail) {
                desc_use = desc;
            } else {
                desc_use = cutUnits(desc, avail);
                tags_ok = false;
            }
            if (desc_use.len > 0) used += sep.len + units(desc_use);
        } else tags_ok = false;
    }
    var tag_line: std.ArrayList(u8) = .empty;
    if (tags_ok) {
        const tags = try normTags(a, f.hashtags, p.hashtags_max);
        var line_units: usize = 0;
        for (tags) |t| {
            const add = (if (line_units == 0) @as(usize, 0) else 1) + 1 + units(t);
            const extra = if (line_units == 0) sep.len else 0;
            if (used + extra + add > max) break;
            if (line_units != 0) try tag_line.append(a, ' ');
            try tag_line.append(a, '#');
            try tag_line.appendSlice(a, t);
            used += extra + add;
            line_units += add;
        }
    }
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, hook);
    if (desc_use.len > 0) {
        try out.appendSlice(a, sep);
        try out.appendSlice(a, desc_use);
    }
    if (tag_line.items.len > 0) {
        try out.appendSlice(a, sep);
        try out.appendSlice(a, tag_line.items);
    }
    if (url.len > 0) {
        try out.appendSlice(a, sep);
        try out.appendSlice(a, url);
    }
    try out.appendSlice(a, sep);
    try out.appendSlice(a, notice);
    return .{ .caption = try out.toOwnedSlice(a) };
}

fn post(max: u32) cfg_mod.Post {
    var p: cfg_mod.Post = .{};
    p.caption_max = max;
    return p;
}

test "caption: hook, description, hashtags, link and the notice in order" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const t = try build(ar.allocator(), .{ .hooks = &.{"Xe dep gia tot"}, .description = "Mo ta xe", .hashtags = &.{ "#xe", "oto", "XE" }, .listing_url = "https://example.org/x", .ai_notice = "Video tao bang AI." }, post(1024));
    try std.testing.expectEqualStrings("Xe dep gia tot\n\nMo ta xe\n\n#xe #oto\n\nhttps://example.org/x\n\nVideo tao bang AI.", t.caption);
}

test "caption: the notice and the hook are never cut; tags go first, then the description" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const f = Fields{ .hooks = &.{"Hook"}, .description = "one two three four five six seven", .hashtags = &.{ "aa", "bb" }, .ai_notice = "AI made." };
    // exact fit without tags: "Hook\n\n" 6 + desc + "\n\nAI made." 10
    const full = try build(a, f, post(1024));
    try std.testing.expect(std.mem.indexOf(u8, full.caption, "#aa #bb") != null);
    const no_tags = try build(a, f, post(@intCast(6 + 33 + 10)));
    try std.testing.expect(std.mem.indexOf(u8, no_tags.caption, "#") == null);
    try std.testing.expect(std.mem.indexOf(u8, no_tags.caption, "seven") != null);
    // too small for the whole description: it is cut at a word, the notice stays
    const cut = try build(a, f, post(6 + 15 + 10));
    try std.testing.expect(std.mem.endsWith(u8, cut.caption, "\n\nAI made."));
    try std.testing.expect(units(cut.caption) <= 31);
    try std.testing.expect(std.mem.indexOf(u8, cut.caption, "seven") == null);
    try std.testing.expect(std.mem.indexOf(u8, cut.caption, "thre") == null or std.mem.indexOf(u8, cut.caption, "three") != null);
    // hook + notice alone too long: refused, never cut
    try std.testing.expectError(Err.TooLong, build(a, f, post(13)));
}

test "caption: missing notice or title is refused; the title may come from the description" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    try std.testing.expectError(Err.NoNotice, build(a, .{ .hooks = &.{"x"} }, post(1024)));
    try std.testing.expectError(Err.NoTitle, build(a, .{ .ai_notice = "AI" }, post(1024)));
    const t = try build(a, .{ .description = "First line\nsecond line", .ai_notice = "AI" }, post(1024));
    try std.testing.expectEqualStrings("First line\n\nsecond line\n\nAI", t.caption);
}

test "caption: plain text, control characters out, no angle-bracket stripping, emoji count double, Vietnamese kept" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const t = try build(a, .{ .hooks = &.{"Xe <dep>\x00 \r\n gia"}, .ai_notice = "Video tạo bằng AI." }, post(1024));
    try std.testing.expectEqualStrings("Xe <dep> gia\n\nVideo tạo bằng AI.", t.caption);
    try std.testing.expectEqual(@as(usize, 3), units("a🚗"));
    try std.testing.expectEqual(@as(usize, 4), units("tạo "));
    // a car emoji hook near the limit counts as 2 units
    try std.testing.expectError(Err.TooLong, build(a, .{ .hooks = &.{"🚗🚗🚗🚗"}, .ai_notice = "AI" }, post(2 + 8 + 2 - 1)));
    const ok = try build(a, .{ .hooks = &.{"🚗🚗🚗🚗"}, .ai_notice = "AI" }, post(2 + 8 + 2));
    try std.testing.expect(units(ok.caption) <= 12);
}

test "caption: never longer than the limit, whatever the input" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const long = "tiếng Việt có dấu rất dài " ** 80;
    const t = try build(a, .{ .hooks = &.{"Tiêu đề"}, .description = long, .hashtags = &.{ "xe", "oto" }, .listing_url = "https://example.org/a/b", .ai_notice = "Video được tạo bằng AI từ ảnh thật." }, post(1024));
    try std.testing.expect(units(t.caption) <= 1024);
    try std.testing.expect(std.mem.endsWith(u8, t.caption, "Video được tạo bằng AI từ ảnh thật."));
    try std.testing.expect(std.unicode.utf8ValidateSlice(t.caption));
}
// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
