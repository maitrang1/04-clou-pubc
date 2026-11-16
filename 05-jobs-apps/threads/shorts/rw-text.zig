// Post text builder: hook + description + listing url + AI notice, cut at a word boundary to the weighted limit (500). The AI notice and the url are never the part that gets cut.
// ONE topic tag per post (Threads allows one): hashtags[0] goes in the topic_tag parameter, never as #tag in the text. Nothing is invented: only the pair's own words.
const std = @import("std");
const guard = @import("co-guard.zig");

pub const Err = error{ NoNotice, NoticeTooLong, TooManyLinks, OutOfMemory };
pub const Unit = enum { weighted, chars, bytes };
pub const Post = struct { text: []const u8, topic_tag: ?[]const u8, weight: u32 };
pub const In = struct { hooks: []const []const u8 = &.{}, description: []const u8 = "", hashtags: []const []const u8 = &.{}, ai_notice: []const u8 = "", listing_url: []const u8 = "" };
pub const Lim = struct { text_max: u32, margin: u32 = 0, unit: Unit = .weighted, url_in_text: bool = true, notice_required: bool = true };

pub const max_links: usize = 5;
const sep = "\n\n";

pub fn unitOf(s: []const u8) Unit {
    if (std.mem.eql(u8, s, "chars")) return .chars;
    if (std.mem.eql(u8, s, "bytes")) return .bytes;
    return .weighted;
}

fn cpWeight(cp: u21, unit: Unit) u32 {
    return switch (unit) {
        .chars => 1,
        .bytes => @intCast(std.unicode.utf8CodepointSequenceLength(cp) catch 1),
        .weighted => if (cp >= 0x2190) @intCast(std.unicode.utf8CodepointSequenceLength(cp) catch 4) else 1, // symbols and emoji (U+2190 up, incl. BMP ones like U+2764) count as their UTF-8 bytes (Meta); letters incl. accents are one each (unconfirmed, see 15-FEAT)
    };
}

// length of s in the chosen unit. Invalid UTF-8 counts by bytes (never under-counts).
pub fn weight(s: []const u8, unit: Unit) u32 {
    if (unit == .bytes or !std.unicode.utf8ValidateSlice(s)) return @intCast(@min(s.len, std.math.maxInt(u32)));
    var n: u32 = 0;
    var it = (std.unicode.Utf8View.init(s) catch return @intCast(s.len)).iterator();
    while (it.nextCodepoint()) |cp| n +|= cpWeight(cp, unit);
    return n;
}

// longest prefix of s within `budget` (on a character boundary), then back to the last space; never inside a multi-byte char
pub fn cutW(s: []const u8, budget: u32, unit: Unit) []const u8 {
    if (weight(s, unit) <= budget) return s;
    var end: usize = 0;
    var w: u32 = 0;
    if (unit == .bytes or !std.unicode.utf8ValidateSlice(s)) {
        end = @min(s.len, budget);
        while (end > 0 and end < s.len and (s[end] & 0xC0) == 0x80) end -= 1;
    } else {
        var it = (std.unicode.Utf8View.init(s) catch return "").iterator();
        while (it.nextCodepointSlice()) |sl| {
            const cp = std.unicode.utf8Decode(sl) catch 0;
            const cw = cpWeight(cp, unit);
            if (w + cw > budget) break;
            w += cw;
            end += sl.len;
        }
    }
    const head = s[0..end];
    if (std.mem.lastIndexOfScalar(u8, head, ' ')) |sp| if (sp > 0) return std.mem.trimEnd(u8, head[0..sp], " \n,.;:-");
    return std.mem.trimEnd(u8, head, " \n");
}

// byte cut for notes (ledger/output): last space within max bytes, never inside a multi-byte char
pub fn cut(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var e = max;
    while (e > 0 and (s[e] & 0xC0) == 0x80) e -= 1;
    const head = s[0..e];
    if (std.mem.lastIndexOfScalar(u8, head, ' ')) |sp| if (sp > 0) return std.mem.trimEnd(u8, head[0..sp], " \n,.;:-");
    return head;
}

// text from outside (Meta messages) that may land in the ledger or output: secrets removed, cut on a character boundary
pub fn safeNote(a: std.mem.Allocator, s: []const u8, max: usize) []const u8 {
    const red = guard.redactText(a, s) catch return "(note dropped)";
    return cut(red, max);
}

