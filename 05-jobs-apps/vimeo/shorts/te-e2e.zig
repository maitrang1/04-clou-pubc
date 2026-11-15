// =====================================================================
// Des: End-to-end tests - every command runs for real against the loopback fake Google (OAuth + Vimeo) with a temp folder, fake secrets and real files; proves once-only sending, lost-answer recovery, resume, limits, holds, kill file and the AI/kids/private fields
// Flo: build a rig (fake server + temp dirs + secrets + pairs) > run commands through their real entry points > check exit codes, ledger rows, fake counters and the bytes the fake received
// Cre: 2026-11-15                          - | Mod: 2026-11-15
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: none (tests only)
// Out: pass or fail
// Run: cd /home/mai_trang/04-clou-base/05-jobs-apps/vimeo/shorts && zig build test --summary all
// =====================================================================
const std = @import("std");
const ctx_mod = @import("co-ctx.zig");
const util = @import("co-util.zig");
const exit = @import("co-exit.zig");
const kill = @import("co-kill.zig");
const lock = @import("co-lock.zig");
const send = @import("rw-send.zig");
const caps = @import("rw-caps.zig");
const probe = @import("rw-probe.zig");
const ms = @import("te-mini-srv.zig");
const yt = @import("te-fake-yt.zig");
const publish = @import("cm-publish.zig");
const approve = @import("cm-approve.zig");
const resolve = @import("cm-resolve.zig");
const scan = @import("cm-scan.zig");
const status = @import("cm-status.zig");
const doctor = @import("cm-doctor.zig");
const login = @import("cm-login.zig");
const token = @import("cm-token.zig");
const admin = @import("cm-admin.zig");
const auth = @import("ap-auth.zig");
const call = @import("ap-call.zig");
const session = @import("ap-session.zig");
const upload = @import("ap-upload.zig");
const engine = @import("cm-send.zig");

const Rig = struct {
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,
    env: std.process.Environ.Map,
    fake: yt.Fake,
    srv: *ms.Srv,
    cx: ctx_mod.Ctx,
    dir: []const u8,
    src: []const u8,

    fn create(gpa: std.mem.Allocator) !*Rig {
        const r = try gpa.create(Rig);
        r.gpa = gpa;
        r.arena = std.heap.ArenaAllocator.init(gpa);
        const a = r.arena.allocator();
        r.tmp = std.testing.tmpDir(.{});
        r.dir = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{&r.tmp.sub_path});
        r.src = try std.fmt.allocPrint(a, "{s}/src", .{r.dir});
        r.env = std.process.Environ.Map.init(a);
        r.fake = .{};
        r.srv = try yt.serve(std.testing.io, &r.fake);
        r.cx = ctx_mod.testCtx(a, &r.env, r.dir);
        const secr = try std.fmt.allocPrint(a, "{s}/secr", .{r.dir});
        try util.mkdirp(std.testing.io, r.src);
        try util.mkdirp(std.testing.io, secr);
        try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/yout-client-id.txt", .{secr}), .data = "CID\n" });
        try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/yout-refresh-token.txt", .{secr}), .data = "RT-GOOD\n" });
        const c = &r.cx;
        c.cfg_dir = ".";
        c.data_dir = try std.fmt.allocPrint(a, "{s}/data", .{r.dir});
        c.secrets_dir = secr;
        c.cfg.source.dir = r.src;
        c.cfg.google.token_url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/token", .{r.srv.port});
        c.cfg.google.api_base = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/vimeo/v3", .{r.srv.port});
        c.cfg.google.upload_base = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/upload/vimeo/v3", .{r.srv.port});
        c.cfg.limits.gap_min_s = 0;
        c.cfg.limits.gap_max_s = 0;
        c.cfg.net.status_poll_s = 1;
        c.cfg.net.status_poll_max_s = 3;
        c.cfg.net.timeout_s = 10;
        c.cfg.net.upload_timeout_s = 60;
        c.cfg.net.chunk_kb = 64;
        return r;
    }

    fn destroy(r: *Rig) void {
        r.srv.stop();
        r.tmp.cleanup();
        const g = r.gpa;
        r.arena.deinit();
        g.destroy(r);
    }

    fn al_(r: *Rig) std.mem.Allocator {
        return r.arena.allocator();
    }

    const Opt = struct { review: bool = false, secs: u32 = 15, w: u32 = 1080, h: u32 = 1920, pad: usize = 4000, made: []const u8 = "2026-11-01T10:00:00Z", title: []const u8 = "Xe dep gia tot" };

    // a pair in the source folder; returns the mp4 bytes
    fn addPair(r: *Rig, name: []const u8, car: []const u8, o: Opt) ![]u8 {
        const al = r.al_();
        const mp4 = try probe.testMp4Pad(al, o.w, o.h, o.secs, true, o.pad);
        try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = try std.fmt.allocPrint(al, "{s}/{s}.mp4", .{ r.src, name }), .data = mp4 });
        const js = try std.fmt.allocPrint(al, "{{\"car\":\"{s}\",\"code\":\"C\",\"template\":\"t1\",\"mp4\":\"{s}.mp4\",\"hooks\":[\"{s}\"],\"description\":\"Mo ta xe\",\"hashtags\":[\"xe\",\"oto\"],\"ai_notice\":\"Video tao bang AI.\",\"review\":{},\"made_at\":\"{s}\",\"listing_url\":\"\"}}", .{ car, name, o.title, o.review, o.made });
        try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = try std.fmt.allocPrint(al, "{s}/{s}.json", .{ r.src, name }), .data = js });
        return mp4;
    }

    fn led(r: *Rig) !send.Ledger {
        return send.Ledger.open(&r.cx, r.al_());
    }

    fn row(r: *Rig, pkey: []const u8) !?send.Row {
        const l = try r.led();
        defer l.close();
        return l.find(r.al_(), pkey);
    }

    fn pub_(r: *Rig, extra: []const []const u8) u8 {
        return publish.run(&r.cx, extra, false);
    }
};

