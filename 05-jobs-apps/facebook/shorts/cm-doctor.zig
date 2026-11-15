// doctor: is everything ready? config, folder, secrets (names only), token, Page, disk, probe tool, ledger. Writes nothing.
const std = @import("std");
const Ctx = @import("co-ctx.zig").Ctx;
const exit = @import("co-exit.zig");
const out = @import("co-out.zig");
const os = @import("co-os.zig");
const util = @import("co-util.zig");
const kill = @import("co-kill.zig");
const auth = @import("ap-auth.zig");
const tokc = @import("cm-token.zig");
const pair = @import("rw-pair.zig");
const send = @import("rw-send.zig");
const open = @import("co-open.zig");

const Line = struct { check: []const u8, ok: bool, detail: []const u8 };

pub fn run(cx: *Ctx, av: []const []const u8) u8 {
    _ = av;
    var arena = std.heap.ArenaAllocator.init(cx.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var lines: std.ArrayList(Line) = .empty;
    var local_bad = false;
    var remote_bad = false;
    const add = struct {
        fn f(l: *std.ArrayList(Line), al: std.mem.Allocator, c: *const Ctx, check: []const u8, ok: bool, detail: []const u8) void {
            l.append(al, .{ .check = check, .ok = ok, .detail = detail }) catch {};
            out.say(c, "{s} {s}: {s}", .{ if (ok) "ok  " else "FAIL", check, detail });
        }
    }.f;
    add(&lines, a, cx, "config", true, "00-config.json is valid");
    // source folder
    if (pair.scan(cx, a, null)) |es| {
        add(&lines, a, cx, "source", true, std.fmt.allocPrint(a, "{d} pair(s) found", .{es.len}) catch "readable");
    } else |_| {
        add(&lines, a, cx, "source", false, "source.dir is not set or cannot be opened");
        local_bad = true;
    }
    // secrets: names only, never values
    const need = [_]struct { n: []const u8, v: ?[]const u8 }{
        .{ .n = cx.cfg.graph.page_token_env, .v = cx.pageToken() },
        .{ .n = cx.cfg.account.page_id_env, .v = cx.pageId() },
        .{ .n = cx.cfg.graph.app_id_env, .v = cx.secret(cx.cfg.graph.app_id_env, cx.cfg.graph.app_id_file) },
        .{ .n = cx.cfg.graph.app_secret_env, .v = cx.secret(cx.cfg.graph.app_secret_env, cx.cfg.graph.app_secret_file) },
    };
    for (need) |s| {
        add(&lines, a, cx, std.fmt.allocPrint(a, "secret {s}", .{s.n}) catch "secret", s.v != null, if (s.v != null) "present" else "missing (env var or file in secrets_dir)");
        if (s.v == null) local_bad = true;
    }
    // disk
    const dd = cx.dataPath(a, "") catch "";
    const dpath = std.mem.trimEnd(u8, dd, "/");
    const probe_at: []const u8 = if (util.exists(cx.io, dpath)) dpath else cx.home; // the folder may not exist before the first send
    if (os.diskFreeMb(a, probe_at)) |mb| {
        const ok = mb >= cx.cfg.limits.disk_min_mb;
        add(&lines, a, cx, "disk", ok, std.fmt.allocPrint(a, "{d} MB free (min {d})", .{ mb, cx.cfg.limits.disk_min_mb }) catch "");
        if (!ok) local_bad = true;
    } else add(&lines, a, cx, "disk", true, "free space unknown on this system");
    // probe tool
    if (cx.cfg.video.probe_tool.len > 0) {
        const r = std.process.run(a, cx.io, .{ .argv = &.{ cx.cfg.video.probe_tool, "-version" }, .stdout_limit = .limited(65536) }) catch null;
        const ok = r != null and r.?.term == .exited and r.?.term.exited == 0;
        add(&lines, a, cx, "probe tool", ok, if (ok) "runs" else "cannot run the tool named in video.probe_tool");
        if (!ok) local_bad = true;
    } else add(&lines, a, cx, "probe tool", true, "none set: the built-in mp4 reader is used");
    // ledger + kill
    var db = open.existing(cx);
    defer if (db) |*d| d.close();
    if (db != null) {
        add(&lines, a, cx, "ledger", true, "opens fine");
    } else add(&lines, a, cx, "ledger", true, "none yet (created on the first send)");
    add(&lines, a, cx, "kill file", !kill.killOn(cx), if (kill.killOn(cx)) "ON: nothing will be written or sent" else "off");
    if (db) |*d| {
        const exp = send.metaInt(d, "tok_exp") catch 0;
        if (exp > 0) {
            const days = @divTrunc(std.math.mul(i64, exp, 1000) catch std.math.maxInt(i64) - cx.nowMs(), 24 * 3600 * 1000);
            add(&lines, a, cx, "token expiry", days >= cx.cfg.token_warn_days, std.fmt.allocPrint(a, "{d} days left (warn under {d})", .{ days, cx.cfg.token_warn_days }) catch "");
        }
    }
    // remote: token + Page (read-only)
    if (cx.pageToken() != null and cx.cfg.graph.base.len > 0) {
        const tc = tokc.check(cx, a);
        if (tc.code == exit.USAGE) add(&lines, a, cx, "token", false, tc.msg) else {
            const ok = tc.code == exit.OK;
            add(&lines, a, cx, "token", ok, if (ok) (if (tc.never) "valid, never expires" else "valid, has an expiry date") else if (tc.msg.len > 0) tc.msg else "missing permissions");
            if (!ok) remote_bad = true;
        }
        if (cx.pageId()) |pid| switch (auth.pageName(cx, a, cx.pageToken().?, pid)) {
            .ok => |n| add(&lines, a, cx, "page", true, std.fmt.allocPrint(a, "reachable ({s})", .{if (n.len > 0) "name read" else "no name"}) catch "reachable"),
            .fail => |f| {
                add(&lines, a, cx, "page", false, f.info.msg);
                remote_bad = true;
            },
        };
    }
    out.json(cx, a, .{ .checks = lines.items });
    if (local_bad) return exit.USAGE;
    return if (remote_bad) exit.BLOCKED else exit.OK;
}