fn cleanTag(a: std.mem.Allocator, raw: []const u8) !?[]u8 {
    var o: std.ArrayList(u8) = .empty;
    for (raw) |c| if (c != '#' and c != ' ' and c != '\n' and c != '\r' and c != '\t' and c != '.' and c != '&') try o.append(a, c);
    if (o.items.len == 0) return null;
    if (!std.unicode.utf8ValidateSlice(o.items)) return null;
    if (weight(o.items, .chars) > 50) return null; // Threads: 1..50 characters
    return o.items;
}

// number of distinct http(s) links in the text
fn linkCount(s: []const u8) usize {
    var seen: [16][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.tokenizeAny(u8, s, " \n\r\t");
    while (it.next()) |tok| {
        if (!(std.ascii.startsWithIgnoreCase(tok, "http://") or std.ascii.startsWithIgnoreCase(tok, "https://"))) continue;
        var dup = false;
        for (seen[0..@min(n, seen.len)]) |x| if (std.mem.eql(u8, x, tok)) {
            dup = true;
        };
        if (!dup) {
            if (n < seen.len) seen[n] = tok;
            n += 1;
        }
    }
    return n;
}

pub fn build(a: std.mem.Allocator, in: In, lim: Lim) Err!Post {
    const notice = std.mem.trim(u8, in.ai_notice, " \r\n\t");
    if (notice.len == 0 and lim.notice_required) return Err.NoNotice;
    var body: std.ArrayList(u8) = .empty;
    const hook = if (in.hooks.len > 0) std.mem.trim(u8, in.hooks[0], " \r\n\t") else "";
    const desc = std.mem.trim(u8, in.description, " \r\n\t");
    if (hook.len > 0) body.appendSlice(a, hook) catch return Err.OutOfMemory;
    if (desc.len > 0) {
        if (body.items.len > 0) body.appendSlice(a, sep) catch return Err.OutOfMemory;
        body.appendSlice(a, desc) catch return Err.OutOfMemory;
    }
    // the tail that is never cut: url (optional) and the AI notice
    var tail: std.ArrayList(u8) = .empty;
    const url = std.mem.trim(u8, in.listing_url, " \r\n\t");
    if (lim.url_in_text and url.len > 0) tail.appendSlice(a, url) catch return Err.OutOfMemory;
    if (notice.len > 0) {
        if (tail.items.len > 0) tail.appendSlice(a, sep) catch return Err.OutOfMemory;
        tail.appendSlice(a, notice) catch return Err.OutOfMemory;
    }
    const limit = lim.text_max - @min(lim.margin, lim.text_max);
    const tw = weight(tail.items, lim.unit);
    if (tw > limit) return Err.NoticeTooLong;
    var text: []const u8 = undefined;
    if (body.items.len == 0) {
        text = tail.items;
    } else if (tail.items.len == 0) {
        text = cutW(body.items, limit, lim.unit);
    } else {
        const sw = weight(sep, lim.unit);
        const budget: u32 = if (limit > tw + sw) limit - tw - sw else 0;
        const head = std.mem.trimEnd(u8, cutW(body.items, budget, lim.unit), "\n ");
        text = if (head.len > 0) std.fmt.allocPrint(a, "{s}{s}{s}", .{ head, sep, tail.items }) catch return Err.OutOfMemory else tail.items;
    }
    if (linkCount(text) > max_links) return Err.TooManyLinks;
    var tag: ?[]const u8 = null;
    for (in.hashtags) |h| {
        if (cleanTag(a, h) catch return Err.OutOfMemory) |t| {
            tag = t;
            break;
        }
    }
    return .{ .text = text, .topic_tag = tag, .weight = weight(text, lim.unit) };
}

const L = Lim{ .text_max = 200, .margin = 0 };

test "joins hook, description, url, notice in order; one topic tag, no #tag in the text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const p = try build(arena.allocator(), .{ .hooks = &.{"Big hook"}, .description = "Body text.", .hashtags = &.{ "#cars", "fun" }, .ai_notice = "Made with AI.", .listing_url = "https://x.example/a" }, L);
    try std.testing.expectEqualStrings("Big hook\n\nBody text.\n\nhttps://x.example/a\n\nMade with AI.", p.text);
    try std.testing.expectEqualStrings("cars", p.topic_tag.?);
    try std.testing.expect(std.mem.indexOfScalar(u8, p.text, '#') == null);
}

test "topic tag rules: first valid, no dot or ampersand, 1..50 chars" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = try build(a, .{ .description = "x", .hashtags = &.{ "#", " ", "a.b&c", "second" }, .ai_notice = "AI" }, L);
    try std.testing.expectEqualStrings("abc", p.topic_tag.?);
    const long = "z" ** 51;
    const p2 = try build(a, .{ .description = "x", .hashtags = &.{ long, "ok" }, .ai_notice = "AI" }, L);
    try std.testing.expectEqualStrings("ok", p2.topic_tag.?);
    const p3 = try build(a, .{ .description = "x", .ai_notice = "AI" }, L);
    try std.testing.expect(p3.topic_tag == null);
}

