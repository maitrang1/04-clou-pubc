// instagram-shorts: publish finished short videos to ONE Instagram professional account as Reels, once each, with a ledger. CLI only.
// Exit: 0 ok · 1 failed · 2 usage/config · 3 blocked · 4 nothing to do · 5 unsure (run resolve).
const std = @import("std");
const bo = @import("build_options");
const util = @import("co-util.zig");
const cfg_mod = @import("co-cfg.zig");
const ctx_mod = @import("co-ctx.zig");
const exit = @import("co-exit.zig");
const doctor_cmd = @import("cm-doctor.zig");
const status_cmd = @import("cm-status.zig");
const scan_cmd = @import("cm-scan.zig");
const publish_cmd = @import("cm-publish.zig");
const approve_cmd = @import("cm-approve.zig");
const resolve_cmd = @import("cm-resolve.zig");
const token_cmd = @import("cm-token.zig");
const admin_cmd = @import("cm-admin.zig");

pub const Ctx = ctx_mod.Ctx;

const Usage =
    \\instagram-shorts <command> [--config FILE] [--json] [--live]
    \\  doctor                      is everything ready? (reads only)
    \\  status [--verify]           counts, 24 h caps, breaker, held/staged lists (--verify: Meta's allowance)
    \\  scan                        list the pairs in the hand-off folder
    \\  publish [--video NAME] [--again]   send the oldest ready pair; staged unless post.public (dry-run unless --live)
    \\  approve --video NAME        let a review:true pair go (needs --live to write)
    \\  hold --video NAME           take the approval back
    \\  resolve --video NAME [--as posted|failed]   settle an unsure send; never re-sends
    \\  token                       check the token works (a read; no expiry date exists)
    \\  kill [--on|--off]           stop every write (--off needs --live)
    \\  backup                      copy the ledger (needs --live)
    \\  config [--reset-breaker]    show the settings; clear the breaker (needs --live)
    \\Every write is a dry-run unless --live. Exit: 0 ok · 1 failed · 2 usage/config · 3 blocked · 4 nothing to do · 5 unsure
    \\
;

fn die(io: std.Io, code: u8, comptime fmt: []const u8, args: anytype) noreturn {
    util.eprint(io, fmt ++ "\n", args);
    std.process.exit(code);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    var it = try init.minimal.args.iterateAllocator(arena);
    _ = it.next();
    var list: std.ArrayList([]const u8) = .empty;
    while (it.next()) |x| try list.append(arena, x);
    const av = list.items;
    if (av.len == 0 or std.mem.eql(u8, av[0], "--help") or std.mem.eql(u8, av[0], "help")) {
        util.printAll(io, Usage);
        std.process.exit(if (av.len == 0) exit.USAGE else exit.OK);
    }
    var config_path: []const u8 = "00-config.json";
    var json = false;
    var live = false;
    var rest: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < av.len) : (i += 1) {
        if (std.mem.eql(u8, av[i], "--config") and i + 1 < av.len) {
            i += 1;
            config_path = av[i];
        } else if (std.mem.eql(u8, av[i], "--json")) json = true else if (std.mem.eql(u8, av[i], "--live")) live = true else if (std.mem.eql(u8, av[i], "--help")) {
            util.printAll(io, Usage);
            std.process.exit(exit.OK);
        } else try rest.append(arena, av[i]);
    }
    if (init.environ_map.get("INST_SHOR_CONFIG")) |p| if (p.len > 0 and std.mem.eql(u8, config_path, "00-config.json")) {
        config_path = p;
    };
    // default config: ./00-config.json, else the one next to the exe
    if (std.mem.eql(u8, config_path, "00-config.json") and !util.exists(io, config_path)) {
        if (std.process.executableDirPathAlloc(io, arena)) |d| {
            const alt = try std.fmt.allocPrint(arena, "{s}/00-config.json", .{d});
            if (util.exists(io, alt)) config_path = alt;
        } else |_| {}
    }
    var why: [160]u8 = undefined;
    var wl: usize = 0;
    const cfg = cfg_mod.load(arena, io, config_path, &why, &wl) catch die(io, exit.USAGE, "error: {s}\nwhy: bad or missing config\nfix: edit {s} (unknown keys are refused)", .{ why[0..wl], config_path });
    const home = ctx_mod.resolveHome(arena, init.environ_map) catch die(io, exit.USAGE, "error: no home folder\nwhy: HOME and USERPROFILE are unset\nfix: set INST_SHOR_HOME to a folder", .{});
    const cfg_dir = std.fs.path.dirname(config_path) orelse ".";
    var cx = Ctx{ .cfg_dir = cfg_dir, .io = io, .gpa = init.gpa, .arena = arena, .env = init.environ_map, .cfg = cfg, .home = home, .mock = bo.mock, .live = live, .json = json };
    std.process.exit(dispatch(&cx, rest.items));
}

