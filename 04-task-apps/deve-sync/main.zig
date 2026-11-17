// =====================================================================
// Des: The CLI entry point - keeps Claude Code, VS Code and local tool settings the same on every device through the repo's .deve-user folder
// Flo: parse args > load 00-config.json > resolve per-OS paths > plan (compare both sides) > status / check / pull / push > print what happened > exit code
// Cre: 2026-11-15                          - | Mod: 2026-11-15
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: none - `deve-sync status|check|pull|push|version|help` -- --repo --config --home --only --go
// Out: exit 0 ok · 1 failed · 2 usage/config · 3 not in sync (check)
// Run: cd /home/mai_trang/04-clou-base/04-task-apps/deve-sync && zig build run -- status --repo /home/mai_trang/04-clou-base
// Exe: /home/mai_trang/04-clou-base/04-task-apps/deve-sync/zig-out/bin/deve-sync
// =====================================================================
const std = @import("std");
const build_options = @import("build_options");
const conf = @import("co-config.zig");
const os = @import("co-os.zig");
const out = @import("co-out.zig");
const pl = @import("cm-plan.zig");
const ap = @import("cm-apply.zig");
const cb = @import("cm-base.zig");
const tri = @import("cm-tri.zig");

const CF = .{ .conf_rel = "04-task-apps/deve-sync/00-config.json", .exit_ok = 0, .exit_fail = 1, .exit_use = 2, .exit_diff = 3, .rows_max = 12 };

const USAGE =
    \\deve-sync - keep Claude Code, VS Code and local tool settings the same on every device, through the repo's .deve-user folder
    \\
    \\Usage: deve-sync <command> --repo <folder> [flags]
    \\
    \\Commands:
    \\  status   compare this device with the repo, item by item (read-only)
    \\  check    like status, plus one fingerprint line for check-parity.sh (read-only; exit 3 when not in sync)
    \\  sync     two-way and truly safe: a change on one side goes to the other, a missing file comes back, nothing is ever deleted; a file changed on both sides is auto-merged (code, text; sync.merge_globs), else the newest edit wins and the other copy goes to the trash folder (sync.trash_dir). Dry-run unless --go
    \\  pull     the repo wins: this device takes the repo's version of every file the repo changed (and of a conflict); the old copy is saved first. Dry-run unless --go
    \\  push     this device wins: the repo takes this device's version of every file this device changed (and of a conflict); a secret-looking file stops it. Dry-run unless --go
    \\  version  print the app version
    \\  help     print this text
    \\
    \\Flags:
    \\  --repo <folder>   the repo root (required)
    \\  --config <path>   00-config.json (default: <repo>/04-task-apps/deve-sync/00-config.json)
    \\  --home <path>     home folder for {home} (default: HOME / USERPROFILE)
    \\  --only <id>       work on one item of the config only
    \\  --big             allow more than sync.big_files changes on one side
    \\  --no-merge        never auto-merge: the newest edit wins every conflict
    \\  --go              allow writes; omit for a dry-run
    \\
    \\Never deletes: pull saves the old device file to backup_dir, push only adds or replaces inside the repo. Files that exist on one side only are left alone.
    \\Exit codes: 0 ok · 1 failed · 2 usage or config · 3 not in sync (check)
    \\
;

const Args = struct { cmd: []const u8, repo: ?[]const u8 = null, conf_path: ?[]const u8 = null, home: ?[]const u8 = null, only: ?[]const u8 = null, go: bool = false, big: bool = false, no_merge: bool = false };

fn parseArgs(argv: []const []const u8) ?Args {
    if (argv.len == 0) return null;
    var r: Args = .{ .cmd = argv[0] };
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const k = argv[i];
        if (std.mem.eql(u8, k, "--go")) {
            r.go = true;
            continue;
        }
        if (std.mem.eql(u8, k, "--big")) {
            r.big = true;
            continue;
        }
        if (std.mem.eql(u8, k, "--no-merge")) {
            r.no_merge = true;
            continue;
        }
        if (i + 1 >= argv.len) return null;
        const v = argv[i + 1];
        i += 1;
        if (std.mem.eql(u8, k, "--repo")) r.repo = v else if (std.mem.eql(u8, k, "--config")) r.conf_path = v else if (std.mem.eql(u8, k, "--home")) r.home = v else if (std.mem.eql(u8, k, "--only")) r.only = v else return null;
    }
    return r;
}

fn die(n: u8) noreturn {
    std.process.exit(n);
}