const live = [_][]const u8{"--live"};

fn sha(b: []const u8) [32]u8 {
    var h: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(b, &h, .{});
    return h;
}

test "dry run sends nothing: no token call, no session, no ledger row" {
    const r = try Rig.create(std.testing.allocator);
    defer r.destroy();
    _ = try r.addPair("a", "car1", .{});
    try std.testing.expectEqual(exit.ok, r.pub_(&.{}));
    try std.testing.expectEqual(@as(u32, 0), r.fake.counts.token);
    try std.testing.expectEqual(@as(u32, 0), r.fake.counts.start);
    try std.testing.expect((try r.row("car1:t1:vime-short")) == null);
}

test "happy path: one upload, private + AI label + kids set + no notify, bytes identical, token never in a URL" {
    const r = try Rig.create(std.testing.allocator);
    defer r.destroy();
    const mp4 = try r.addPair("a", "car1", .{});
    try std.testing.expectEqual(exit.ok, r.pub_(&live));
    const row = (try r.row("car1:t1:vime-short")).?;
    try std.testing.expect(row.state == .posted);
    try std.testing.expectEqualStrings("vid1", row.video_uri);
    try std.testing.expect(std.mem.endsWith(u8, row.url, "vid1"));
    try std.testing.expectEqual(@as(u32, 1), r.fake.counts.start);
    try std.testing.expectEqual(@as(u32, 1), r.fake.counts.put);
    const s0 = r.fake.sessions[0];
    try std.testing.expect(s0.completed and s0.stored == mp4.len and s0.seg_n == 1);
    try std.testing.expectEqualSlices(u8, &sha(mp4), &s0.segs[0].sha);
    const meta = r.fake.metaStr();
    try std.testing.expect(std.mem.indexOf(u8, meta, "\"privacyStatus\":\"private\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, meta, "\"containsSyntheticMedia\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, meta, "\"selfDeclaredMadeForKids\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, meta, "Video tao bang AI.") != null);
    try std.testing.expect(std.mem.indexOf(u8, meta, "\"categoryId\":\"2\"") != null);
    const path = r.fake.last_start_path[0..r.fake.last_start_path_len];
    try std.testing.expect(std.mem.indexOf(u8, path, "notifySubscribers=false") != null);
    try std.testing.expect(std.mem.indexOf(u8, path, "uploadType=resumable") != null);
    try std.testing.expect(!r.fake.saw_token_in_url);
    const head = r.fake.last_start_head[0..r.fake.last_start_head_len];
    try std.testing.expect(std.mem.indexOf(u8, head, "X-Upload-Content-Length: ") != null);
    try std.testing.expect(std.mem.indexOf(u8, head, "video/mp4") != null);
    // the processing poll ran and the log never holds a token
    try std.testing.expect(r.fake.counts.status >= 1);
    const lg = try util.readAll(r.al_(), std.testing.io, try r.cx.dataPath(r.al_(), "log/run.log"), 1 << 16);
    try std.testing.expect(std.mem.indexOf(u8, lg, "AT-") == null and std.mem.indexOf(u8, lg, "RT-GOOD") == null);
}

test "replay: the same video again is a no-op (named or picked), nothing new reaches Google" {
    const r = try Rig.create(std.testing.allocator);
    defer r.destroy();
    _ = try r.addPair("a", "car1", .{});
    try std.testing.expectEqual(exit.ok, r.pub_(&live));
    try std.testing.expectEqual(exit.ok, r.pub_(&.{ "--live", "--video", "a" }));
    try std.testing.expectEqual(exit.nothing, r.pub_(&live)); // nothing left to send
    try std.testing.expectEqual(@as(u32, 1), r.fake.counts.start);
    try std.testing.expectEqual(@as(u32, 1), r.fake.counts.put);
}

test "a review video is held: never sent until a person approves" {
    const r = try Rig.create(std.testing.allocator);
    defer r.destroy();
    _ = try r.addPair("rev", "car9", .{ .review = true });
    try std.testing.expectEqual(exit.nothing, r.pub_(&live));
    try std.testing.expectEqual(exit.nothing, r.pub_(&.{ "--live", "--video", "rev" }));
    try std.testing.expectEqual(@as(u32, 0), r.fake.counts.start);
    // approve as a dry run changes nothing
    try std.testing.expectEqual(exit.ok, approve.run(&r.cx, &.{ "--video", "rev" }, true));
    try std.testing.expect((try r.row("car9:t1:vime-short")) == null);
    try std.testing.expectEqual(exit.nothing, r.pub_(&live));
    // approve for real
    try std.testing.expectEqual(exit.ok, approve.run(&r.cx, &.{ "--video", "rev", "--live" }, true));
    try std.testing.expect((try r.row("car9:t1:vime-short")).?.state == .ready);
    try std.testing.expectEqual(exit.nothing, approve.run(&r.cx, &.{ "--video", "rev", "--live" }, true)); // already approved
    try std.testing.expectEqual(exit.ok, r.pub_(&live));
    try std.testing.expect((try r.row("car9:t1:vime-short")).?.state == .posted);
    // hold and approve no longer apply to a posted video
    try std.testing.expectEqual(exit.blocked, approve.run(&r.cx, &.{ "--video", "rev", "--live" }, false));
}

test "hold parks a ready video until approved again" {
    const r = try Rig.create(std.testing.allocator);
    defer r.destroy();
    _ = try r.addPair("a", "car1", .{});
    try std.testing.expectEqual(exit.ok, approve.run(&r.cx, &.{ "--video", "a", "--live" }, false));
    try std.testing.expect((try r.row("car1:t1:vime-short")).?.state == .held);
    try std.testing.expectEqual(exit.nothing, r.pub_(&live));
    try std.testing.expectEqual(exit.ok, approve.run(&r.cx, &.{ "--video", "a", "--live" }, true));
    try std.testing.expectEqual(exit.ok, r.pub_(&live));
}

test "lost answer after the last byte: the session is asked, the video is NOT uploaded twice" {
    const r = try Rig.create(std.testing.allocator);
    defer r.destroy();
    _ = try r.addPair("a", "car1", .{});
    r.fake.put_mode = .drop_after_complete;
    try std.testing.expectEqual(exit.ok, r.pub_(&live));
    try std.testing.expect((try r.row("car1:t1:vime-short")).?.state == .posted);
    try std.testing.expectEqual(@as(u32, 1), r.fake.counts.start);
    try std.testing.expectEqual(@as(u32, 1), r.fake.counts.put);
    try std.testing.expect(r.fake.counts.ask >= 1);
}

test "lost answer and the session expired: unsure (exit 5), never retried; resolve finds it on the channel" {
    const r = try Rig.create(std.testing.allocator);
    defer r.destroy();
    _ = try r.addPair("a", "car1", .{});
    r.fake.put_mode = .expire_after_complete;
    try std.testing.expectEqual(exit.unsure, r.pub_(&live));
    const row = (try r.row("car1:t1:vime-short")).?;
    try std.testing.expect(row.state == .unsure);
    // another run does not re-send it (unsure is never picked)
    r.fake.put_mode = .ok;
    try std.testing.expectEqual(exit.nothing, r.pub_(&live));
    try std.testing.expectEqual(@as(u32, 1), r.fake.counts.start);
    // approve refuses without --resend, because a duplicate is possible
    try std.testing.expectEqual(exit.blocked, approve.run(&r.cx, &.{ "--video", "a", "--live" }, true));
    // resolve: dry run reports, does not write
    try std.testing.expectEqual(exit.ok, resolve.run(&r.cx, &.{ "--video", "a" }));
    try std.testing.expect((try r.row("car1:t1:vime-short")).?.state == .unsure);
    try std.testing.expectEqual(exit.ok, resolve.run(&r.cx, &.{ "--video", "a", "--live" }));
    const done = (try r.row("car1:t1:vime-short")).?;
    try std.testing.expect(done.state == .posted);
    try std.testing.expectEqualStrings("vid1", done.video_uri);
    try std.testing.expectEqual(@as(u32, 1), r.fake.counts.start); // still one upload
}

test "resolve: not on the channel stays unsure (exit 5); the person may then re-send on purpose" {
    const r = try Rig.create(std.testing.allocator);
    defer r.destroy();
    _ = try r.addPair("a", "car1", .{});
    r.fake.put_mode = .expire_after_complete;
    r.fake.listing_on = false;
    try std.testing.expectEqual(exit.unsure, r.pub_(&live));
    try std.testing.expectEqual(exit.unsure, resolve.run(&r.cx, &.{ "--video", "a", "--live" }));
    try std.testing.expect((try r.row("car1:t1:vime-short")).?.state == .unsure);
    try std.testing.expectEqual(exit.ok, approve.run(&r.cx, &.{ "--video", "a", "--live", "--resend" }, true));
    try std.testing.expect((try r.row("car1:t1:vime-short")).?.state == .ready);
    r.fake.put_mode = .ok;
    r.fake.listing_on = true;
    try std.testing.expectEqual(exit.ok, r.pub_(&live));
    try std.testing.expectEqual(@as(u32, 2), r.fake.counts.start); // a second, deliberate upload
}

test "connection cut mid-body: resume from the byte the session names, both parts hash to the file" {
    const r = try Rig.create(std.testing.allocator);
    defer r.destroy();
    const mp4 = try r.addPair("a", "car1", .{ .pad = 6000 });
    r.srv.cut_after.store(100, .release);
    try std.testing.expectEqual(exit.ok, r.pub_(&live));
    try std.testing.expect((try r.row("car1:t1:vime-short")).?.state == .posted);
    const s0 = r.fake.sessions[0];
    try std.testing.expectEqual(@as(usize, 2), s0.seg_n);
    try std.testing.expectEqual(@as(u64, 100), s0.segs[0].len);
    try std.testing.expectEqualSlices(u8, &sha(mp4[0..100]), &s0.segs[0].sha);
    try std.testing.expectEqualSlices(u8, &sha(mp4[100..]), &s0.segs[1].sha);
    try std.testing.expectEqual(@as(u32, 1), r.fake.counts.start); // never a second session
}

test "5xx on the session start: retried before any byte; always-5xx leaves the video queued" {
    const r = try Rig.create(std.testing.allocator);
    defer r.destroy();
    _ = try r.addPair("a", "car1", .{});
    r.fake.start_mode = .srv_503_once;
    try std.testing.expectEqual(exit.ok, r.pub_(&live));
    try std.testing.expectEqual(@as(u32, 2), r.fake.counts.start);
    const r2 = try Rig.create(std.testing.allocator);
    defer r2.destroy();
    _ = try r2.addPair("b", "car2", .{});
    r2.fake.start_mode = .srv_503_always;
    try std.testing.expectEqual(exit.failed, r2.pub_(&live));
    try std.testing.expectEqual(@as(u32, 3), r2.fake.counts.start); // retry_pre_send 2 -> 3 tries
    try std.testing.expect((try r2.row("car2:t1:vime-short")).?.state == .ready);
    try std.testing.expectEqual(@as(u32, 0), r2.fake.counts.put);
}

test "quota: stop for the day, the video stays queued, the next run makes no call; channel limit is named apart" {
    const r = try Rig.create(std.testing.allocator);
    defer r.destroy();
    _ = try r.addPair("a", "car1", .{});
    r.fake.start_mode = .quota;
    try std.testing.expectEqual(exit.blocked, r.pub_(&live));
    try std.testing.expect((try r.row("car1:t1:vime-short")).?.state == .ready);
    r.fake.start_mode = .ok;
    try std.testing.expectEqual(exit.blocked, r.pub_(&live)); // stopped until Pacific midnight
    try std.testing.expectEqual(@as(u32, 1), r.fake.counts.start);
    // next Pacific day it goes
    r.cx.fake_now_ms = util.nowMs(std.testing.io) + 36 * 3600 * 1000;
    try std.testing.expectEqual(exit.ok, r.pub_(&live));
    const r2 = try Rig.create(std.testing.allocator);
    defer r2.destroy();
    _ = try r2.addPair("b", "car2", .{});
    r2.fake.start_mode = .channel_limit;
    try std.testing.expectEqual(exit.blocked, r2.pub_(&live));
    const l = try r2.led();
    defer l.close();
    const why = (try l.kvGet(r2.al_(), "stop_why")).?;
    try std.testing.expect(std.mem.indexOf(u8, why, "uploadLimitExceeded") != null);
}

test "forbidden opens the breaker until a person resets it; invalid title is a plain failure" {
    const r = try Rig.create(std.testing.allocator);
    defer r.destroy();
    _ = try r.addPair("a", "car1", .{});
    _ = try r.addPair("b", "car2", .{ .made = "2026-11-02T10:00:00Z" });
    r.fake.start_mode = .forbidden;
    try std.testing.expectEqual(exit.failed, r.pub_(&live));
    try std.testing.expect((try r.row("car1:t1:vime-short")).?.state == .failed);
    r.fake.start_mode = .ok;
    try std.testing.expectEqual(exit.blocked, r.pub_(&live)); // breaker open, no call
    try std.testing.expectEqual(@as(u32, 1), r.fake.counts.start);
    try std.testing.expectEqual(exit.ok, admin.config(&r.cx, &.{"--reset-breaker"}, false)); // dry run: still open
    try std.testing.expectEqual(exit.blocked, r.pub_(&live));
    try std.testing.expectEqual(exit.ok, admin.config(&r.cx, &.{ "--reset-breaker", "--live" }, false));
    try std.testing.expectEqual(exit.ok, r.pub_(&live)); // the failed one is terminal: b goes now
    try std.testing.expect((try r.row("car2:t1:vime-short")).?.state == .posted);
    const r2 = try Rig.create(std.testing.allocator);
    defer r2.destroy();
    _ = try r2.addPair("c", "car3", .{});
    r2.fake.start_mode = .invalid_title;
    try std.testing.expectEqual(exit.failed, r2.pub_(&live));
    const l = try r2.led();
    defer l.close();
    try std.testing.expectEqual(@as(i64, 1), try l.kvInt("breaker_fails"));
}

test "breaker opens after N plain failures and cools down" {
    const r = try Rig.create(std.testing.allocator);
    defer r.destroy();
    r.cx.cfg.breaker.fails = 2;
    _ = try r.addPair("a", "car1", .{ .made = "2026-11-01T10:00:00Z" });
    _ = try r.addPair("b", "car2", .{ .made = "2026-11-02T10:00:00Z" });
    _ = try r.addPair("c", "car3", .{ .made = "2026-11-03T10:00:00Z" });
    r.fake.start_mode = .invalid_title;
    try std.testing.expectEqual(exit.failed, r.pub_(&live));
    try std.testing.expectEqual(exit.failed, r.pub_(&live));
    try std.testing.expectEqual(exit.blocked, r.pub_(&live)); // 2 in a row: open
    try std.testing.expectEqual(@as(u32, 2), r.fake.counts.start);
    r.cx.fake_now_ms = util.nowMs(std.testing.io) + 7 * 3600 * 1000; // past cool_h 6
    r.fake.start_mode = .ok;
    try std.testing.expectEqual(exit.ok, r.pub_(&live));
}

test "daily cap and gap hold, counted from the ledger" {
    const r = try Rig.create(std.testing.allocator);
    defer r.destroy();
    r.cx.cfg.limits.daily_cap = 1;
    _ = try r.addPair("a", "car1", .{ .made = "2026-11-01T10:00:00Z" });
    _ = try r.addPair("b", "car2", .{ .made = "2026-11-02T10:00:00Z" });
    try std.testing.expectEqual(exit.ok, r.pub_(&live));
    try std.testing.expectEqual(exit.blocked, r.pub_(&live)); // cap 1 reached
    try std.testing.expectEqual(@as(u32, 1), r.fake.counts.start);
    r.cx.fake_now_ms = util.nowMs(std.testing.io) + 30 * 3600 * 1000;
    try std.testing.expectEqual(exit.ok, r.pub_(&live)); // a new Pacific day
    // gap: with a 1-hour minimum the next send waits (exit 4), nothing is called
    const g = try Rig.create(std.testing.allocator);
    defer g.destroy();
    g.cx.cfg.limits.gap_min_s = 3600;
    g.cx.cfg.limits.gap_max_s = 3600;
    _ = try g.addPair("a", "car1", .{ .made = "2026-11-01T10:00:00Z" });
    _ = try g.addPair("b", "car2", .{ .made = "2026-11-02T10:00:00Z" });
    try std.testing.expectEqual(exit.ok, g.pub_(&live));
    try std.testing.expectEqual(exit.nothing, g.pub_(&live));
    try std.testing.expectEqual(@as(u32, 1), g.fake.counts.start);
}

test "kill file and run lock stop a live run before any call" {
    const r = try Rig.create(std.testing.allocator);
    defer r.destroy();
    _ = try r.addPair("a", "car1", .{});
    try std.testing.expectEqual(exit.ok, admin.killCmd(&r.cx, &.{"on"}));
    try std.testing.expectEqual(exit.blocked, r.pub_(&live));
    try std.testing.expectEqual(exit.blocked, approve.run(&r.cx, &.{ "--video", "a", "--live" }, true));
    try std.testing.expectEqual(@as(u32, 0), r.fake.counts.token);
    try std.testing.expectEqual(exit.ok, admin.killCmd(&r.cx, &.{"off"}));
    const lk = try lock.take(&r.cx, r.al_());
    try std.testing.expectEqual(exit.blocked, r.pub_(&live)); // another run holds the lock
    lk.release();
    try std.testing.expectEqual(exit.ok, r.pub_(&live));
    try std.testing.expect(!kill.isOn(&r.cx, r.al_()));
}

test "dead refresh token: blocked, ledger untouched; a 401 mid-run refreshes once and goes on" {
    const r = try Rig.create(std.testing.allocator);
    defer r.destroy();
    _ = try r.addPair("a", "car1", .{});
    r.fake.invalid_grant = true;
    try std.testing.expectEqual(exit.blocked, r.pub_(&live));
    try std.testing.expect((try r.row("car1:t1:vime-short")) == null);
    try std.testing.expectEqual(@as(u32, 0), r.fake.counts.start);
    try std.testing.expectEqual(exit.blocked, token.run(&r.cx, &.{}));
    r.fake.invalid_grant = false;
    r.fake.reject_tokens_up_to = 1; // AT-1 is refused by the API
    const tokens_before = r.fake.counts.token;
    try std.testing.expectEqual(exit.ok, r.pub_(&live));
    try std.testing.expectEqual(@as(u32, 2), r.fake.counts.token - tokens_before); // one sign-in + one refresh
    // missing secrets are blocked, not a crash
    const r2 = try Rig.create(std.testing.allocator);
    defer r2.destroy();
    _ = try r2.addPair("a", "car1", .{});
    r2.cx.cfg.google.refresh_token_file = "nope.txt";
    try std.testing.expectEqual(exit.blocked, r2.pub_(&live));
    r2.cx.cfg.google.client_id_file = "nope.txt";
    try std.testing.expectEqual(exit.blocked, r2.pub_(&live));
}

test "processing result: failed and rejected are recorded, a slow one stays posted" {
    const r = try Rig.create(std.testing.allocator);
    defer r.destroy();
    _ = try r.addPair("a", "car1", .{});
    r.fake.status_script = &.{ "uploaded", "processed" };
    try std.testing.expectEqual(exit.ok, r.pub_(&live));
    try std.testing.expect((try r.row("car1:t1:vime-short")).?.state == .posted);
    const f = try Rig.create(std.testing.allocator);
    defer f.destroy();
    _ = try f.addPair("a", "car1", .{});
    f.fake.status_script = &.{"failed:codec"};
    try std.testing.expectEqual(exit.failed, f.pub_(&live));
    const fr = (try f.row("car1:t1:vime-short")).?;
    try std.testing.expect(fr.state == .failed and std.mem.indexOf(u8, fr.note, "codec") != null);
    try std.testing.expectEqualStrings("vid1", fr.video_uri); // it exists on Vimeo: never re-uploaded blindly
    const j = try Rig.create(std.testing.allocator);
    defer j.destroy();
    _ = try j.addPair("a", "car1", .{});
    j.fake.status_script = &.{"rejected:duplicate"};
    try std.testing.expectEqual(exit.failed, j.pub_(&live));
    const l = try j.led();
    defer l.close();
    try std.testing.expectEqual(@as(i64, 1), try l.kvInt("breaker_hard"));
    const s = try Rig.create(std.testing.allocator);
    defer s.destroy();
    _ = try s.addPair("a", "car1", .{});
    s.fake.status_script = &.{"uploaded"};
    try std.testing.expectEqual(exit.ok, s.pub_(&live));
    const sr = (try s.row("car1:t1:vime-short")).?;
    try std.testing.expect(sr.state == .posted and std.mem.indexOf(u8, sr.note, "processing") != null);
}

test "crash recovery: a send left `sending` resumes from the session's byte; one with no session is queued again" {
    const r = try Rig.create(std.testing.allocator);
    defer r.destroy();
    const mp4 = try r.addPair("a", "car1", .{ .pad = 6000 });
    // simulate the dead process: row sending, session started, 100 bytes uploaded
    {
        var tok = try call.Tok.init(&r.cx, r.al_());
        const meta = session.Meta{ .title = "Xe dep gia tot", .description = "d", .tags = &.{}, .category_id = "2", .privacy = "private", .made_for_kids = false, .notify = false };
        const uri = switch (session.start(&tok, meta, mp4.len)) {
            .ok => |u| u,
            else => return error.TestUnexpectedResult,
        };
        const l = try r.led();
        defer l.close();
        _ = try l.insertNew("a", "car1:t1:vime-short", .sending, "Xe dep gia tot", 1000);
        try l.begin("car1:t1:vime-short", 1000, caps.ptDay(1000), @intCast(mp4.len), "Xe dep gia tot");
        try l.setSession("car1:t1:vime-short", uri, 1000);
        r.srv.cut_after.store(100, .release);
        const p = upload.put(&tok, uri, try std.fmt.allocPrint(r.al_(), "{s}/a.mp4", .{r.src}), mp4.len, 0);
        try std.testing.expect(p != .done);
    }
    try std.testing.expectEqual(exit.ok, r.pub_(&live)); // recovery resumes at byte 100 and finishes
    const row = (try r.row("car1:t1:vime-short")).?;
    try std.testing.expect(row.state == .posted);
    try std.testing.expectEqual(@as(u32, 1), r.fake.counts.start);
    try std.testing.expectEqualSlices(u8, &sha(mp4[100..]), &r.fake.sessions[0].segs[1].sha);
    // a crash before any session: the row goes back to ready, then is sent in the same run
    const q = try Rig.create(std.testing.allocator);
    defer q.destroy();
    _ = try q.addPair("b", "car2", .{});
    {
        const l = try q.led();
        defer l.close();
        _ = try l.insertNew("b", "car2:t1:vime-short", .sending, "t", 1000);
    }
    try std.testing.expectEqual(exit.ok, q.pub_(&live));
    try std.testing.expect((try q.row("car2:t1:vime-short")).?.state == .posted);
}

test "login: PKCE round trip stores the token (mode 600), a wrong state stores nothing, an existing token needs --force" {
    const r = try Rig.create(std.testing.allocator);
    defer r.destroy();
    const a = r.al_();
    // start clean: no token file
    r.cx.cfg.google.refresh_token_file = "new-refresh.txt";
    const p = try auth.prepare(&r.cx, a, 1);
    r.fake.challenge = p.challenge;
    const bad = try std.fmt.allocPrint(a, "http://127.0.0.1:1/?code=CODE-1&state=EVIL", .{});
    try std.testing.expectEqual(exit.failed, login.finish(&r.cx, a, p, bad));
    try std.testing.expect(auth.readRefresh(&r.cx, a) == null);
    const good = try std.fmt.allocPrint(a, "http://127.0.0.1:1/?code=CODE-1&state={s}&scope=x", .{p.state});
    try std.testing.expectEqual(exit.ok, login.finish(&r.cx, a, p, good));
    try std.testing.expectEqualStrings("RT-NEW", auth.readRefresh(&r.cx, a).?);
    const st = try std.Io.Dir.cwd().statFile(std.testing.io, try r.cx.secretPath(a, "new-refresh.txt"), .{});
    try std.testing.expectEqual(@as(u32, 0o600), @as(u32, @intCast(st.permissions.toMode() & 0o777)));
    // a second login is refused (Google keeps few tokens per client)
    try std.testing.expectEqual(exit.blocked, login.run(&r.cx, &.{"--live"}));
    // the url has the safe parts and no secret
    try std.testing.expect(std.mem.indexOf(u8, p.url, "code_challenge_method=S256") != null);
    try std.testing.expect(std.mem.indexOf(u8, p.url, "access_type=offline") != null);
    try std.testing.expect(std.mem.indexOf(u8, p.url, "vimeo.upload") != null);
    try std.testing.expect(std.mem.indexOf(u8, p.url, "client_secret") == null);
}

test "doctor, status, scan, backup, config run and report" {
    const r = try Rig.create(std.testing.allocator);
    defer r.destroy();
    _ = try r.addPair("a", "car1", .{});
    _ = try r.addPair("w", "car2", .{ .w = 1920, .h = 1080 });
    try std.testing.expectEqual(exit.ok, doctor.run(&r.cx, &.{}));
    try std.testing.expectEqual(exit.ok, scan.run(&r.cx, &.{}, false));
    try std.testing.expectEqual(exit.ok, scan.run(&r.cx, &.{}, true));
    try std.testing.expectEqual(exit.ok, status.run(&r.cx, &.{}, false));
    try std.testing.expectEqual(exit.ok, status.run(&r.cx, &.{}, true));
    try std.testing.expectEqual(exit.ok, admin.backup(&r.cx, &.{}));
    try std.testing.expectEqual(exit.ok, admin.config(&r.cx, &.{}, true));
    try std.testing.expectEqual(exit.ok, token.run(&r.cx, &.{}));
    // a broken sign-in makes doctor say so (exit 3), without a crash
    r.fake.invalid_grant = true;
    try std.testing.expectEqual(exit.blocked, doctor.run(&r.cx, &.{}));
    // the wide video can never be sent, even when named
    r.fake.invalid_grant = false;
    try std.testing.expectEqual(exit.nothing, r.pub_(&.{ "--live", "--video", "w" }));
    try std.testing.expectEqual(@as(u32, 0), r.fake.counts.start);
}

test "a 64 MB video streams: bytes arrive identical and memory stays flat" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    const r = try Rig.create(std.testing.allocator);
    defer r.destroy();
    const al = r.al_();
    const head = try probe.testHead(al, 1080, 1920, 20);
    const payload: u64 = 64 * 1024 * 1024;
    const path = try std.fmt.allocPrint(al, "{s}/big.mp4", .{r.src});
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    {
        var f = try std.Io.Dir.cwd().createFile(std.testing.io, path, .{});
        defer f.close(std.testing.io);
        var hdr: [8]u8 = undefined;
        std.mem.writeInt(u32, hdr[0..4], @intCast(8 + payload), .big);
        @memcpy(hdr[4..8], "mdat");
        try f.writePositionalAll(std.testing.io, head, 0);
        try f.writePositionalAll(std.testing.io, &hdr, head.len);
        hasher.update(head);
        hasher.update(&hdr);
        const chunk = try al.alloc(u8, 1 << 20);
        for (chunk, 0..) |*b, i| b.* = @truncate(i *% 13 +% 5);
        var off: u64 = head.len + 8;
        var done: u64 = 0;
        while (done < payload) : (done += chunk.len) {
            try f.writePositionalAll(std.testing.io, chunk, off);
            hasher.update(chunk);
            off += chunk.len;
        }
    }
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = try std.fmt.allocPrint(al, "{s}/big.json", .{r.src}), .data = "{\"car\":\"big\",\"template\":\"t1\",\"mp4\":\"big.mp4\",\"hooks\":[\"Big\"],\"ai_notice\":\"AI\"}" });
    const before = hwmKb();
    try std.testing.expectEqual(exit.ok, r.pub_(&live));
    const after = hwmKb();
    var want: [32]u8 = undefined;
    hasher.final(&want);
    const s0 = r.fake.sessions[0];
    try std.testing.expect(s0.completed);
    try std.testing.expectEqual(@as(u64, head.len + 8 + payload), s0.stored);
    try std.testing.expectEqualSlices(u8, &want, &s0.segs[0].sha);
    // peak memory grew by far less than the file (it would be >= 64 MB if the file were loaded whole)
    try std.testing.expect(after -| before < 32 * 1024);
}