pub fn dispatch(cx: *Ctx, av: []const []const u8) u8 {
    if (av.len == 0) {
        util.eprint(cx.io, "{s}", .{Usage});
        return exit.USAGE;
    }
    const cmd = av[0];
    const rest = av[1..];
    if (std.mem.eql(u8, cmd, "publish")) return publish_cmd.run(cx, rest);
    if (std.mem.eql(u8, cmd, "scan")) return scan_cmd.run(cx, rest);
    if (std.mem.eql(u8, cmd, "status")) return status_cmd.run(cx, rest);
    if (std.mem.eql(u8, cmd, "doctor")) return doctor_cmd.run(cx, rest);
    if (std.mem.eql(u8, cmd, "approve")) return approve_cmd.run(cx, rest, true);
    if (std.mem.eql(u8, cmd, "hold")) return approve_cmd.run(cx, rest, false);
    if (std.mem.eql(u8, cmd, "resolve")) return resolve_cmd.run(cx, rest);
    if (std.mem.eql(u8, cmd, "token")) return token_cmd.run(cx, rest);
    if (std.mem.eql(u8, cmd, "kill")) return admin_cmd.killCmd(cx, rest);
    if (std.mem.eql(u8, cmd, "backup")) return admin_cmd.backup(cx, rest);
    if (std.mem.eql(u8, cmd, "config")) return admin_cmd.configCmd(cx, rest);
    if (comptime bo.mock) if (std.mem.eql(u8, cmd, "fake")) return fakeServe(cx); // mock builds only: a pretend Instagram for hand testing
    util.eprint(cx.io, "error: unknown command '{s}'\nwhy: not in the command list\nfix: run instagram-shorts with no args\n", .{cmd});
    return exit.USAGE;
}

// mock builds only: serve the test fake on a spare port until killed; prints the port
fn fakeServe(cx: *Ctx) u8 {
    const fk = @import("te-fake-graph.zig");
    const f = fk.Fake.start(cx.io) catch return exit.FAILED;
    f.script = &[_]fk.Mode{ .in_progress, .finished };
    util.print(cx.io, "fake instagram on http://127.0.0.1:{d} (token TESTTOKEN, user id 1784140000)\n", .{f.port});
    while (true) util.sleepMs(cx.io, 1000);
}

test {
    _ = @import("co-util.zig");
    _ = @import("co-args.zig");
    _ = @import("co-cfg.zig");
    _ = @import("co-os.zig");
    _ = @import("co-ctx.zig");
    _ = @import("co-kill.zig");
    _ = @import("co-log.zig");
    _ = @import("co-guard.zig");
    _ = @import("co-net.zig");
    _ = @import("ap-error.zig");
    _ = @import("ap-call.zig");
    _ = @import("ap-status.zig");
    _ = @import("ap-quota.zig");
    _ = @import("rw-sqlite.zig");
    _ = @import("rw-send.zig");
    _ = @import("rw-caps.zig");
    _ = @import("rw-text.zig");
    _ = @import("rw-probe.zig");
    _ = @import("rw-pair.zig");
    _ = @import("te-mp4.zig");
    _ = @import("te-net.zig");
    _ = @import("te-publish.zig");
    _ = @import("te-cmds.zig");
    _ = @import("te-guard.zig");
    _ = @import("te-probe.zig");
}
