// Lost-ledger guard: before a new container is made, the account's last 24 h are read; a post whose text starts like ours means "already posted" (a restored/empty ledger, or a second device). Pure matching here, the read lives in ap-lookup.
const std = @import("std");
const lookup = @import("ap-lookup.zig");
const text = @import("rw-text.zig");

fn norm(a: std.mem.Allocator, s: []const u8) ![]u8 {
    var o: std.ArrayList(u8) = .empty;
    errdefer o.deinit(a);
    var space = true;
    for (s) |c| {
        if (c == ' ' or c == '\n' or c == '\r' or c == '\t') {
            if (!space) try o.append(a, ' ');
            space = true;
        } else {
            try o.append(a, c);
            space = false;
        }
    }
    return o.toOwnedSlice(a);
}

// first `chars` characters of the normalized text (whitespace folded, cut on a character boundary)
pub fn prefix(a: std.mem.Allocator, s: []const u8, chars: u32) ![]u8 {
    const n = try norm(a, std.mem.trim(u8, s, " \r\n\t"));
    return a.dupe(u8, text.cutW(n, chars, .chars));
}

// id of the first remote post that starts with the same prefix, or null
pub fn match(a: std.mem.Allocator, mine: []const u8, items: []const lookup.Item, chars: u32) !?[]const u8 {
    const p = try prefix(a, mine, chars);
    if (p.len == 0) return null;
    for (items) |it| {
        const theirs = try norm(a, std.mem.trim(u8, it.text, " \r\n\t"));
        if (std.mem.startsWith(u8, theirs, p)) return it.id;
    }
    return null;
}

test "same start = match, whitespace and case of layout ignored, different start = none" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const items = [_]lookup.Item{ .{ .id = "1", .text = "Other post entirely" }, .{ .id = "2", .text = "Big  hook\n\nBody text. More words after." } };
    try std.testing.expectEqualStrings("2", (try match(a, "Big hook\n\nBody text.\n\nMade with AI.", &items, 20)).?);
    try std.testing.expect((try match(a, "Different start here", &items, 20)) == null);
    try std.testing.expect((try match(a, "", &items, 20)) == null);
    try std.testing.expect((try match(a, "Big hook", &.{}, 20)) == null);
}