// a session started by a "dead process": row sending, `cut` bytes uploaded. Returns the mp4 bytes' size and the session address.
fn crashAt(r: *Rig, name: []const u8, car: []const u8, mp4_len: usize, cut: u64) ![]const u8 {
    var tok = try call.Tok.init(&r.cx, r.al_());
    const meta = session.Meta{ .title = "Xe dep gia tot", .description = "d", .tags = &.{}, .category_id = "2", .privacy = "private", .made_for_kids = false, .notify = false };
    const uri = switch (session.start(&tok, meta, mp4_len)) {
        .ok => |u| u,
        else => return error.TestUnexpectedResult,
    };
    const pkey = try std.fmt.allocPrint(r.al_(), "{s}:t1:vime-short", .{car});
    const l = try r.led();
    defer l.close();
    _ = try l.insertNew(name, pkey, .sending, "Xe dep gia tot", 1000);
    try l.begin(pkey, 1000, caps.ptDay(1000), @intCast(mp4_len), "Xe dep gia tot");
    try l.setSession(pkey, uri, 1000);
    if (cut > 0) {
        r.srv.cut_after.store(cut, .release);
        const p = upload.put(&tok, uri, try std.fmt.allocPrint(r.al_(), "{s}/{s}.mp4", .{ r.src, name }), mp4_len, 0);
        try std.testing.expect(p != .done);
    }
    return uri;
}

