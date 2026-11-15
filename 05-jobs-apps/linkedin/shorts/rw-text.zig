// Commentary builder for LinkedIn's "little text" format: hook + description + AI notice + hashtags. Reserved characters in plain text are escaped with a backslash; hashtags stay raw; the notice and the hashtags are never the part that gets cut. Nothing is invented: only the pair's own text.
const std = @import("std");
const guard = @import("co-guard.zig");

pub const Err = error{ NoNotice, NoticeTooLong, OutOfMemory };
pub const Caption = struct { commentary: []const u8, title: ?[]const u8 };
pub const In = struct { hooks: []const []const u8 = &.{}, description: []const u8 = "", hashtags: []const []const u8 = &.{}, ai_notice: []const u8 = "", url: []const u8 = "" };
pub const Lim = struct { text_max: u32, text_margin: u32, title_max: u32, tags_max: u32, notice_required: bool };

// the 15 characters the little text format reserves
const reserved = "|{}@[]()<>#\\*_~";

fn isReserved(c: u8) bool {
    return std.mem.indexOfScalar(u8, reserved, c) != null;
}

pub fn escape(a: std.mem.Allocator, s: []const u8) ![]u8 {
    var o: std.ArrayList(u8) = .empty;
    for (s) |c| {
        if (isReserved(c)) try o.append(a, '\\');
        try o.append(a, c);
    }
    return o.items;
}

// code points in a UTF-8 string
pub fn cpLen(s: []const u8) usize {
    var n: usize = 0;
    for (s) |c| {
        if ((c & 0xC0) != 0x80) n += 1;
    }
    return n;
}

// byte length of the first `max` code points
fn cpPrefix(s: []const u8, max: usize) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if ((s[i] & 0xC0) != 0x80) {
            if (n == max) return i;
            n += 1;
        }
    }
    return s.len;
}

// cut at the last space within max code points (or at a code point boundary when there is none); never leaves a lone escape backslash
pub fn cut(s: []const u8, max: usize) []const u8 {
    if (cpLen(s) <= max) return s;
    const e = cpPrefix(s, max);
    var head = s[0..e];
    if (std.mem.lastIndexOfScalar(u8, head, ' ')) |sp| {
        if (sp > 0) head = head[0..sp];
    }
    head = std.mem.trimEnd(u8, head, " \n,.;:-");
    var bs: usize = 0; // trailing run of backslashes: an odd run would escape nothing
    while (bs < head.len and head[head.len - 1 - bs] == '\\') bs += 1;
    if (bs % 2 == 1) head = head[0 .. head.len - 1];
    return head;
}

// text from outside (LinkedIn messages) that may land in the ledger or output: secrets removed, cut on a character boundary
pub fn safeNote(a: std.mem.Allocator, s: []const u8, max: usize) []const u8 {
    const red = guard.redactText(a, s) catch return "(note dropped)";
    const e = cpPrefix(red, max);
    return red[0..e];
}

// hashtag: keep letters, digits, underscore and non-ASCII letters; drop spaces and punctuation. Null when nothing is left.
fn tag(a: std.mem.Allocator, raw: []const u8) !?[]u8 {
    var o: std.ArrayList(u8) = .empty;
    try o.append(a, '#');
    for (raw) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '_' or c >= 0x80) try o.append(a, c);
    }
    if (o.items.len == 1) return null;
    return o.items;
}

pub fn build(a: std.mem.Allocator, in: In, lim: Lim) Err!Caption {
    const notice_raw = std.mem.trim(u8, in.ai_notice, " \r\n\t");
    if (notice_raw.len == 0 and lim.notice_required) return Err.NoNotice;
    const notice = escape(a, notice_raw) catch return Err.OutOfMemory;
    const hook_raw = if (in.hooks.len > 0) std.mem.trim(u8, in.hooks[0], " \r\n\t") else "";
    const desc_raw = std.mem.trim(u8, in.description, " \r\n\t");
    const url_raw = std.mem.trim(u8, in.url, " \r\n\t");
    var body: std.ArrayList(u8) = .empty;
    if (hook_raw.len > 0) body.appendSlice(a, escape(a, hook_raw) catch return Err.OutOfMemory) catch return Err.OutOfMemory;
    if (desc_raw.len > 0) {
        if (body.items.len > 0) body.appendSlice(a, "\n\n") catch return Err.OutOfMemory;
        body.appendSlice(a, escape(a, desc_raw) catch return Err.OutOfMemory) catch return Err.OutOfMemory;
    }
    if (url_raw.len > 0) {
        if (body.items.len > 0) body.appendSlice(a, "\n\n") catch return Err.OutOfMemory;
        body.appendSlice(a, escape(a, url_raw) catch return Err.OutOfMemory) catch return Err.OutOfMemory;
    }
    var tags: std.ArrayList(u8) = .empty;
    var nt: u32 = 0;
    for (in.hashtags) |h| {
        if (nt >= lim.tags_max) break;
        const t = (tag(a, h) catch return Err.OutOfMemory) orelse continue;
        if (tags.items.len > 0) tags.append(a, ' ') catch return Err.OutOfMemory;
        tags.appendSlice(a, t) catch return Err.OutOfMemory;
        nt += 1;
    }
    const budget_total: usize = lim.text_max - lim.text_margin;
    // the parts that are never cut
    const fixed = cpLen(notice) + (if (tags.items.len > 0) cpLen(tags.items) + 2 else 0) + (if (notice.len > 0) @as(usize, 2) else 0);
    if (fixed > budget_total and body.items.len > 0) return Err.NoticeTooLong;
    if (notice.len > budget_total) return Err.NoticeTooLong;
    const room = budget_total - fixed;
    const head = std.mem.trimEnd(u8, cut(body.items, room), "\n ");
    var out: std.ArrayList(u8) = .empty;
    if (head.len > 0) out.appendSlice(a, head) catch return Err.OutOfMemory;
    if (notice.len > 0) {
        if (out.items.len > 0) out.appendSlice(a, "\n\n") catch return Err.OutOfMemory;
        out.appendSlice(a, notice) catch return Err.OutOfMemory;
    }
    if (tags.items.len > 0) {
        if (out.items.len > 0) out.appendSlice(a, "\n\n") catch return Err.OutOfMemory;
        out.appendSlice(a, tags.items) catch return Err.OutOfMemory;
    }
    // the media title is plain text (not little text): the hook, cut to title_max
    const title: ?[]const u8 = if (hook_raw.len > 0) cut(hook_raw, lim.title_max) else null;
    return .{ .commentary = out.items, .title = title };
}