fn label(s: pl.State) []const u8 {
    return switch (s) {
        .same => "same",
        .differs => "differs",
        .only_repo => "only repo",
        .only_dev => "only here",
    };
}

fn show(io: std.Io, plans: []const pl.Plan) void {
    for (plans) |p| {
        const id = p.item.id;
        if (p.unavailable.len > 0) {
            out.say(io, "{s:<22} n/a ({s})\n", .{ id, p.unavailable });
            continue;
        }
        if (p.entries.len == 0) {
            out.say(io, "{s:<22} none (nothing on either side)\n", .{id});
            continue;
        }
        const t = pl.tally(p);
        out.say(io, "{s:<22} {d} same · {d} differ · {d} only repo · {d} only here\n", .{ id, t.same, t.differs, t.only_repo, t.only_dev });
        var shown: usize = 0;
        for (p.entries) |e| {
            if (e.state == .same) continue;
            if (shown == CF.rows_max) {
                out.say(io, "    ... and {d} more\n", .{t.differs + t.only_repo + t.only_dev - CF.rows_max});
                break;
            }
            out.say(io, "    {s:<10} {s}\n", .{ label(e.state), e.rel });
            shown += 1;
        }
        if (p.skipped > 0) out.say(io, "    ({d} file(s) skipped: unsafe name or over file_maxz_kbyt)\n", .{p.skipped});
    }
}

fn fail(io: std.Io, e: anyerror) noreturn {
    switch (e) {
        error.BadPath => out.fail(io, "cannot resolve a path", pl.why, "check roots and backup_dir in 00-config.json; on Windows APPDATA must be set"),
        error.NoSuchItem => out.fail(io, "unknown item", pl.why, "run status to see the item ids"),
        error.BadDevJson => out.fail(io, "a settings file on this device is not valid JSON", pl.why, "fix that file by hand (it was not touched), then run again"),
        error.BadRepoJson => out.fail(io, "a shared settings file in the repo is not valid JSON", pl.why, "fix it in the repo, then run again"),
        error.TooBig => out.fail(io, "a file is over the size cap", pl.why, "raise file_maxz_kbyt in 00-config.json, or skip the file with the item's skip list"),
        error.TooManyChanges => out.fail(io, "too many changes at once", pl.why, "read the list with a dry-run; if it is right add --big"),
        error.SecretFound => out.fail(io, "push stopped by the secret guard", pl.why, "remove the secret from that file or add the file to the item's skip list, then run again"),
        error.UnsafePath => out.fail(io, "an unsafe path was found", pl.why, "rename or move that file; nothing was written for it"),
        error.LinkInTheWay => out.fail(io, "a link or folder sits where a file should go", pl.why, "move it away by hand, then run again"),
        error.WriteFail, error.ReadFail => out.fail(io, "cannot read or write a file", pl.why, "check the path, permissions and free disk space"),
        else => out.fail(io, @errorName(e), pl.why, "run again; report if it repeats"),
    }
    die(CF.exit_fail);
}

