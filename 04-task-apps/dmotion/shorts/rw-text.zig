// Caption builder: hook + description + hashtags + AI notice, cut to the limit at a word boundary. The AI notice is never the part that gets cut. Nothing is invented: only the pair's own text.
const std = @import("std");

const guard = @import("co-guard.zig");

pub const Err = error{ NoNotice, NoticeTooLong, OutOfMemory };
pub const Caption = struct { description: []const u8, title: ?[]const u8 };
pub const In = struct { hooks: []const []const u8 = &.{}, description: []const u8 = "", hashtags: []const []const u8 = &.{}, ai_notice: []const u8 = "" };
pub const Lim = struct { desc_max: u32, title_max: u32, tags_max: u32, notice_required: bool };

// cut at the last space within max bytes (or at a UTF-8 boundary when there is none)
pub fn cut(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var e = max;
    while (e > 0 and (s[e] & 0xC0) == 0x80) e -= 1; // never inside a multi-byte char
    const head = s[0..e];
    if (std.mem.lastIndexOfScalar(u8, head, ' ')) |sp| if (sp > 0) return std.mem.trimEnd(u8, head[0..sp], " \n,.;:-");
    return head;
}

// text from outside (Facebook messages) that may land in the ledger or output: secrets removed, cut on a character boundary
pub fn safeNote(a: std.mem.Allocator, s: []const u8, max: usize) []const u8 {
    const red = guard.redactText(a, s) catch return "(note dropped)";
    return cut(red, max);
}

fn tag(a: std.mem.Allocator, raw: []const u8) !?[]u8 {
    var o: std.ArrayList(u8) = .empty;
    try o.append(a, '#');
    for (raw) |c| if (c != '#' and c != ' ' and c != '\n' and c != '\r' and c != '\t') try o.append(a, c);
    if (o.items.len == 1) return null;
    return o.items;
}

pub fn build(a: std.mem.Allocator, in: In, lim: Lim) Err!Caption {
    const notice = std.mem.trim(u8, in.ai_notice, " \r\n\t");
    if (notice.len == 0 and lim.notice_required) return Err.NoNotice;
    var body: std.ArrayList(u8) = .empty;
    const hook = if (in.hooks.len > 0) std.mem.trim(u8, in.hooks[0], " \r\n\t") else "";
    const desc = std.mem.trim(u8, in.description, " \r\n\t");
    if (hook.len > 0) body.appendSlice(a, hook) catch return Err.OutOfMemory;
    if (desc.len > 0) {
        if (body.items.len > 0) body.appendSlice(a, "\n\n") catch return Err.OutOfMemory;
        body.appendSlice(a, desc) catch return Err.OutOfMemory;
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
    if (tags.items.len > 0) {
        if (body.items.len > 0) body.appendSlice(a, "\n\n") catch return Err.OutOfMemory;
        body.appendSlice(a, tags.items) catch return Err.OutOfMemory;
    }
    var out: []const u8 = body.items;
    if (notice.len > 0) {
        const sep: usize = 2;
        if (notice.len + sep > lim.desc_max and out.len > 0) return Err.NoticeTooLong;
        if (notice.len > lim.desc_max) return Err.NoticeTooLong;
        const budget = if (lim.desc_max > notice.len + sep) lim.desc_max - notice.len - sep else 0;
        const head = std.mem.trimEnd(u8, cut(out, budget), "\n ");
        out = if (head.len > 0) std.fmt.allocPrint(a, "{s}\n\n{s}", .{ head, notice }) catch return Err.OutOfMemory else notice;
    } else out = cut(out, lim.desc_max);
    const title: ?[]const u8 = if (hook.len > 0) cut(hook, lim.title_max) else null;
    return .{ .description = out, .title = title };
}

const L = Lim{ .desc_max = 200, .title_max = 30, .tags_max = 3, .notice_required = true };

test "joins hook, description, tags, notice in order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const c = try build(arena.allocator(), .{ .hooks = &.{"Big hook"}, .description = "Body text.", .hashtags = &.{ "cars", "#fun", "has space", "dropped" }, .ai_notice = "Made with AI." }, L);
    try std.testing.expectEqualStrings("Big hook\n\nBody text.\n\n#cars #fun #hasspace\n\nMade with AI.", c.description);
    try std.testing.expectEqualStrings("Big hook", c.title.?);
}

test "long text is cut at a word, the notice survives whole" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const long = "word " ** 100;
    const c = try build(arena.allocator(), .{ .description = long, .ai_notice = "AI NOTICE END" }, L);
    try std.testing.expect(c.description.len <= 200);
    try std.testing.expect(std.mem.endsWith(u8, c.description, "AI NOTICE END"));
    try std.testing.expect(std.mem.indexOf(u8, c.description, "wor\n") == null);
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
    const c = try build(a, .{ .description = "plain" }, l2);
    try std.testing.expectEqualStrings("plain", c.description);
}

test "never cuts inside a multi-byte character" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const c = try build(arena.allocator(), .{ .description = "é" ** 300, .ai_notice = "AI" }, L);
    try std.testing.expect(std.unicode.utf8ValidateSlice(c.description));
    try std.testing.expect(c.description.len <= 200);
}

test "only the pair's own words appear" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const c = try build(arena.allocator(), .{ .description = "just this", .ai_notice = "AI" }, L);
    try std.testing.expectEqualStrings("just this\n\nAI", c.description);
}
