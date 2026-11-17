// =====================================================================
// Des: Turns a Telegram refusal (error_code + description + parameters) into a class the engine acts on - tolerant substring match from a data table, because only 429 + retry_after + migrate_to_chat_id are documented
// Flo: migrate_to_chat_id first > table rows in order (code, lowercase substring) > default fail
// Cre: 2026-11-16                          - | Mod: 2026-11-16
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: error_code, description, migrate_to_chat_id
// Out: Verdict {class, why}
// Run: not run directly - imported by ap-call and cm-send
// =====================================================================
const std = @import("std");

pub const Class = enum {
    flood, // 429: wait retry_after, nothing was sent
    dead_token, // 401: breaker open, a person fixes the token
    no_right, // 403: not admin / kicked: breaker open
    no_chat, // wrong chat id or bot not in it: breaker open
    migrated, // the chat moved: breaker open, a person updates the id
    caption, // this video's caption was refused: failed
    too_big, // this file is too big: failed
    conflict, // 409: feed held by a webhook or another reader
    fail, // any other refusal: failed, counts toward the breaker
};

pub const Verdict = struct { class: Class, why: []const u8 };

const Row = struct { code: u32, has: []const u8, class: []const u8, why: []const u8 };

const table_json = @embedFile("df-tele-errors.json");

fn classOf(name: []const u8) ?Class {
    inline for (@typeInfo(Class).@"enum".fields) |f| if (std.mem.eql(u8, name, f.name)) return @field(Class, f.name);
    return null;
}

fn containsLower(hay: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    return std.ascii.indexOfIgnoreCase(hay, needle) != null;
}

pub fn classify(a: std.mem.Allocator, code: u32, desc: []const u8, migrate_to: i64) Verdict {
    if (migrate_to != 0) return .{ .class = .migrated, .why = "the chat was upgraded and has a new id" };
    const rows = std.json.parseFromSliceLeaky([]const Row, a, table_json, .{}) catch return .{ .class = .fail, .why = "Telegram refused the request" };
    for (rows) |r| {
        if (r.code != 0 and r.code != code) continue;
        if (!containsLower(desc, r.has)) continue;
        return .{ .class = classOf(r.class) orelse .fail, .why = r.why };
    }
    return .{ .class = .fail, .why = "Telegram refused the request" };
}

test "the shipped table parses, every class is known, the last row catches all" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const rows = try std.json.parseFromSliceLeaky([]const Row, ar.allocator(), table_json, .{});
    try std.testing.expect(rows.len >= 10);
    for (rows) |r| try std.testing.expect(classOf(r.class) != null);
    try std.testing.expectEqual(@as(u32, 0), rows[rows.len - 1].code);
}

test "codes and words map to classes; unknown stays a plain failure" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    try std.testing.expect(classify(a, 429, "Too Many Requests: retry after 5", 0).class == .flood);
    try std.testing.expect(classify(a, 401, "Unauthorized", 0).class == .dead_token);
    try std.testing.expect(classify(a, 403, "Forbidden: bot was kicked from the channel chat", 0).class == .no_right);
    try std.testing.expect(classify(a, 400, "Bad Request: chat not found", 0).class == .no_chat);
    try std.testing.expect(classify(a, 400, "Bad Request: message caption is too long", 0).class == .caption);
    try std.testing.expect(classify(a, 400, "Bad Request: file is too big", 0).class == .too_big);
    try std.testing.expect(classify(a, 413, "Request Entity Too Large", 0).class == .too_big);
    try std.testing.expect(classify(a, 409, "Conflict: can't use getUpdates while webhook is active", 0).class == .conflict);
    try std.testing.expect(classify(a, 400, "Bad Request: something never seen before", 0).class == .fail);
    try std.testing.expect(classify(a, 418, "teapot", 0).class == .fail);
    // a moved chat wins over every word
    try std.testing.expect(classify(a, 400, "Bad Request: group chat was upgraded to a supergroup chat", -100777).class == .migrated);
    try std.testing.expect(classify(a, 400, "Bad Request: group chat was upgraded to a supergroup chat", 0).class == .migrated);
}
// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
