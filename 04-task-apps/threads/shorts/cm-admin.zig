// kill (stop every write) · backup (copy the ledger) · config (show, validate, reset the breaker).
const std = @import("std");
const Ctx = @import("co-ctx.zig").Ctx;
const args = @import("co-args.zig");
const exit = @import("co-exit.zig");
const out = @import("co-out.zig");
const log = @import("co-log.zig");
const kill = @import("co-kill.zig");
const send = @import("rw-send.zig");
const caps = @import("rw-caps.zig");
const util = @import("co-util.zig");

// --on is safe and always works; --off needs --live
pub fn killCmd(cx: *Ctx, av: []const []const u8) u8 {
    const on = args.has(av, "--on");
    const off = args.has(av, "--off");
    if (on and off) return exit.USAGE;
    if (on or off) {
        if (off and !cx.live) {
            out.say(cx, "dry-run: would clear the kill file. Add --live.", .{});
            return exit.OK;
        }
        kill.setKill(cx, on) catch {
            out.warn(cx, "error: cannot write the kill file in the data folder", .{});
            return exit.FAILED;
        };
        log.log(cx, "warn", "kill file {s}", .{if (on) "ON" else "off"});
    }
    out.say(cx, "kill file: {s}", .{if (kill.killOn(cx)) "ON (nothing is written or sent)" else "off"});
    return exit.OK;
}

pub fn backup(cx: *Ctx, av: []const []const u8) u8 {
    _ = av;
    var arena = std.heap.ArenaAllocator.init(cx.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const stamp = @divTrunc(cx.nowMs(), 1000);
    const dest = cx.dataPath(a, std.fmt.allocPrint(a, "backup/ledger-{d}.db", .{stamp}) catch return exit.FAILED) catch return exit.FAILED;
    if (!cx.live) {
        out.say(cx, "dry-run: would copy the ledger to {s}. Add --live.", .{dest});
        return exit.OK;
    }
    kill.writeOk(cx) catch {
        out.warn(cx, "blocked: kill file is on", .{});
        return exit.BLOCKED;
    };
    var db = send.open(cx) catch return exit.BLOCKED;
    defer db.close();
    const dir = cx.dataPath(a, "backup") catch return exit.FAILED;
    util.mkdirp(cx.io, dir) catch return exit.FAILED;
    const vac = blk: {
        var st = db.prepare("VACUUM INTO ?1") catch break :blk false;
        defer st.finalize();
        st.text(1, dest) catch break :blk false;
        _ = st.step() catch break :blk false;
        break :blk true;
    };
    if (!vac) {
        out.warn(cx, "error: backup failed (is there already a file at {s}?)", .{dest});
        return exit.FAILED;
    }
    log.log(cx, "info", "backup {s}", .{dest});
    out.say(cx, "backup: {s}", .{dest});
    out.json(cx, a, .{ .backup = dest });
    return exit.OK;
}

pub fn configCmd(cx: *Ctx, av: []const []const u8) u8 {
    var arena = std.heap.ArenaAllocator.init(cx.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    if (args.has(av, "--reset-breaker")) {
        if (!cx.live) {
            out.say(cx, "dry-run: would reset the breaker and any limit stop. Add --live.", .{});
            return exit.OK;
        }
        kill.writeOk(cx) catch return exit.BLOCKED;
        var db = send.open(cx) catch return exit.BLOCKED;
        defer db.close();
        caps.resetBreaker(&db) catch return exit.FAILED;
        log.log(cx, "warn", "breaker reset by a person", .{});
        out.say(cx, "breaker and quota stop cleared", .{});
        return exit.OK;
    }
    const s = std.json.Stringify.valueAlloc(a, cx.cfg, .{ .whitespace = .indent_2 }) catch return exit.FAILED;
    util.printAll(cx.io, s);
    util.printAll(cx.io, "\n");
    return exit.OK;
}