test "run budget ends mid-upload: the row stays `sending`, the next run resumes it (never unsure)" {
    const r = try Rig.create(std.testing.allocator);
    defer r.destroy();
    const mp4 = try r.addPair("a", "car1", .{ .pad = 6000 });
    const uri = try crashAt(r, "a", "car1", mp4.len, 100);
    var tok = try call.Tok.init(&r.cx, r.al_());
    var j = engine.Job{ .cx = &r.cx, .a = r.al_(), .l = try r.led(), .t = &tok, .pkey = "car1:t1:vime-short", .name = "a", .mp4 = try std.fmt.allocPrint(r.al_(), "{s}/a.mp4", .{r.src}), .size = mp4.len, .uri = uri, .t0_mono = util.monoMs(std.testing.io) - 10_000_000 };
    defer j.l.close();
    try std.testing.expect(engine.uploadFrom(&j, 100) == .stopped); // budget long gone
    try std.testing.expect((try r.row("car1:t1:vime-short")).?.state == .sending);
    try std.testing.expectEqual(exit.ok, r.pub_(&live)); // recovery resumes at byte 100
    try std.testing.expect((try r.row("car1:t1:vime-short")).?.state == .posted);
    try std.testing.expectEqualSlices(u8, &sha(mp4[100..]), &r.fake.sessions[0].segs[1].sha);
}

