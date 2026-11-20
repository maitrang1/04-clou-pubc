// =====================================================================
// Des: The CLI entry point of the YouTube Shorts publisher - reads flags, loads the strict config, builds the context and dispatches one command; exit codes are fixed (0 ok, 1 failed, 2 usage, 3 blocked, 4 nothing to do, 5 unsure)
// Flo: parse args > load 00-config.json > resolve data and secrets folders > dispatch command > exit code
// Cre: 2026-11-15                          - | Mod: 2026-11-15
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: shorts <doctor|status|scan|publish|resolve|login|token|kill|backup|config|version|help> [--config FILE] [--json] [--live] ...
// Out: lines on stdout (errors on stderr); exit code
// Run: cd /home/mai_trang/04-clou-base/04-task-apps/youtube/shorts && zig build run -- scan
// Exe: /home/mai_trang/04-clou-base/04-task-apps/youtube/shorts/zig-out/bin/shorts
// =====================================================================
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
const resolve_cmd = @import("cm-resolve.zig");
const login_cmd = @import("cm-login.zig");
const token_cmd = @import("cm-token.zig");
const admin_cmd = @import("cm-admin.zig");

pub const Ctx = ctx_mod.Ctx;

const Usage =
    \\shorts <command> [--config FILE] [--json] [--live]
    \\  doctor                          check everything a run needs (no upload)
    \\  status                          counts, today's cap, breaker, stop, held videos
    \\  scan                            every video in source.dir with its status and reason
    \\  publish [--video NAME] [--live] send the oldest ready video (dry run without --live)
    \\  resolve --video NAME [--live]   settle an unsure send (never uploads again)
    \\  login [--live] [--paste] [--force]   one-time Google sign-in
    \\  token                           does the stored sign-in still work
    \\  kill [on|off]                   stop every write at once
    \\  backup                          copy the ledger
    \\  config [--reset-breaker --live] print the checked settings
    \\  version
    \\exit: 0 ok · 1 failed · 2 usage/config · 3 blocked · 4 nothing to do · 5 unsure
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
    while (it.next()) |a| try list.append(arena, a);
    const av = list.items;
    if (av.len == 0 or std.mem.eql(u8, av[0], "help") or std.mem.eql(u8, av[0], "--help")) {
        util.printAll(io, Usage);
        std.process.exit(if (av.len == 0) exit.usage else exit.ok);
    }
    if (std.mem.eql(u8, av[0], "version")) {
        util.print(io, "shorts {s}{s}\n", .{ bo.version, if (bo.mock) " (mock build: loopback http allowed, never release)" else "" });
        std.process.exit(exit.ok);
    }
    var config_path: []const u8 = "00-config.json";
    var json = false;
    var rest: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < av.len) : (i += 1) {
        if (std.mem.eql(u8, av[i], "--config") and i + 1 < av.len) {
            i += 1;
            config_path = av[i];
        } else if (std.mem.eql(u8, av[i], "--json")) json = true else try rest.append(arena, av[i]);
    }
    // default config: ./00-config.json, else the one next to the exe (release folder layout)
    if (std.mem.eql(u8, config_path, "00-config.json") and !util.exists(io, config_path)) {
        if (std.process.executableDirPathAlloc(io, arena)) |d| {
            const alt = try std.fmt.allocPrint(arena, "{s}/00-config.json", .{d});
            if (util.exists(io, alt)) config_path = alt;
        } else |_| {}
    }
    var why: [160]u8 = undefined;
    var wl: usize = 0;
    const cfg = cfg_mod.load(arena, io, config_path, &why, &wl) catch die(io, exit.usage, "error: {s}\nwhy: bad or missing config\nfix: edit {s} (unknown keys are refused)", .{ why[0..wl], config_path });
    const cfg_dir = std.fs.path.dirname(config_path) orelse ".";
    const data = ctx_mod.resolveData(arena, init.environ_map, cfg_dir, cfg.data_dir) catch die(io, exit.usage, "error: no data folder\nwhy: HOME, USERPROFILE and {s} are unset\nfix: set data_dir in the config", .{ctx_mod.home_env});
    const secr = ctx_mod.resolveSecrets(arena, init.environ_map, cfg_dir, cfg.secrets_dir) catch die(io, exit.usage, "error: no secrets folder\nwhy: HOME and USERPROFILE are unset\nfix: set secrets_dir in the config", .{});
    var cx = Ctx{ .io = io, .gpa = init.gpa, .arena = arena, .env = init.environ_map, .cfg = cfg, .cfg_dir = cfg_dir, .data_dir = data, .secrets_dir = secr, .mock = bo.mock };
    std.process.exit(dispatch(&cx, rest.items, json));
}

