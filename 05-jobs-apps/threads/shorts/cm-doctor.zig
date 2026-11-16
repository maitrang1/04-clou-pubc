// doctor: is everything ready? config, publisher flag, folders, public host, secrets (names only), token, quota, disk, probe tool, ledger. Writes only a tiny probe file into host.dir, and only with --live.
const std = @import("std");
const Io = std.Io;
const Ctx = @import("co-ctx.zig").Ctx;
const exit = @import("co-exit.zig");
const out = @import("co-out.zig");
const os = @import("co-os.zig");
const util = @import("co-util.zig");
const kill = @import("co-kill.zig");
const tokc = @import("cm-token.zig");
const pair = @import("rw-pair.zig");
const host = @import("rw-host.zig");
const quota_api = @import("ap-quota.zig");
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
    add(&lines, a, cx, "publisher device", true, if (cx.cfg.device.publisher) "yes: publish --live is allowed here" else "no: publish --live is refused here (set device.publisher on the ONE device that posts)");
    if (pair.scan(cx, a, null)) |es| {
        add(&lines, a, cx, "source", true, std.fmt.allocPrint(a, "{d} pair(s) found", .{es.len}) catch "readable");
    } else |_| {
        add(&lines, a, cx, "source", false, "source.dir is not set or cannot be opened");
        local_bad = true;
    }
    // public host
    if (!host.configured(cx)) {
        add(&lines, a, cx, "host", false, "host.dir, host.done_dir and host.base_url must all be set");
        local_bad = true;
    } else {
        const hd = cx.path(a, cx.cfg.host.dir) catch "";
        add(&lines, a, cx, "host folder", util.exists(cx.io, hd), if (util.exists(cx.io, hd)) "exists" else "host.dir does not exist (create it, and serve it over https)");
        if (!util.exists(cx.io, hd)) local_bad = true;
        if (cx.live and util.exists(cx.io, hd)) {
            // a 16-byte probe file: copy, fetch it from the public url, move it to done_dir
            const probe = std.fmt.allocPrint(a, "{s}/doctor-probe.bin", .{std.mem.trimEnd(u8, cx.path(a, cx.cfg.data_dir) catch ".", "/")}) catch "";
            util.mkdirp(cx.io, std.fs.path.dirname(probe) orelse ".") catch {};
            util.writeAtomic(a, cx.io, probe, "doctor-probe-123") catch {};
            if (host.stage(cx, a, probe)) |s| {
                const chk = host.selfCheck(cx, a, s.url, 16);
                add(&lines, a, cx, "public url", chk.ok, chk.note);
                if (!chk.ok) remote_bad = true;
                host.finish(cx, a, s.file) catch {};
            } else |e| {
                add(&lines, a, cx, "public url", false, std.fmt.allocPrint(a, "cannot write into host.dir: {s}", .{@errorName(e)}) catch "cannot write into host.dir");
                local_bad = true;
            }
        } else add(&lines, a, cx, "public url", true, "not tested (add --live: writes one 16-byte probe file)");
    }
    // secrets: names only, never values
    const need = [_]struct { n: []const u8, v: ?[]const u8, must: bool }{
        .{ .n = cx.cfg.account.token_env, .v = cx.token(), .must = true },
        .{ .n = cx.cfg.account.user_id_env, .v = cx.userId(), .must = false },
        .{ .n = cx.cfg.account.app_id_env, .v = cx.secret(cx.cfg.account.app_id_env, cx.cfg.account.app_id_file), .must = false },
        .{ .n = cx.cfg.account.app_secret_env, .v = cx.secret(cx.cfg.account.app_secret_env, cx.cfg.account.app_secret_file), .must = false },
    };
    for (need) |s| {
        const ok = s.v != null or !s.must;
        add(&lines, a, cx, std.fmt.allocPrint(a, "secret {s}", .{s.n}) catch "secret", ok, if (s.v != null) "present" else if (s.must) "missing (env var or file in secrets_dir)" else "not set (optional)");
        if (!ok) local_bad = true;
    }
    const dd = cx.dataPath(a, "") catch "";
    const dpath = std.mem.trimEnd(u8, dd, "/");
    const probe_at: []const u8 = if (util.exists(cx.io, dpath)) dpath else cx.home;
    if (os.diskFreeMb(a, probe_at)) |mb| {
        const ok = mb >= cx.cfg.limits.disk_min_mb;
        add(&lines, a, cx, "disk", ok, std.fmt.allocPrint(a, "{d} MB free (min {d})", .{ mb, cx.cfg.limits.disk_min_mb }) catch "");
        if (!ok) local_bad = true;
    } else add(&lines, a, cx, "disk", true, "free space unknown on this system");
    if (cx.cfg.video.probe_tool.len > 0) {
        const r = std.process.run(a, cx.io, .{ .argv = &.{ cx.cfg.video.probe_tool, "-version" }, .stdout_limit = .limited(65536) }) catch null;
        const ok = r != null and r.?.term == .exited and r.?.term.exited == 0;
        add(&lines, a, cx, "probe tool", ok, if (ok) "runs" else "cannot run the tool named in video.probe_tool");
        if (!ok) local_bad = true;
    } else add(&lines, a, cx, "probe tool", true, "none set: the built-in mp4 reader is used");
    var db = open.existing(cx);
    defer if (db) |*d| d.close();
    add(&lines, a, cx, "ledger", true, if (db != null) "opens fine" else "none yet (created on the first send)");
    add(&lines, a, cx, "kill file", !kill.killOn(cx), if (kill.killOn(cx)) "ON: nothing will be written or sent" else "off");
    if (tokc.daysLeft(cx)) |d| add(&lines, a, cx, "token age", d >= cx.cfg.token_warn_days, std.fmt.allocPrint(a, "{d} days left (warn under {d}; the app refreshes under {d})", .{ d, cx.cfg.token_warn_days, cx.cfg.token_refresh_days }) catch "");
    // remote, read-only
    if (cx.token() != null) {
        const tc = tokc.check(cx, a);
        if (tc.code == exit.USAGE) add(&lines, a, cx, "token", false, tc.msg) else {
            const ok = tc.code == exit.OK;
            add(&lines, a, cx, "token", ok, if (ok) std.fmt.allocPrint(a, "valid · account {s}{s}", .{ tc.username, if (tc.scopes_checked) " · scopes ok" else " · scopes unchecked (no app id/secret)" }) catch "valid" else if (tc.msg.len > 0) tc.msg else "missing permissions");
            if (!ok) remote_bad = true;
            if (ok) {
                const uid = cx.userId() orelse tc.id;
                switch (quota_api.get(cx, a, cx.token().?, uid)) {
                    .ok => |q| add(&lines, a, cx, "quota", true, std.fmt.allocPrint(a, "{d} of {d} used in the last 24 h", .{ q.usage, q.total }) catch ""),
                    .fail => |f| {
                        add(&lines, a, cx, "quota", false, f.info.msg);
                        remote_bad = true;
                    },
                }
            }
        }
    }
    out.json(cx, a, .{ .checks = lines.items });
    if (local_bad) return exit.USAGE;
    return if (remote_bad) exit.BLOCKED else exit.OK;
}
