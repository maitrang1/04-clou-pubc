// =====================================================================
// Des: The doctor command - checks everything a run needs without uploading: config, source folder, secret names present (never values), data folder and ledger, disk space, sign-in, channel, and the category id
// Flo: local checks > token refresh > channel list > category list > one ok/FAIL line each > exit 3 if any FAIL
// Cre: 2026-11-15                          - | Mod: 2026-11-15
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: doctor
// Out: check lines; exit 0 all good · 3 something to fix
// Run: /home/mai_trang/04-clou-base/04-task-apps/vimeo/shorts/zig-out/bin/shorts doctor
// =====================================================================
const std = @import("std");
const ctx_mod = @import("co-ctx.zig");
const util = @import("co-util.zig");
const exit = @import("co-exit.zig");
const disk = @import("co-disk.zig");
const send = @import("rw-send.zig");
const pair = @import("rw-pair.zig");
const auth = @import("ap-auth.zig");
const call = @import("ap-call.zig");
const list = @import("ap-list.zig");
const cats = @import("ap-cats.zig");

const Rep = struct {
    cx: *const ctx_mod.Ctx,
    bad: u32 = 0,
    fn ok(self: *Rep, what: []const u8, detail: []const u8) void {
        util.print(self.cx.io, "ok    {s}{s}{s}\n", .{ what, if (detail.len > 0) ": " else "", detail });
    }
    fn fail(self: *Rep, what: []const u8, why: []const u8, fix: []const u8) void {
        self.bad += 1;
        util.print(self.cx.io, "FAIL  {s}: {s}\n      fix: {s}\n", .{ what, why, fix });
    }
    fn skip(self: *Rep, what: []const u8, why: []const u8) void {
        util.print(self.cx.io, "skip  {s}: {s}\n", .{ what, why });
    }
};

pub fn run(cx: *const ctx_mod.Ctx, _: []const []const u8) u8 {
    var arena = std.heap.ArenaAllocator.init(cx.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var r = Rep{ .cx = cx };
    r.ok("config", "parsed and range-checked");
    // source folder
    if (cx.cfg.source.dir.len == 0) {
        r.fail("source folder", "source.dir is empty", "set source.dir in the config to the producer's output folder");
    } else if (pair.scan(cx, a)) |items| {
        var ready: usize = 0;
        for (items) |i| if (i.status == .ready) {
            ready += 1;
        };
        r.ok("source folder", std.fmt.allocPrint(a, "{d} videos, {d} pass the checks", .{ items.len, ready }) catch "");
    } else |_| r.fail("source folder", "cannot be read", "check source.dir");
    // secrets: names only
    const g = cx.cfg.google;
    if (auth.secret(cx, a, g.client_id_env, g.client_id_file) != null) r.ok("client id", "present") else r.fail("client id", "missing", std.fmt.allocPrint(a, "set env {s} or put the file {s} in the secrets folder", .{ g.client_id_env, g.client_id_file }) catch "see HOW-TO");
    if (auth.secret(cx, a, g.client_secret_env, g.client_secret_file) != null) r.ok("client secret", "present") else r.skip("client secret", "not set (Desktop clients usually need one: see 10-HOW-TO)");
    const have_rt = auth.readRefresh(cx, a) != null;
    if (have_rt) r.ok("refresh token file", "present") else r.fail("refresh token file", "missing", "run: shorts login --live");
    // data folder + ledger
    var led: ?send.Ledger = null;
    if (send.Ledger.open(cx, a)) |l| {
        led = l;
        r.ok("ledger", std.fmt.allocPrint(a, "{s}/{s} opens", .{ cx.data_dir, cx.cfg.db_file }) catch "");
    } else |_| r.fail("ledger", "cannot be opened", "check the data folder path and permissions");
    defer if (led) |l| l.close();
    if (disk.freeMb(cx.data_dir)) |mb| {
        if (mb >= cx.cfg.limits.disk_min_mb) r.ok("disk space", std.fmt.allocPrint(a, "{d} MB free", .{mb}) catch "") else r.fail("disk space", std.fmt.allocPrint(a, "{d} MB free, limits.disk_min_mb is {d}", .{ mb, cx.cfg.limits.disk_min_mb }) catch "low", "free some space");
    } else r.skip("disk space", "this OS cannot tell");
    // network checks need a token
    if (!have_rt or auth.secret(cx, a, g.client_id_env, g.client_id_file) == null) {
        r.skip("sign-in, channel, category", "need the client id and a refresh token first");
    } else if (call.Tok.init(cx, a)) |tk| {
        var tok = tk;
        r.ok("sign-in", "a fresh access token was issued");
        if (led) |l| l.kvSetInt("token_ok", cx.nowMs()) catch {};
        switch (list.channel(&tok)) {
            .ok => r.ok("channel", "found (id not printed)"),
            .none => r.fail("channel", "this Google account has no Vimeo channel", "create a channel in Vimeo first"),
            .api => |v| r.fail("channel", v.why, "run: shorts login --live --force if the scope is wrong"),
            .net, .bad_reply => r.fail("channel", "no usable answer", "check the network and try again"),
        }
        switch (cats.check(&tok, cx.cfg.post.category_id)) {
            .ok => |t| r.ok("category", std.fmt.allocPrint(a, "{s} = {s}, assignable", .{ cx.cfg.post.category_id, t }) catch ""),
            .missing => r.fail("category", std.fmt.allocPrint(a, "id {s} does not exist for region {s}", .{ cx.cfg.post.category_id, g.region_code }) catch "missing", "change post.category_id"),
            .not_assignable => r.fail("category", "this category cannot be assigned to videos", "change post.category_id"),
            .api => |v| r.fail("category", v.why, "check the sign-in"),
            .net, .bad_reply => r.fail("category", "no usable answer", "check the network"),
        }
    } else |e| switch (e) {
        error.InvalidGrant => r.fail("sign-in", "refresh token is dead (invalid_grant)", "set the consent screen to In production, then: shorts login --live --force"),
        else => r.fail("sign-in", @errorName(e), "check the network and the secrets"),
    }
    if (r.bad == 0) {
        util.print(cx.io, "---\nall good\n", .{});
        return exit.ok;
    }
    util.print(cx.io, "---\n{d} thing(s) to fix\n", .{r.bad});
    return exit.blocked;
}
// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
