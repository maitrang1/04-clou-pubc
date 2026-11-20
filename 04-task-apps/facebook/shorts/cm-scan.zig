// scan: list every pair in the hand-off folder: ready / invalid / skipped / done, with plain reasons. Read-only.
const std = @import("std");
const Ctx = @import("co-ctx.zig").Ctx;
const exit = @import("co-exit.zig");
const out = @import("co-out.zig");
const open = @import("co-open.zig");
const pair = @import("rw-pair.zig");

const Row = struct { name: []const u8, kind: []const u8, reason: []const u8, note: []const u8, size: u64 };

pub fn run(cx: *Ctx, av: []const []const u8) u8 {
    _ = av;
    var arena = std.heap.ArenaAllocator.init(cx.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var db = open.existing(cx);
    defer if (db) |*d| d.close();
    const es = pair.scan(cx, a, if (db) |*d| d else null) catch {
        out.warn(cx, "error: source.dir is not set or cannot be opened\nwhy: the hand-off folder is missing\nfix: set \"source\":{{\"dir\":...}} in 00-config.json", .{});
        return exit.USAGE;
    };
    var rows: std.ArrayList(Row) = .empty;
    var n = [_]usize{0} ** 4;
    for (es) |e| {
        n[@intFromEnum(e.kind)] += 1;
        rows.append(a, .{ .name = e.name, .kind = @tagName(e.kind), .reason = e.reason, .note = e.note, .size = e.size }) catch return exit.FAILED;
        out.say(cx, "{s:<8} {s}{s}{s}{s}{s}", .{ @tagName(e.kind), e.name, if (e.reason.len > 0) "  - " else "", e.reason, if (e.note.len > 0) "  (" else "", e.note });
        if (e.note.len > 0) out.say(cx, "", .{});
    }
    out.say(cx, "{d} ready · {d} invalid · {d} skipped · {d} already sent", .{ n[0], n[1], n[2], n[3] });
    out.json(cx, a, .{ .ready = n[0], .invalid = n[1], .skipped = n[2], .done = n[3], .pairs = rows.items });
    return exit.OK;
}