test "kill file during a run: queued again if no byte left, resumable if some did" {
    const r = try Rig.create(std.testing.allocator);
    defer r.destroy();
    const mp4 = try r.addPair("a", "car1", .{ .pad = 3000 });
    const uri = try crashAt(r, "a", "car1", mp4.len, 0);
    var tok = try call.Tok.init(&r.cx, r.al_());
    var j = engine.Job{ .cx = &r.cx, .a = r.al_(), .l = try r.led(), .t = &tok, .pkey = "car1:t1:vime-short", .name = "a", .mp4 = try std.fmt.allocPrint(r.al_(), "{s}/a.mp4", .{r.src}), .size = mp4.len, .uri = uri, .t0_mono = util.monoMs(std.testing.io) };
    defer j.l.close();
    try kill.set(&r.cx, r.al_(), true);
    try std.testing.expect(engine.uploadFrom(&j, 0) == .stopped);
    try std.testing.expectEqual(@as(u32, 0), r.fake.counts.put); // not one byte sent
    const row = (try r.row("car1:t1:vime-short")).?;
    try std.testing.expect(row.state == .ready and row.started == 0); // queued again, not counted
}

test "a 308 whose Range points past the file is not trusted: unsure, never a bad Content-Range" {
    const r = try Rig.create(std.testing.allocator);
    defer r.destroy();
    _ = try r.addPair("a", "car1", .{});
    r.fake.bad_range = true;
    try std.testing.expectEqual(exit.unsure, r.pub_(&live));
    try std.testing.expect((try r.row("car1:t1:vime-short")).?.state == .unsure);
    try std.testing.expectEqual(@as(u32, 1), r.fake.counts.put);
}