pub fn main(init: std.process.Init) void {
    const io = init.io;
    var arena = init.arena;
    const a = arena.allocator();
    const argv = std.process.Args.toSlice(init.minimal.args, a) catch die(CF.exit_use);
    const parsed = parseArgs(if (argv.len > 1) argv[1..] else &.{}) orelse {
        out.err(io, "{s}", .{USAGE});
        die(CF.exit_use);
    };
    if (std.mem.eql(u8, parsed.cmd, "help") or std.mem.eql(u8, parsed.cmd, "--help") or std.mem.eql(u8, parsed.cmd, "-h")) {
        out.say(io, "{s}", .{USAGE});
        die(CF.exit_ok);
    }
    if (std.mem.eql(u8, parsed.cmd, "version")) {
        out.say(io, "deve-sync {s}\n", .{build_options.version});
        die(CF.exit_ok);
    }
    const KNOWN = [_][]const u8{ "status", "check", "pull", "push", "sync" };
    var known = false;
    for (KNOWN) |k| if (std.mem.eql(u8, parsed.cmd, k)) {
        known = true;
    };
    if (!known) {
        out.err(io, "{s}", .{USAGE});
        die(CF.exit_use);
    }
    const repo = parsed.repo orelse {
        out.fail(io, "no repo folder given", "--repo is required", "pass --repo <repo root>; the app never guesses it");
        die(CF.exit_use);
    };
    const env = init.environ_map;
    const home = parsed.home orelse (os.homePath(env) orelse {
        out.fail(io, "no home folder set", "neither --home nor HOME/USERPROFILE is set", "pass --home <path>");
        die(CF.exit_use);
    });
    const conf_path = parsed.conf_path orelse (std.fs.path.join(a, &.{ repo, CF.conf_rel }) catch die(CF.exit_fail));
    const cf = conf.confLoad(io, a, conf_path) catch {
        out.fail(io, "config problem", conf.why, "fix 00-config.json and run again");
        die(CF.exit_use);
    };
    const base_dir = conf.fill(a, cf.sync.base_dir, .{ .home = home, .appdata = os.appdataPath(env), .repo = repo }) catch {
        out.fail(io, "cannot resolve sync.base_dir", cf.sync.base_dir, "check sync.base_dir in 00-config.json; on Windows APPDATA must be set");
        die(CF.exit_use);
    };
    var base = cb.load(io, a, base_dir) catch {
        out.fail(io, "the base store is damaged", base_dir, "move that folder away by hand: the next run treats every difference as a conflict until a pull or push sets it again");
        die(CF.exit_fail);
    };
    const ctx: pl.Ctx = .{
        .base = &base,
        .io = io,
        .a = a,
        .env = env,
        .cf = cf,
        .os_tag = os.cur(),
        .repo = repo,
        .home = home,
        .appdata = os.appdataPath(env),
        .claude_dir = os.envGet(env, cf.claude_envz),
        .now_secs = @divFloor(std.Io.Clock.real.now(io).toMilliseconds(), 1000),
    };
    const plans = pl.planAll(&ctx, parsed.only) catch |e| fail(io, e);
    const is = struct {
        fn cmd(p: Args, n: []const u8) bool {
            return std.mem.eql(u8, p.cmd, n);
        }
    };

    if (is.cmd(parsed, "status")) {
        show(io, plans);
        die(CF.exit_ok);
    }
    if (is.cmd(parsed, "check")) {
        show(io, plans);
        const same = pl.allSame(plans);
        out.say(io, "deve_state {s}\ndeve_sha256 {s}\n", .{ if (same) "same" else "differs", pl.devSha(plans) });
        die(if (same) CF.exit_ok else CF.exit_diff);
    }
    const mode: tri.Mode = if (is.cmd(parsed, "pull")) .pull else if (is.cmd(parsed, "push")) .push else .sync;
    const r = ap.run(&ctx, plans, mode, parsed.go, parsed.big, parsed.no_merge) catch |e| fail(io, e);
    const c = r.counts;
    out.say(io, "{s}", .{r.report});
    out.say(io, "{s}: {d} same · {d} to this device · {d} to the repo · {d} merged · {d} settled by newest edit · {d} skipped (repo newer) · {d} skipped (device newer)\n", .{ parsed.cmd, c.same, c.near, c.far, c.merged, c.newest, c.behind, c.ahead });
    if (!parsed.go) out.say(io, "dry-run: nothing written. Pass --go to apply.\n", .{}) else {
        if (c.installed > 0) out.say(io, "installed {d} extension(s)\n", .{c.installed});
        if (c.moved > 0) out.say(io, "{d} renamed file(s) followed; the old copies were moved to the trash folder or backup_dir, nothing was deleted\n", .{c.moved});
        if (c.raced > 0) out.say(io, "{d} file(s) were saved on this device while the sync ran and were left alone; the next run looks at them again.\n", .{c.raced});
        if (c.failed > 0) {
            out.fail(io, "some extensions did not install", "the editor command failed for them", "run the install by hand, or check the extension ids in vscode/extensions.txt");
            die(CF.exit_fail);
        }
        if (c.near > 0) out.say(io, "restart Claude Code and VS Code to load the new settings; old copies are in backup_dir\n", .{});
    }
    if (parsed.go and c.newest > 0) out.say(io, "{d} conflict(s) settled by the newest edit; the losing copies are in {s}/ in the repo.\n", .{ c.newest, ctx.cf.sync.trash_dir });
    die(CF.exit_ok);
}

test {
    _ = @import("co-os.zig");
    _ = @import("co-glob.zig");
    _ = @import("co-config.zig");
    _ = @import("co-fsio.zig");
    _ = @import("co-out.zig");
    _ = @import("cm-json.zig");
    _ = @import("cm-scan.zig");
    _ = @import("cm-exts.zig");
    _ = @import("cm-move.zig");
    _ = @import("cm-plan.zig");
    _ = @import("cm-apply.zig");
    _ = @import("cm-tri.zig");
    _ = @import("cm-base.zig");
    _ = @import("cm-merge.zig");
}
// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
