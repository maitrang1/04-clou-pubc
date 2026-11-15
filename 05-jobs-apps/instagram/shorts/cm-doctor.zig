// doctor: is everything ready? config, folder, secrets (names only), token, account, Meta allowance, disk, probe tool, ledger. Writes nothing.
const std = @import("std");
const Ctx = @import("co-ctx.zig").Ctx;
const exit = @import("co-exit.zig");
const out = @import("co-out.zig");
const os = @import("co-os.zig");
const util = @import("co-util.zig");
const kill = @import("co-kill.zig");
const quota_api = @import("ap-quota.zig");
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
        .{ .n = cx.cfg.graph.token_env, .v = cx.token() },
        .{ .n = cx.cfg.account.ig_user_id_env, .v = cx.igId() },
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
    // remote (read-only): the token answers for the account, and Meta's publishing allowance is readable
    if (cx.token() != null and cx.igId() != null and cx.cfg.graph.base.len > 0) {
        const tc = tokc.check(cx, a);
        const ok = tc.code == exit.OK;
        add(&lines, a, cx, "token", ok, if (ok) (std.fmt.allocPrint(a, "works for account {s} (no expiry date is available)", .{if (tc.username.len > 0) tc.username else "(no name)"}) catch "works") else tc.msg);
        if (!ok) {
            if (tc.code == exit.USAGE) local_bad = true else remote_bad = true;
        } else switch (quota_api.get(cx, a, cx.token().?, cx.igId().?)) {
            .ok => |q| add(&lines, a, cx, "publishing allowance", q.usage < q.total, std.fmt.allocPrint(a, "{d} used of {d} in the last 24 h (our cap {d})", .{ q.usage, q.total, cx.cfg.limits.meta_cap }) catch ""),
            .fail => |f| {
                add(&lines, a, cx, "publishing allowance", false, f.info.msg);
                remote_bad = true;
            },
        }
    }
    out.json(cx, a, .{ .checks = lines.items });
    if (local_bad) return exit.USAGE;
    return if (remote_bad) exit.BLOCKED else exit.OK;
}