test "401 on the PUT: a new token is fetched, the session is asked, the bytes are resent from where it stands" {
    const r = try Rig.create(std.testing.allocator);
    defer r.destroy();
    const mp4 = try r.addPair("a", "car1", .{});
    r.fake.put_401_once = true;
    try std.testing.expectEqual(exit.ok, r.pub_(&live));
    try std.testing.expect((try r.row("car1:t1:vime-short")).?.state == .posted);
    try std.testing.expectEqual(@as(u32, 2), r.fake.counts.token); // sign-in + the refresh after the 401
    try std.testing.expectEqual(@as(u32, 1), r.fake.counts.start);
    try std.testing.expectEqualSlices(u8, &sha(mp4), &r.fake.sessions[0].segs[0].sha); // the 401 request stored nothing
}

test "a send that never started does not burn the day's cap or the gap" {
    const r = try Rig.create(std.testing.allocator);
    defer r.destroy();
    r.cx.cfg.limits.daily_cap = 1;
    _ = try r.addPair("a", "car1", .{});
    r.fake.start_mode = .srv_503_always;
    try std.testing.expectEqual(exit.failed, r.pub_(&live));
    const l = try r.led();
    defer l.close();
    try std.testing.expectEqual(@as(u32, 0), try l.countDay(caps.ptDay(util.nowMs(std.testing.io))));
    try std.testing.expectEqual(@as(i64, 0), try l.lastStarted());
    r.fake.start_mode = .ok;
    r.cx.fake_now_ms = util.nowMs(std.testing.io) + 7 * 3600 * 1000; // breaker cool-down passed
    try std.testing.expectEqual(exit.ok, r.pub_(&live)); // the single slot of the day was still free
}