test "long text is cut at a word, the notice and url survive whole" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const long = "word " ** 100;
    const p = try build(arena.allocator(), .{ .description = long, .ai_notice = "AI NOTICE END", .listing_url = "https://x.example/q" }, L);
    try std.testing.expect(p.weight <= 200);
    try std.testing.expect(std.mem.endsWith(u8, p.text, "AI NOTICE END"));
    try std.testing.expect(std.mem.indexOf(u8, p.text, "https://x.example/q") != null);
    try std.testing.expect(std.mem.indexOf(u8, p.text, "wor\n") == null);
}

test "weights: emoji = 4 (UTF-8 bytes), accents = 1, bytes mode counts bytes" {
    try std.testing.expectEqual(@as(u32, 4), weight("😀", .weighted));
    try std.testing.expectEqual(@as(u32, 1), weight("é", .weighted));
    try std.testing.expectEqual(@as(u32, 2), weight("é", .bytes));
    try std.testing.expectEqual(@as(u32, 3), weight("ệ", .bytes));
    try std.testing.expectEqual(@as(u32, 1), weight("😀", .chars));
    try std.testing.expectEqual(@as(u32, 3), weight("❤", .weighted)); // BMP symbol: 3 bytes
    try std.testing.expectEqual(@as(u32, 1), weight("ệ", .weighted)); // Vietnamese letter stays 1
    try std.testing.expectEqual(@as(u32, 5), weight("a😀", .weighted));
    // invalid UTF-8 never under-counts
    try std.testing.expectEqual(@as(u32, 3), weight("\xff\xfe\xfd", .weighted));
}

test "emoji text respects the limit in weighted units" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const p = try build(arena.allocator(), .{ .description = "😀 " ** 120, .ai_notice = "AI" }, L);
    try std.testing.expect(p.weight <= 200);
    try std.testing.expect(std.unicode.utf8ValidateSlice(p.text));
    try std.testing.expect(std.mem.endsWith(u8, p.text, "AI"));
}

test "missing notice refused, huge notice refused, no notice allowed when not required" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectError(Err.NoNotice, build(a, .{ .description = "x" }, L));
    try std.testing.expectError(Err.NoNotice, build(a, .{ .description = "x", .ai_notice = "  " }, L));
    try std.testing.expectError(Err.NoticeTooLong, build(a, .{ .description = "x", .ai_notice = "n" ** 250 }, L));
    var l2 = L;
    l2.notice_required = false;
    const p = try build(a, .{ .description = "plain" }, l2);
    try std.testing.expectEqualStrings("plain", p.text);
}

test "the margin shrinks the budget; never cuts inside a multi-byte character" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var l = L;
    l.margin = 50;
    const p = try build(a, .{ .description = "word " ** 100, .ai_notice = "AI" }, l);
    try std.testing.expect(p.weight <= 150);
    const p2 = try build(a, .{ .description = "ệ" ** 300, .ai_notice = "AI" }, .{ .text_max = 200, .unit = .bytes });
    try std.testing.expect(std.unicode.utf8ValidateSlice(p2.text));
    try std.testing.expect(p2.text.len <= 200);
}

test "more than five distinct links is refused; the url in the json is optional" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const six = "https://a.x/1 https://a.x/2 https://a.x/3 https://a.x/4 https://a.x/5 https://a.x/6";
    try std.testing.expectError(Err.TooManyLinks, build(a, .{ .description = six, .ai_notice = "AI" }, .{ .text_max = 500 }));
    const five_dup = "https://a.x/1 https://a.x/1 https://a.x/2 https://a.x/3 https://a.x/4 https://a.x/5";
    _ = try build(a, .{ .description = five_dup, .ai_notice = "AI" }, .{ .text_max = 500 });
    var l = L;
    l.url_in_text = false;
    const p = try build(a, .{ .description = "d", .ai_notice = "AI", .listing_url = "https://x.example" }, l);
    try std.testing.expect(std.mem.indexOf(u8, p.text, "x.example") == null);
}

test "only the pair's own words appear" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const p = try build(arena.allocator(), .{ .description = "just this", .ai_notice = "AI" }, L);
    try std.testing.expectEqualStrings("just this\n\nAI", p.text);
}
