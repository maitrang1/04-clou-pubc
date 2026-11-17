// approve / hold: a person's decision for review:true pairs. Writes only with --live.
const std = @import("std");
const Ctx = @import("co-ctx.zig").Ctx;
const args = @import("co-args.zig");
const exit = @import("co-exit.zig");
const out = @import("co-out.zig");
const log = @import("co-log.zig");
const send = @import("rw-send.zig");
const pair = @import("rw-pair.zig");

pub fn run(cx: *Ctx, av: []const []const u8, approve: bool) u8 {
    var arena = std.heap.ArenaAllocator.init(cx.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const name = args.value(av, "--video") orelse {
        out.warn(cx, "error: --video <name> is required", .{});
        return exit.USAGE;
    };
    var db = send.open(cx) catch return exit.BLOCKED;
    defer db.close();
    const es = pair.scan(cx, a, &db) catch {
        out.warn(cx, "error: source.dir is not set or cannot be opened", .{});
        return exit.USAGE;
    };
    const e = pair.find(es, name) orelse {
        out.warn(cx, "error: no pair named '{s}' in the source folder", .{name});
        return exit.FAILED;
    };
    if (!e.j.review) {
        out.say(cx, "'{s}' has review:false: it never needs approval", .{name});
        return exit.OK;
    }
    if (e.kind == .done) {
        out.say(cx, "'{s}' was already sent ({s}): nothing to decide", .{ name, e.reason });
        return exit.OK;
    }
    const verb: []const u8 = if (approve) "approved" else "held";
    const stored: []const u8 = if (approve) (pair.approvalSig(a, e) catch return exit.FAILED) else "held";
    if (!cx.live) {
        out.say(cx, "dry-run: would mark '{s}' as {s}. Add --live to write it.", .{ name, verb });
        out.json(cx, a, .{ .name = name, .would = verb, .written = false });
        return exit.OK;
    }
    send.setApproval(cx, &db, name, stored) catch |er| {
        out.warn(cx, "blocked: {s}", .{@errorName(er)});
        return exit.BLOCKED;
    };
    log.log(cx, "info", "{s} {s} by a person", .{ name, verb });
    out.say(cx, "{s}: {s}", .{ verb, name });
    out.json(cx, a, .{ .name = name, .state = verb, .written = true });
    return exit.OK;
}