pub fn dispatch(cx: *Ctx, av: []const []const u8, json: bool) u8 {
    if (av.len == 0) {
        util.eprint(cx.io, "{s}", .{Usage});
        return exit.usage;
    }
    const cmd = av[0];
    const rest = av[1..];
    if (std.mem.eql(u8, cmd, "doctor")) return doctor_cmd.run(cx, rest);
    if (std.mem.eql(u8, cmd, "status")) return status_cmd.run(cx, rest, json);
    if (std.mem.eql(u8, cmd, "scan")) return scan_cmd.run(cx, rest, json);
    if (std.mem.eql(u8, cmd, "publish")) return publish_cmd.run(cx, rest, json);
    if (std.mem.eql(u8, cmd, "resolve")) return resolve_cmd.run(cx, rest);
    if (std.mem.eql(u8, cmd, "login")) return login_cmd.run(cx, rest);
    if (std.mem.eql(u8, cmd, "token")) return token_cmd.run(cx, rest);
    if (std.mem.eql(u8, cmd, "kill")) return admin_cmd.killCmd(cx, rest);
    if (std.mem.eql(u8, cmd, "backup")) return admin_cmd.backup(cx, rest);
    if (std.mem.eql(u8, cmd, "config")) return admin_cmd.config(cx, rest, json);
    util.eprint(cx.io, "error: unknown command '{s}'\nwhy: not in the command list\nfix: run shorts with no args\n", .{cmd});
    return exit.usage;
}

test {
    _ = @import("co-util.zig");
    _ = @import("co-cfg.zig");
    _ = @import("co-ctx.zig");
    _ = @import("co-args.zig");
    _ = @import("co-exit.zig");
    _ = @import("co-guard.zig");
    _ = @import("co-net.zig");
    _ = @import("co-http.zig");
    _ = @import("co-kill.zig");
    _ = @import("co-lock.zig");
    _ = @import("co-log.zig");
    _ = @import("co-disk.zig");
    _ = @import("rw-sqlite.zig");
    _ = @import("rw-send.zig");
    _ = @import("rw-caps.zig");
    _ = @import("rw-text.zig");
    _ = @import("rw-probe.zig");
    _ = @import("rw-pair.zig");
    _ = @import("rw-pick.zig");
    _ = @import("ap-err.zig");
    _ = @import("ap-auth.zig");
    _ = @import("ap-call.zig");
    _ = @import("ap-session.zig");
    _ = @import("ap-upload.zig");
    _ = @import("ap-status.zig");
    _ = @import("ap-list.zig");
    _ = @import("ap-cats.zig");
    _ = @import("cm-send.zig");
    _ = @import("cm-publish.zig");
    _ = @import("cm-scan.zig");
    _ = @import("cm-status.zig");
    _ = @import("cm-resolve.zig");
    _ = @import("cm-login.zig");
    _ = @import("cm-token.zig");
    _ = @import("cm-doctor.zig");
    _ = @import("cm-admin.zig");
    _ = @import("te-mini-srv.zig");
    _ = @import("te-fake-yt.zig");
    _ = @import("te-e2e.zig");
    _ = @import("te-hard.zig");
}
// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
