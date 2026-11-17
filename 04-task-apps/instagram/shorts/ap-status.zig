// Step 3: GET {container}?fields=status_code,status. status_code: IN_PROGRESS | FINISHED | PUBLISHED | ERROR | EXPIRED. Unknown text = keep waiting, never "ok".
const std = @import("std");
const Ctx = @import("co-ctx.zig").Ctx;
const call = @import("ap-call.zig");
const js = @import("ap-json.zig");

pub const Status = struct { code: []const u8 = "", sub: []const u8 = "", copyright_match: bool = false };
pub const Verdict = enum { in_progress, finished, published, failed, expired, unknown };

pub fn parse(a: std.mem.Allocator, body: []const u8) ?Status {
    const root = js.parse(a, body) orelse return null;
    if (root != .object) return null;
    const st = js.obj(root, "status");
    const sub: []const u8 = if (st) |s| switch (s) {
        .string => |x| x,
        .integer => |i| std.fmt.allocPrint(a, "{d}", .{i}) catch "",
        else => "",
    } else "";
    return .{ .code = js.str(root, "status_code"), .sub = sub, .copyright_match = js.boolean(js.obj(root, "copyright_check_status"), "matches_found") };
}

pub fn verdict(s: Status) Verdict {
    const eq = std.mem.eql;
    if (eq(u8, s.code, "FINISHED")) return .finished;
    if (eq(u8, s.code, "PUBLISHED")) return .published;
    if (eq(u8, s.code, "ERROR")) return .failed;
    if (eq(u8, s.code, "EXPIRED")) return .expired;
    if (eq(u8, s.code, "IN_PROGRESS")) return .in_progress;
    return .unknown;
}

pub fn get(cx: *const Ctx, a: std.mem.Allocator, tok: []const u8, cont_id: []const u8) call.Out(Status) {
    if (!call.idOk(cont_id)) return .{ .fail = .{ .info = .{ .class = .failed, .msg = "container id must be digits" } } };
    const path = std.fmt.allocPrint(a, "{s}?fields=status_code,status", .{cont_id}) catch return .{ .fail = .{ .info = .{ .class = .failed, .msg = "out of memory" } } };
    const url = call.graphUrl(cx, a, path) catch return .{ .fail = .{ .info = .{ .class = .failed, .msg = "out of memory" } } };
    switch (call.call(cx, a, .{ .url = url, .token = tok })) {
        .fail => |f| return .{ .fail = f },
        .ok => |ok| {
            const s = parse(a, ok.body) orelse return .{ .fail = .{ .info = .{ .class = .retry, .msg = "status reply unreadable" }, .body = ok.body } };
            return .{ .ok = s };
        },
    }
}

test "status codes and verdicts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqual(Verdict.finished, verdict(parse(a, "{\"status_code\":\"FINISHED\",\"id\":\"1\"}").?));
    try std.testing.expectEqual(Verdict.in_progress, verdict(parse(a, "{\"status_code\":\"IN_PROGRESS\"}").?));
    try std.testing.expectEqual(Verdict.published, verdict(parse(a, "{\"status_code\":\"PUBLISHED\"}").?));
    try std.testing.expectEqual(Verdict.expired, verdict(parse(a, "{\"status_code\":\"EXPIRED\"}").?));
    const e = parse(a, "{\"status_code\":\"ERROR\",\"status\":\"2207026\"}").?;
    try std.testing.expectEqual(Verdict.failed, verdict(e));
    try std.testing.expectEqualStrings("2207026", e.sub);
    try std.testing.expectEqual(Verdict.unknown, verdict(parse(a, "{}").?));
    try std.testing.expectEqual(Verdict.unknown, verdict(parse(a, "{\"status_code\":\"WEIRD\"}").?));
    try std.testing.expect(parse(a, "not json") == null);
    try std.testing.expect(parse(a, "[1]") == null);
    try std.testing.expect(parse(a, "{\"status_code\":\"FINISHED\",\"copyright_check_status\":{\"matches_found\":true}}").?.copyright_match);
}