const L = Lim{ .text_max = 300, .text_margin = 50, .title_max = 30, .tags_max = 3, .notice_required = true };

test "joins hook, description, notice, tags in order; tags stay raw" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const c = try build(arena.allocator(), .{ .hooks = &.{"Big hook"}, .description = "Body text.", .hashtags = &.{ "cars", "#fun", "has space", "dropped" }, .ai_notice = "Made with AI." }, L);
    try std.testing.expectEqualStrings("Big hook\n\nBody text.\n\nMade with AI.\n\n#cars #fun #hasspace", c.commentary);
    try std.testing.expectEqualStrings("Big hook", c.title.?);
}

test "all 15 reserved characters are escaped in plain text, none in hashtags" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const e = try escape(a, "|{}@[]()<>#\\*_~");
    try std.testing.expectEqualStrings("\\|\\{\\}\\@\\[\\]\\(\\)\\<\\>\\#\\\\\\*\\_\\~", e);
    try std.testing.expectEqual(@as(usize, 30), e.len);
    const c = try build(a, .{ .description = "50% (new) a_b *x*", .hashtags = &.{ "a_b", "x-y" }, .ai_notice = "AI" }, L);
    try std.testing.expect(std.mem.indexOf(u8, c.commentary, "50% \\(new\\) a\\_b \\*x\\*") != null);
    try std.testing.expect(std.mem.endsWith(u8, c.commentary, "#a_b #xy"));
    try std.testing.expect(std.mem.indexOf(u8, c.commentary, "\\#") == null);
}

test "long text is cut at a word, notice and tags survive whole, size within budget" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const long = "word " ** 200;
    const c = try build(arena.allocator(), .{ .description = long, .hashtags = &.{"tag"}, .ai_notice = "AI NOTICE END" }, L);
    try std.testing.expect(cpLen(c.commentary) <= 250);
    try std.testing.expect(std.mem.indexOf(u8, c.commentary, "AI NOTICE END\n\n#tag") != null);
    try std.testing.expect(std.mem.indexOf(u8, c.commentary, "wor\n") == null);
}

test "missing notice refused, huge notice refused, allowed when not required" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectError(Err.NoNotice, build(a, .{ .description = "x" }, L));
    try std.testing.expectError(Err.NoNotice, build(a, .{ .description = "x", .ai_notice = "  " }, L));
    try std.testing.expectError(Err.NoticeTooLong, build(a, .{ .description = "x", .ai_notice = "n" ** 400 }, L));
    var l2 = L;
    l2.notice_required = false;
    const c = try build(a, .{ .description = "plain" }, l2);
    try std.testing.expectEqualStrings("plain", c.commentary);
}

test "counts code points, never cuts inside a character, never ends on a lone backslash" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const c = try build(a, .{ .description = "é" ** 400, .ai_notice = "AI" }, L);
    try std.testing.expect(std.unicode.utf8ValidateSlice(c.commentary));
    try std.testing.expect(cpLen(c.commentary) <= 250);
    try std.testing.expectEqual(@as(usize, 3), cpLen("aéé") + 0 - 0);
    // cutting right after an escape's backslash must drop the backslash
    const r = cut("abc \\_\\_\\_", 5);
    try std.testing.expect(!std.mem.endsWith(u8, r, "\\") or std.mem.endsWith(u8, r, "\\\\"));
    const h = cut("aaaaaaaa\\_bbb", 9); // 9th char is the "_" after a backslash: keep pairs whole
    try std.testing.expect(h.len == 0 or h[h.len - 1] != '\\');
}

test "vietnamese diacritics survive in text and hashtags" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const c = try build(arena.allocator(), .{ .hooks = &.{"Xe đẹp"}, .hashtags = &.{"xe đẹp"}, .ai_notice = "AI" }, L);
    try std.testing.expect(std.mem.indexOf(u8, c.commentary, "Xe đẹp") != null);
    try std.testing.expect(std.mem.endsWith(u8, c.commentary, "#xeđẹp"));
}

test "title is the plain hook, cut" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const c = try build(arena.allocator(), .{ .hooks = &.{"A hook with *stars* and (parens) that is long enough to be cut"}, .ai_notice = "AI" }, L);
    try std.testing.expect(std.mem.indexOf(u8, c.title.?, "*stars*") != null);
    try std.testing.expect(cpLen(c.title.?) <= 30);
}
