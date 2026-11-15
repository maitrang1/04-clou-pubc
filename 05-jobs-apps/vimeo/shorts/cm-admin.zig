// =====================================================================
// Des: The small admin commands - kill (stop every write), backup (consistent copy of the ledger, never overwrites), config (print the checked settings; reset the breaker with --live)
// Flo: kill [on|off] > backup > config [--reset-breaker]
// Cre: 2026-11-15                          - | Mod: 2026-11-15
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: kill [on|off] · backup · config [--reset-breaker] [--live]
// Out: one or a few lines; exit 0 ok · 2 usage · 3 blocked
// Run: /home/mai_trang/04-clou-base/05-jobs-apps/vimeo/shorts/zig-out/bin/shorts kill on
// =====================================================================
const std = @import("std");
const ctx_mod = @import("co-ctx.zig");
const util = @import("co-util.zig");
const args = @import("co-args.zig");
const exit = @import("co-exit.zig");
const kill = @import("co-kill.zig");
const log = @import("co-log.zig");
const send = @import("rw-send.zig");
const caps = @import("rw-caps.zig");

// emergency tools: work at once, no --live needed
pub fn killCmd(cx: *const ctx_mod.Ctx, av: []const []const u8) u8 {
    var arena = std.heap.ArenaAllocator.init(cx.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    if (av.len == 0) {
        util.print(cx.io, "kill file: {s}\n", .{if (kill.isOn(cx, a)) "ON (every write is refused)" else "off"});
        return exit.ok;
    }
    const on = std.mem.eql(u8, av[0], "on");
    if (!on and !std.mem.eql(u8, av[0], "off")) {
        util.eprint(cx.io, "error: kill takes on or off\nwhy: got '{s}'\nfix: shorts kill on\n", .{av[0]});
        return exit.usage;
    }
    kill.set(cx, a, on) catch {
        util.eprint(cx.io, "error: cannot change the kill file\nwhy: the data folder is not writable\nfix: check {s}\n", .{cx.data_dir});
        return exit.blocked;
    };
    log.line(cx, "WARN", "kill file {s}", .{av[0]});
    util.print(cx.io, "kill file: {s}\n", .{if (on) "ON: every write is refused" else "off (old file kept as .off-<time>)"});
    return exit.ok;
}

pub fn backup(cx: *const ctx_mod.Ctx, _: []const []const u8) u8 {
    var arena = std.heap.ArenaAllocator.init(cx.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const l = send.Ledger.open(cx, a) catch {
        util.eprint(cx.io, "error: the ledger cannot be opened\nwhy: nothing to back up\nfix: shorts doctor\n", .{});
        return exit.blocked;
    };
    defer l.close();
    util.mkdirp(cx.io, std.fmt.allocPrint(a, "{s}/backup", .{cx.data_dir}) catch return exit.failed) catch return exit.failed;
    var tb: [32]u8 = undefined;
    const ts = util.fmtTs(&tb, cx.nowMs(), 0);
    var stamp: [20]u8 = undefined;
    var n: usize = 0;
    for (ts) |ch| {
        if (ch >= '0' and ch <= '9') {
            stamp[n] = ch;
            n += 1;
        }
    }
    const to = std.fmt.allocPrint(a, "{s}/backup/ledger-{s}.db", .{ cx.data_dir, stamp[0..n] }) catch return exit.failed;
    l.backup(to, cx.io) catch |e| {
        util.eprint(cx.io, "error: backup failed ({s})\nwhy: the target exists or cannot be written\nfix: wait a second and run again\n", .{@errorName(e)});
        return exit.failed;
    };
    util.print(cx.io, "backup: {s}\n", .{to});
    return exit.ok;
}

pub fn config(cx: *const ctx_mod.Ctx, av: []const []const u8, json: bool) u8 {
    var arena = std.heap.ArenaAllocator.init(cx.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    if (args.has(av, "--reset-breaker")) {
        if (!args.has(av, "--live")) {
            util.print(cx.io, "dry run: would close the breaker. Add --live to write.\n", .{});
            return exit.ok;
        }
        const l = send.Ledger.open(cx, a) catch return exit.blocked;
        defer l.close();
        caps.breakerReset(l) catch return exit.failed;
        log.line(cx, "WARN", "breaker reset by a person", .{});
        util.print(cx.io, "breaker: closed\n", .{});
        return exit.ok;
    }
    // secrets never live in the config; print the checked settings plus the resolved folders
    const s = std.json.Stringify.valueAlloc(a, cx.cfg, .{ .whitespace = .indent_2 }) catch return exit.failed;
    if (json) {
        util.printAll(cx.io, s);
        util.printAll(cx.io, "\n");
    } else {
        util.print(cx.io, "config is valid.\ndata folder: {s}\nsecrets folder: {s}\n---\n", .{ cx.data_dir, cx.secrets_dir });
        util.printAll(cx.io, s);
        util.printAll(cx.io, "\n");
    }
    return exit.ok;
}
// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
