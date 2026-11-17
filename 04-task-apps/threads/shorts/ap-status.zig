// Step 2: GET /{container}?fields=status,error_message. Statuses: IN_PROGRESS, FINISHED, PUBLISHED, ERROR, EXPIRED. Unknown text = unknown (keep waiting, never guess).
const std = @import("std");
const Ctx = @import("co-ctx.zig").Ctx;
const call = @import("ap-call.zig");
const js = @import("ap-json.zig");

pub const Kind = enum { in_progress, finished, published, failed, expired, unknown };
pub const Status = struct { kind: Kind = .unknown, raw: []const u8 = "", error_message: []const u8 = "" };

pub fn kindOf(s: []const u8) Kind {
    const eq = std.mem.eql;
    if (eq(u8, s, "IN_PROGRESS")) return .in_progress;
    if (eq(u8, s, "FINISHED")) return .finished;
    if (eq(u8, s, "PUBLISHED")) return .published;
    if (eq(u8, s, "ERROR")) return .failed;
    if (eq(u8, s, "EXPIRED")) return .expired;
    return .unknown;
}

pub fn parse(a: std.mem.Allocator, body: []const u8) ?Status {
    const root = js.parse(a, body) orelse return null;
    const st = js.str(root, "status");
    if (st.len == 0) return null;
    return .{ .kind = kindOf(st), .raw = st, .error_message = js.str(root, "error_message") };
}

pub fn get(cx: *const Ctx, a: std.mem.Allocator, tok: []const u8, container: []const u8) call.Out(Status) {
    if (!call.idOk(container)) return .{ .fail = .{ .info = .{ .class = .failed, .msg = "container id must be digits" } } };
    const path = std.fmt.allocPrint(a, "{s}?fields=status,error_message", .{container}) catch return .{ .fail = .{ .info = .{ .class = .failed, .msg = "out of memory" } } };
    const url = call.graphUrl(cx, a, path) catch return .{ .fail = .{ .info = .{ .class = .failed, .msg = "out of memory" } } };
    switch (call.call(cx, a, .{ .url = url, .token = tok })) {
        .fail => |f| return .{ .fail = f },
        .ok => |ok| {
            const s = parse(a, ok.body) orelse return .{ .fail = .{ .info = .{ .class = .retry, .msg = "status reply unreadable" }, .body = ok.body } };
            return .{ .ok = s };
        },
    }
}

test "status words parse, unknown stays unknown" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqual(Kind.finished, parse(a, "{\"status\":\"FINISHED\",\"id\":\"1\"}").?.kind);
    try std.testing.expectEqual(Kind.in_progress, parse(a, "{\"status\":\"IN_PROGRESS\"}").?.kind);
    try std.testing.expectEqual(Kind.published, parse(a, "{\"status\":\"PUBLISHED\"}").?.kind);
    try std.testing.expectEqual(Kind.expired, parse(a, "{\"status\":\"EXPIRED\"}").?.kind);
    const e = parse(a, "{\"status\":\"ERROR\",\"error_message\":\"FAILED_DOWNLOADING_VIDEO\"}").?;
    try std.testing.expectEqual(Kind.failed, e.kind);
    try std.testing.expectEqualStrings("FAILED_DOWNLOADING_VIDEO", e.error_message);
    try std.testing.expectEqual(Kind.unknown, parse(a, "{\"status\":\"NEW_THING\"}").?.kind);
    try std.testing.expect(parse(a, "not json") == null);
    try std.testing.expect(parse(a, "{}") == null);
}