test "resolve works on an approved review video too (title and start time are in the ledger)" {
    const r = try Rig.create(std.testing.allocator);
    defer r.destroy();
    _ = try r.addPair("rev", "car9", .{ .review = true });
    try std.testing.expectEqual(exit.ok, approve.run(&r.cx, &.{ "--video", "rev", "--live" }, true));
    r.fake.put_mode = .expire_after_complete;
    try std.testing.expectEqual(exit.unsure, r.pub_(&live));
    const row = (try r.row("car9:t1:vime-short")).?;
    try std.testing.expectEqualStrings("Xe dep gia tot", row.title);
    try std.testing.expect(row.started > 0);
    try std.testing.expectEqual(exit.ok, resolve.run(&r.cx, &.{ "--video", "rev", "--live" }));
    try std.testing.expect((try r.row("car9:t1:vime-short")).?.state == .posted);
}

test "recovery that cannot ask the session is tried a few runs, then parked as unsure" {
    const r = try Rig.create(std.testing.allocator);
    defer r.destroy();
    r.cx.cfg.net.retries = 2;
    const mp4 = try r.addPair("a", "car1", .{});
    {
        const l = try r.led();
        defer l.close();
        _ = try l.insertNew("a", "car1:t1:vime-short", .sending, "Xe dep gia tot", 1000);
        try l.begin("car1:t1:vime-short", 1000, caps.ptDay(1000), @intCast(mp4.len), "Xe dep gia tot");
        try l.setSession("car1:t1:vime-short", "http://127.0.0.1:1/dead-session", 1000);
    }
    try std.testing.expectEqual(exit.blocked, r.pub_(&live)); // run 1: left `sending`
    try std.testing.expect((try r.row("car1:t1:vime-short")).?.state == .sending);
    try std.testing.expectEqual(exit.unsure, r.pub_(&live)); // run 2: parked
    try std.testing.expect((try r.row("car1:t1:vime-short")).?.state == .unsure);
}

test "recovery refuses a source file that changed after the crash" {
    const r = try Rig.create(std.testing.allocator);
    defer r.destroy();
    const mp4 = try r.addPair("a", "car1", .{ .pad = 6000 });
    _ = try crashAt(r, "a", "car1", mp4.len, 100);
    _ = try r.addPair("a", "car1", .{ .pad = 9000 }); // re-rendered: another size
    try std.testing.expectEqual(exit.unsure, r.pub_(&live));
    const row = (try r.row("car1:t1:vime-short")).?;
    try std.testing.expect(row.state == .unsure and std.mem.indexOf(u8, row.note, "changed") != null);
}

test "approve of a failed video that had started uploading needs --resend; resolve can settle it" {
    const r = try Rig.create(std.testing.allocator);
    defer r.destroy();
    _ = try r.addPair("a", "car1", .{});
    {
        const l = try r.led();
        defer l.close();
        _ = try l.insertNew("a", "car1:t1:vime-short", .failed, "Xe dep gia tot", 1000);
        try l.setSession("car1:t1:vime-short", "http://127.0.0.1:1/x", 1000);
    }
    try std.testing.expectEqual(exit.blocked, approve.run(&r.cx, &.{ "--video", "a", "--live" }, true));
    try std.testing.expectEqual(exit.ok, approve.run(&r.cx, &.{ "--video", "a", "--live", "--resend" }, true));
}

fn hwmKb() u64 {
    var buf: [4096]u8 = undefined;
    const f = std.Io.Dir.cwd().openFile(std.testing.io, "/proc/self/status", .{}) catch return 0;
    defer f.close(std.testing.io);
    const n = f.readPositionalAll(std.testing.io, &buf, 0) catch return 0;
    const t = buf[0..n];
    const i = std.mem.indexOf(u8, t, "VmHWM:") orelse return 0;
    var it = std.mem.tokenizeAny(u8, t[i + 6 ..], " \tkB\n");
    return std.fmt.parseInt(u64, it.next() orelse return 0, 10) catch 0;
}
// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
