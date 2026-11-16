// publish against the fake Threads: happy path, dry-run, staged, replay, every failure class, crash, cap, kill, lock, review hold, lost-ledger probe, quota, host handling.
const std = @import("std");
const Io = std.Io;
const W = @import("te-world.zig").World;
const fk = @import("te-fake-threads.zig");
const pub_cmd = @import("cm-publish.zig");
const exit = @import("co-exit.zig");
const send = @import("rw-send.zig");
const kill = @import("co-kill.zig");
const util = @import("co-util.zig");

const key = "car1:t1:thre-shor";

fn pub1(w: *W, extra: []const []const u8) u8 {
    return pub_cmd.run(&w.cx, extra);
}
fn errReply(code: i64, a: std.mem.Allocator) !fk.Rep {
    return .{ .status = 400, .body = try std.fmt.allocPrint(a, "{{\"error\":{{\"message\":\"m\",\"code\":{d}}}}}", .{code}) };
}

test "dry-run copies and sends nothing" {
    var w: W = undefined;
    try w.init();
    defer w.deinit();
    try w.pair("a", "car1", false, .{});
    w.cx.live = false;
    try std.testing.expectEqual(exit.OK, pub1(&w, &.{}));
    try std.testing.expectEqual(@as(u32, 0), w.f.create_n.load(.acquire));
    try std.testing.expect(!w.f.logHas("POST"));
    try std.testing.expectEqual(@as(usize, 0), try w.count(w.host_dir));
    try std.testing.expect((try w.row(key)) == null);
}

test "happy path: AI flag on create only, one topic tag, token never in a log, hosted copy moved to done_dir, once only" {
    var w: W = undefined;
    try w.init();
    defer w.deinit();
    try w.pair("a", "car1", false, .{});
    try std.testing.expectEqual(exit.OK, pub1(&w, &.{}));
    try std.testing.expectEqual(@as(u32, 1), w.f.create_n.load(.acquire));
    try std.testing.expectEqual(@as(u32, 1), w.f.publish_n.load(.acquire));
    try std.testing.expect(w.f.fetched_ok.load(.acquire)); // Meta's downloader found the file at video_url
    const a = w.arena.allocator();
    const cb = try w.f.createText(a);
    try std.testing.expect(std.mem.indexOf(u8, cb, "is_made_with_ai=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, cb, "media_type=VIDEO") != null);
    try std.testing.expect(std.mem.indexOf(u8, cb, "topic_tag=cars") != null);
    try std.testing.expect(std.mem.indexOf(u8, cb, "Made%20with%20AI.") != null);
    try std.testing.expect(std.mem.indexOf(u8, cb, "%23") == null); // no #tag in the text
    try std.testing.expect(std.mem.indexOf(u8, cb, "car1") == null); // nothing about the car in the url or text
    const pb = try w.f.publishText(a);
    try std.testing.expect(std.mem.indexOf(u8, pb, "is_made_with_ai") == null); // never on threads_publish
    try std.testing.expect(std.mem.indexOf(u8, pb, "creation_id=") != null);
    const r = (try w.row(key)).?;
    try std.testing.expectEqual(send.State.posted, r.state);
    try std.testing.expectEqualStrings("9001", r.media_id);
    try std.testing.expect(std.mem.indexOf(u8, r.url, "threads.com") != null);
    try std.testing.expect(r.pub_at > 0);
    try std.testing.expectEqual(@as(usize, 0), try w.count(w.host_dir)); // renamed away, not deleted
    try std.testing.expectEqual(@as(usize, 1), try w.count(w.done_dir));
    // the run log never holds the token
    const lp = try w.cx.dataPath(a, "run.jsonl");
    try std.testing.expect(util.exists(w.cx.io, lp)); // the log exists and is clean
    const lt = try util.readAll(a, w.cx.io, lp, 1 << 20);
    try std.testing.expect(std.mem.indexOf(u8, lt, "TESTTOKEN") == null);
    try std.testing.expect(std.mem.indexOf(u8, lt, "access_token=TESTTOKEN") == null);
    // replay: nothing new is sent, answered from the ledger
    try std.testing.expectEqual(exit.NOTHING, pub1(&w, &.{}));
    try std.testing.expectEqual(exit.OK, pub1(&w, &.{ "--video", "a" }));
    try std.testing.expectEqual(@as(u32, 1), w.f.create_n.load(.acquire));
    try std.testing.expectEqual(@as(u32, 1), w.f.publish_n.load(.acquire));
}

test "post.public=false stops at staged (no publish call); a later public run continues the SAME container" {
    var w: W = undefined;
    try w.init();
    defer w.deinit();
    w.cx.cfg.post.public = false;
    try w.pair("a", "car1", false, .{});
    try std.testing.expectEqual(exit.OK, pub1(&w, &.{}));
    try std.testing.expectEqual(@as(u32, 0), w.f.publish_n.load(.acquire));
    const r = (try w.row(key)).?;
    try std.testing.expectEqual(send.State.staged, r.state);
    try std.testing.expectEqual(@as(usize, 1), try w.count(w.host_dir)); // still served until terminal
    try std.testing.expectEqual(@as(usize, 0), w.f.postCount());
    // staged is not picked while public is false
    try std.testing.expectEqual(exit.NOTHING, pub1(&w, &.{}));
    w.cx.cfg.post.public = true;
    try std.testing.expectEqual(exit.OK, pub1(&w, &.{}));
    try std.testing.expectEqual(@as(u32, 1), w.f.create_n.load(.acquire)); // no second container
    try std.testing.expectEqual(@as(u32, 1), w.f.publish_n.load(.acquire));
    try std.testing.expectEqual(send.State.posted, (try w.row(key)).?.state);
    try std.testing.expectEqual(@as(usize, 1), try w.count(w.done_dir));
}

test "a staged container that expired gets a new attempt, still one post" {
    var w: W = undefined;
    try w.init();
    defer w.deinit();
    w.cx.cfg.post.public = false;
    try w.pair("a", "car1", false, .{});
    try std.testing.expectEqual(exit.OK, pub1(&w, &.{}));
    w.cx.cfg.post.public = true;
    const sc = [_]fk.Word{ .expired, .finished };
    w.f.script = &sc;
    w.f.status_n.store(0, .release);
    try std.testing.expectEqual(exit.OK, pub1(&w, &.{}));
    try std.testing.expectEqual(@as(u32, 2), w.f.create_n.load(.acquire));
    const r = (try w.row(key)).?;
    try std.testing.expectEqual(send.State.posted, r.state);
    try std.testing.expectEqual(@as(i64, 2), r.attempt);
    try std.testing.expectEqual(@as(usize, 1), w.f.postCount());
}

test "device.publisher=false blocks --live, not the dry-run" {
    var w: W = undefined;
    try w.init();
    defer w.deinit();
    w.cx.cfg.device.publisher = false;
    try w.pair("a", "car1", false, .{});
    try std.testing.expectEqual(exit.BLOCKED, pub1(&w, &.{}));
    try std.testing.expectEqual(@as(u32, 0), w.f.create_n.load(.acquire));
    w.cx.live = false;
    try std.testing.expectEqual(exit.OK, pub1(&w, &.{}));
}

test "review:true is held until approved, never auto-sent" {
    var w: W = undefined;
    try w.init();
    defer w.deinit();
    try w.pair("h", "car9", true, .{});
    try std.testing.expectEqual(exit.NOTHING, pub1(&w, &.{}));
    try std.testing.expectEqual(exit.BLOCKED, pub1(&w, &.{ "--video", "h" }));
    try std.testing.expectEqual(@as(u32, 0), w.f.create_n.load(.acquire));
    try std.testing.expectEqual(exit.OK, @import("cm-approve.zig").run(&w.cx, &.{ "--video", "h" }, true));
    try std.testing.expectEqual(exit.OK, pub1(&w, &.{}));
    try std.testing.expectEqual(@as(u32, 1), w.f.publish_n.load(.acquire));
}

test "missing ai_notice: refused, nothing copied or sent" {
    var w: W = undefined;
    try w.init();
    defer w.deinit();
    try w.pair("a", "car1", false, .{});
    const jp = try std.fmt.allocPrint(w.arena.allocator(), "{s}/a.json", .{w.src});
    try Io.Dir.cwd().writeFile(w.cx.io, .{ .sub_path = jp, .data = "{\"car\":\"car1\",\"template\":\"t1\",\"mp4\":\"a.mp4\",\"description\":\"x\",\"ai_notice\":\"\"}" });
    try std.testing.expectEqual(exit.FAILED, pub1(&w, &.{ "--video", "a" }));
    try std.testing.expectEqual(@as(u32, 0), w.f.create_n.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), try w.count(w.host_dir));
}

test "FINISHED never comes in time: the row stays, the next run continues the same container" {
    var w: W = undefined;
    try w.init();
    defer w.deinit();
    const sc = [_]fk.Word{.in_progress};
    w.f.script = &sc;
    try w.pair("a", "car1", false, .{});
    try std.testing.expectEqual(exit.NOTHING, pub1(&w, &.{}));
    try std.testing.expectEqual(send.State.sending, (try w.row(key)).?.state);
    const sc2 = [_]fk.Word{.finished};
    w.f.script = &sc2;
    try std.testing.expectEqual(exit.OK, pub1(&w, &.{}));
    try std.testing.expectEqual(@as(u32, 1), w.f.create_n.load(.acquire)); // never a second container
    try std.testing.expectEqual(@as(u32, 1), w.f.publish_n.load(.acquire));
}

test "the first status read can be a 404 (still propagating)" {
    var w: W = undefined;
    try w.init();
    defer w.deinit();
    w.f.status_first_404 = 1;
    try w.pair("a", "car1", false, .{});
    try std.testing.expectEqual(exit.OK, pub1(&w, &.{}));
}

test "download error: new file name, new container, then it goes through" {
    var w: W = undefined;
    try w.init();
    defer w.deinit();
    const sc = [_]fk.Word{ .err_download, .finished };
    w.f.script = &sc;
    try w.pair("a", "car1", false, .{});
    try std.testing.expectEqual(exit.OK, pub1(&w, &.{}));
    try std.testing.expectEqual(@as(u32, 2), w.f.create_n.load(.acquire));
    try std.testing.expectEqual(@as(u32, 1), w.f.publish_n.load(.acquire));
    try std.testing.expectEqual(@as(usize, 2), try w.count(w.done_dir)); // the first copy was given back too
}

test "other container errors fail the row with Meta's reason, no retry" {
    var w: W = undefined;
    try w.init();
    defer w.deinit();
    const sc = [_]fk.Word{.err_duration};
    w.f.script = &sc;
    try w.pair("a", "car1", false, .{});
    try std.testing.expectEqual(exit.FAILED, pub1(&w, &.{}));
    const r = (try w.row(key)).?;
    try std.testing.expectEqual(send.State.failed, r.state);
    try std.testing.expect(std.mem.indexOf(u8, r.note, "INVALID_DURATION") != null);
    try std.testing.expectEqual(@as(u32, 0), w.f.publish_n.load(.acquire));
    try std.testing.expectEqual(exit.NOTHING, pub1(&w, &.{})); // failed is skipped by auto-pick
    try std.testing.expectEqual(exit.FAILED, pub1(&w, &.{ "--video", "a" }));
}

test "publish answers 500 but the post exists: unsure, never retried, resolve finds it" {
    var w: W = undefined;
    try w.init();
    defer w.deinit();
    w.f.publish_500_posted = true;
    try w.pair("a", "car1", false, .{});
    try std.testing.expectEqual(exit.UNSURE, pub1(&w, &.{}));
    try std.testing.expectEqual(send.State.unsure, (try w.row(key)).?.state);
    try std.testing.expectEqual(exit.NOTHING, pub1(&w, &.{}));
    try std.testing.expectEqual(exit.UNSURE, pub1(&w, &.{ "--video", "a" }));
    try std.testing.expectEqual(@as(u32, 1), w.f.publish_n.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), w.f.postCount());
}

test "a lost answer after the publish request left = unsure" {
    var w: W = undefined;
    try w.init();
    defer w.deinit();
    w.f.publish_drop = true;
    try w.pair("a", "car1", false, .{});
    try std.testing.expectEqual(exit.UNSURE, pub1(&w, &.{}));
    try std.testing.expectEqual(send.State.unsure, (try w.row(key)).?.state);
    try std.testing.expectEqual(@as(u32, 1), w.f.publish_n.load(.acquire));
}

test "a clean 4xx on publish fails the row (nothing posted); --again makes a new container" {
    var w: W = undefined;
    try w.init();
    defer w.deinit();
    w.f.publish_rep = try errReply(100, w.arena.allocator());
    try w.pair("a", "car1", false, .{});
    try std.testing.expectEqual(exit.FAILED, pub1(&w, &.{}));
    try std.testing.expectEqual(send.State.failed, (try w.row(key)).?.state);
    try std.testing.expectEqual(exit.NOTHING, pub1(&w, &.{}));
    w.f.publish_rep = null;
    try std.testing.expectEqual(exit.OK, pub1(&w, &.{ "--video", "a", "--again" }));
    try std.testing.expectEqual(@as(i64, 2), (try w.row(key)).?.attempt);
    try std.testing.expectEqual(@as(u32, 2), w.f.create_n.load(.acquire));
}

test "error classes at publish: 190 blocks, 613 stops the day, restricted account opens the breaker for good" {
    const cases = [_]struct { body: []const u8, code: u8 }{
        .{ .body = "{\"error\":{\"code\":190}}", .code = exit.BLOCKED },
        .{ .body = "{\"error\":{\"code\":613}}", .code = exit.BLOCKED },
        .{ .body = "{\"error\":{\"code\":1,\"error_subcode\":4279013}}", .code = exit.BLOCKED },
    };
    for (cases) |c| {
        var w: W = undefined;
        try w.init();
        defer w.deinit();
        w.f.publish_rep = .{ .status = 400, .body = c.body };
        try w.pair("a", "car1", false, .{});
        try std.testing.expectEqual(c.code, pub1(&w, &.{}));
        try std.testing.expectEqual(send.State.failed, (try w.row(key)).?.state);
        try w.pair("b", "car2", false, .{});
        const n = w.f.create_n.load(.acquire);
        if (std.mem.indexOf(u8, c.body, "190") == null) { // 190 only fails this row; the others block every later run
            try std.testing.expectEqual(exit.BLOCKED, pub1(&w, &.{}));
            try std.testing.expectEqual(n, w.f.create_n.load(.acquire));
        }
        if (std.mem.indexOf(u8, c.body, "4279013") != null) {
            w.cx.fake_now_ms = std.Io.Clock.real.now(w.cx.io).toMilliseconds() + 365 * 24 * 3600 * 1000; // time does not clear it
            try std.testing.expectEqual(exit.BLOCKED, pub1(&w, &.{}));
        }
    }
}

test "crash before the publish request: the next run continues the SAME container, one post" {
    var w: W = undefined;
    try w.init();
    defer w.deinit();
    try w.pair("a", "car1", false, .{});
    w.cx.crash_at = 2;
    try std.testing.expectEqual(@as(u8, 99), pub1(&w, &.{}));
    try std.testing.expectEqual(send.State.sending, (try w.row(key)).?.state);
    try std.testing.expectEqual(@as(u32, 0), w.f.publish_n.load(.acquire));
    w.cx.crash_at = 0;
    try std.testing.expectEqual(exit.OK, pub1(&w, &.{}));
    try std.testing.expectEqual(@as(u32, 1), w.f.create_n.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), w.f.postCount());
}

test "crash right after the container id: continued the same way" {
    var w: W = undefined;
    try w.init();
    defer w.deinit();
    try w.pair("a", "car1", false, .{});
    w.cx.crash_at = 1;
    try std.testing.expectEqual(@as(u8, 99), pub1(&w, &.{}));
    const r = (try w.row(key)).?;
    try std.testing.expect(r.container_id.len > 0);
    try std.testing.expect(r.host_file.len > 0);
    w.cx.crash_at = 0;
    try std.testing.expectEqual(exit.OK, pub1(&w, &.{}));
    try std.testing.expectEqual(@as(u32, 1), w.f.create_n.load(.acquire));
}

test "crash after the publish request left (before / after the answer): unsure on the next run, nothing sent twice" {
    var w: W = undefined;
    try w.init();
    defer w.deinit();
    try w.pair("a", "car1", false, .{});
    w.cx.crash_at = 3; // pub_at written, request not sent
    try std.testing.expectEqual(@as(u8, 99), pub1(&w, &.{}));
    w.cx.crash_at = 0;
    try std.testing.expectEqual(exit.NOTHING, pub1(&w, &.{}));
    try std.testing.expectEqual(send.State.unsure, (try w.row(key)).?.state);
    try std.testing.expectEqual(@as(u32, 0), w.f.publish_n.load(.acquire));
    var w2: W = undefined;
    try w2.init();
    defer w2.deinit();
    try w2.pair("a", "car1", false, .{});
    w2.cx.crash_at = 4; // answer received, ledger not yet updated
    try std.testing.expectEqual(@as(u8, 99), pub1(&w2, &.{}));
    w2.cx.crash_at = 0;
    try std.testing.expectEqual(exit.NOTHING, pub1(&w2, &.{}));
    try std.testing.expectEqual(send.State.unsure, (try w2.row(key)).?.state);
    try std.testing.expectEqual(@as(u32, 1), w2.f.publish_n.load(.acquire));
}

test "lost ledger: the account already has this text, nothing is sent (unsure)" {
    var w: W = undefined;
    try w.init();
    defer w.deinit();
    try w.pair("a", "car1", false, .{});
    try std.testing.expectEqual(exit.OK, pub1(&w, &.{}));
    // wipe the ledger (a restored or empty database) and the hosted copy bookkeeping
    const lp = try send.dbPath(&w.cx, w.arena.allocator());
    const moved = try std.fmt.allocPrint(w.arena.allocator(), "{s}.moved", .{lp});
    try Io.Dir.cwd().rename(lp, Io.Dir.cwd(), moved, w.cx.io);
    try std.testing.expectEqual(exit.UNSURE, pub_cmd.run(&w.cx, &.{"--init"}));
    try std.testing.expectEqual(@as(u32, 1), w.f.create_n.load(.acquire));
    try std.testing.expectEqual(@as(u32, 1), w.f.publish_n.load(.acquire));
    try std.testing.expectEqual(send.State.unsure, (try w.row(key)).?.state);
}

test "the probe cannot read the account: blocked, nothing sent, the pair stays ready" {
    var w: W = undefined;
    try w.init();
    defer w.deinit();
    w.f.list_rep = .{ .status = 500, .body = "down" };
    try w.pair("a", "car1", false, .{});
    try std.testing.expectEqual(exit.BLOCKED, pub1(&w, &.{}));
    try std.testing.expectEqual(@as(u32, 0), w.f.create_n.load(.acquire));
    try std.testing.expect((try w.row(key)) == null);
    w.f.list_rep = null;
    try std.testing.expectEqual(exit.OK, pub1(&w, &.{}));
}

test "dup_probe off skips the account read" {
    var w: W = undefined;
    try w.init();
    defer w.deinit();
    w.cx.cfg.safety.dup_probe = false;
    w.f.list_rep = .{ .status = 500, .body = "down" };
    try w.pair("a", "car1", false, .{});
    try std.testing.expectEqual(exit.OK, pub1(&w, &.{}));
    try std.testing.expectEqual(@as(u32, 0), w.f.list_n.load(.acquire));
}

test "server quota near the total blocks before any copy" {
    var w: W = undefined;
    try w.init();
    defer w.deinit();
    w.f.quota_usage = 245;
    try w.pair("a", "car1", false, .{});
    try std.testing.expectEqual(exit.BLOCKED, pub1(&w, &.{}));
    try std.testing.expectEqual(@as(usize, 0), try w.count(w.host_dir));
    try std.testing.expect((try w.row(key)) == null);
    w.f.quota_usage = 0;
    try std.testing.expectEqual(exit.BLOCKED, pub1(&w, &.{})); // the stop is remembered
    w.cx.fake_now_ms = std.Io.Clock.real.now(w.cx.io).toMilliseconds() + 7 * 3600 * 1000;
    try std.testing.expectEqual(exit.OK, pub1(&w, &.{}));
}

test "190 before any row: the pair is not burned" {
    var w: W = undefined;
    try w.init();
    defer w.deinit();
    w.f.quota_rep = try errReply(190, w.arena.allocator());
    try w.pair("a", "car1", false, .{});
    try std.testing.expectEqual(exit.BLOCKED, pub1(&w, &.{}));
    try std.testing.expect((try w.row(key)) == null);
    w.f.quota_rep = null;
    try std.testing.expectEqual(exit.OK, pub1(&w, &.{}));
}

test "the host does not serve the file (redirect): failed before create, copy given back" {
    var w: W = undefined;
    try w.init();
    defer w.deinit();
    w.f.redirect_host = true;
    try w.pair("a", "car1", false, .{});
    try std.testing.expectEqual(exit.FAILED, pub1(&w, &.{}));
    try std.testing.expectEqual(@as(u32, 0), w.f.create_n.load(.acquire));
    try std.testing.expectEqual(send.State.failed, (try w.row(key)).?.state);
    try std.testing.expectEqual(@as(usize, 0), try w.count(w.host_dir));
}

test "a host that ignores Range is fine" {
    var w: W = undefined;
    try w.init();
    defer w.deinit();
    w.f.ignore_range = true;
    try w.pair("a", "car1", false, .{});
    try std.testing.expectEqual(exit.OK, pub1(&w, &.{}));
}

test "host not configured: refused with a plain message" {
    var w: W = undefined;
    try w.init();
    defer w.deinit();
    w.cx.cfg.host.base_url = "";
    try w.pair("a", "car1", false, .{});
    try std.testing.expectEqual(exit.USAGE, pub1(&w, &.{}));
    try std.testing.expectEqual(@as(u32, 0), w.f.create_n.load(.acquire));
}

test "daily cap stops the second send; kill file and run lock stop everything" {
    var w: W = undefined;
    try w.init();
    defer w.deinit();
    w.cx.cfg.limits.daily_cap = 1;
    try w.pair("a", "c1", false, .{});
    try w.pair("b", "c2", false, .{});
    try std.testing.expectEqual(exit.OK, pub1(&w, &.{}));
    try std.testing.expectEqual(exit.BLOCKED, pub1(&w, &.{}));
    try std.testing.expectEqual(@as(u32, 1), w.f.publish_n.load(.acquire));
    w.cx.cfg.limits.daily_cap = 5;
    try kill.setKill(&w.cx, true);
    try std.testing.expectEqual(exit.BLOCKED, pub1(&w, &.{}));
    try kill.setKill(&w.cx, false);
    var l = try kill.acquire(&w.cx);
    try std.testing.expectEqual(exit.BLOCKED, pub1(&w, &.{}));
    l.release();
    try std.testing.expectEqual(exit.OK, pub1(&w, &.{}));
    try std.testing.expectEqual(@as(u32, 2), w.f.publish_n.load(.acquire));
}

test "breaker opens after N failures and holds" {
    var w: W = undefined;
    try w.init();
    defer w.deinit();
    const sc = [_]fk.Word{.err_duration};
    w.f.script = &sc;
    w.cx.cfg.breaker.fails = 2;
    try w.pair("a", "c1", false, .{});
    try w.pair("b", "c2", false, .{});
    try w.pair("c", "c3", false, .{});
    try std.testing.expectEqual(exit.FAILED, pub1(&w, &.{}));
    try std.testing.expectEqual(exit.FAILED, pub1(&w, &.{}));
    const n = w.f.create_n.load(.acquire);
    try std.testing.expectEqual(exit.BLOCKED, pub1(&w, &.{}));
    try std.testing.expectEqual(n, w.f.create_n.load(.acquire));
}

test "a missing ledger next to old files is refused (wrong folder)" {
    var w: W = undefined;
    try w.init();
    defer w.deinit();
    w.cx.cfg.safety.dup_probe = false;
    try w.pair("a", "c1", false, .{});
    try w.pair("b", "c2", false, .{});
    try std.testing.expectEqual(exit.OK, pub1(&w, &.{}));
    const lp = try send.dbPath(&w.cx, w.arena.allocator());
    const moved = try std.fmt.allocPrint(w.arena.allocator(), "{s}.moved", .{lp});
    try Io.Dir.cwd().rename(lp, Io.Dir.cwd(), moved, w.cx.io);
    try std.testing.expectEqual(exit.BLOCKED, pub1(&w, &.{}));
    try std.testing.expectEqual(@as(u32, 1), w.f.create_n.load(.acquire));
}

test "--video with no value is a usage error, not 'the oldest'" {
    var w: W = undefined;
    try w.init();
    defer w.deinit();
    try w.pair("a", "c1", false, .{});
    try std.testing.expectEqual(exit.USAGE, pub1(&w, &.{"--video"}));
    try std.testing.expectEqual(@as(u32, 0), w.f.create_n.load(.acquire));
}

test "an error body that echoes a token never reaches the ledger or the log raw" {
    var w: W = undefined;
    try w.init();
    defer w.deinit();
    w.f.create_rep = .{ .status = 400, .body = "{\"error\":{\"code\":100,\"message\":\"bad access_token=SEKRET9 and \\\"token\\\":\\\"SEKRET8\\\" " ++ "\xe1\xbb\x87" ** 150 ++ "\"}}" };
    try w.pair("a", "c1", false, .{});
    try std.testing.expectEqual(exit.FAILED, pub1(&w, &.{}));
    const r = (try w.row("c1:t1:thre-shor")).?;
    try std.testing.expect(std.mem.indexOf(u8, r.note, "SEKRET9") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.note, "SEKRET8") == null);
    try std.testing.expect(std.unicode.utf8ValidateSlice(r.note));
    const lp = try w.cx.dataPath(w.arena.allocator(), "run.jsonl");
    const lt = try util.readAll(w.arena.allocator(), w.cx.io, lp, 1 << 20);
    try std.testing.expect(std.mem.indexOf(u8, lt, "TESTTOKEN") == null);
    try std.testing.expect(std.mem.indexOf(u8, lt, "SEKRET9") == null);
    try std.testing.expect(std.mem.indexOf(u8, lt, "SEKRET8") == null);
}

test "kill switched on after the container exists: not published, the row stays" {
    var w: W = undefined;
    try w.init();
    defer w.deinit();
    w.cx.cfg.post.public = false;
    try w.pair("a", "car1", false, .{});
    try std.testing.expectEqual(exit.OK, pub1(&w, &.{})); // staged
    w.cx.cfg.post.public = true;
    try kill.setKill(&w.cx, true);
    try std.testing.expectEqual(exit.BLOCKED, pub1(&w, &.{}));
    try std.testing.expectEqual(@as(u32, 0), w.f.publish_n.load(.acquire));
}

test "a quota reply without quota_usage blocks (a renamed field is not 0)" {
    var w: W = undefined;
    try w.init();
    defer w.deinit();
    w.f.quota_rep = .{ .body = "{\"data\":[{\"config\":{\"quota_total\":250}}]}" };
    try w.pair("a", "car1", false, .{});
    try std.testing.expectEqual(exit.BLOCKED, pub1(&w, &.{}));
    try std.testing.expectEqual(@as(u32, 0), w.f.create_n.load(.acquire));
}

test "--again after a publish that once left, while the post exists: unsure, not a double post" {
    var w: W = undefined;
    try w.init();
    defer w.deinit();
    w.f.publish_rep = try errReply(100, w.arena.allocator()); // a clean 4xx: failed, nothing posted ...
    try w.pair("a", "car1", false, .{});
    try std.testing.expectEqual(exit.FAILED, pub1(&w, &.{}));
    w.f.publish_rep = null;
    // ... but Threads shows a post that starts like ours (late landing): --again must not make another
    try w.f.fakePost("Hook a\n\nDesc a.\n\nMade with AI.");
    try std.testing.expectEqual(exit.UNSURE, pub1(&w, &.{ "--video", "a", "--again" }));
    try std.testing.expectEqual(@as(u32, 1), w.f.create_n.load(.acquire));
    try std.testing.expectEqual(send.State.unsure, (try w.row(key)).?.state);
}

test "a host that answers a big error page is not 'reachable'; one that refuses HEAD still works" {
    var w: W = undefined;
    try w.init();
    defer w.deinit();
    w.f.big_error_page = true;
    try w.pair("a", "car1", false, .{});
    try std.testing.expectEqual(exit.FAILED, pub1(&w, &.{}));
    try std.testing.expectEqual(@as(u32, 0), w.f.create_n.load(.acquire));
    var w2: W = undefined;
    try w2.init();
    defer w2.deinit();
    w2.f.no_head = true;
    try w2.pair("a", "car1", false, .{});
    try std.testing.expectEqual(exit.OK, pub1(&w2, &.{}));
}

test "a failed copy leaves nothing in the public folder" {
    var w: W = undefined;
    try w.init();
    defer w.deinit();
    const a = w.arena.allocator();
    try std.testing.expectError(error.Copy, @import("rw-host.zig").stage(&w.cx, a, "no/such/file.mp4"));
    try std.testing.expectEqual(@as(usize, 0), try w.count(w.host_dir));
}

test "an error that blocks (dead token at create) also stops the next runs" {
    var w: W = undefined;
    try w.init();
    defer w.deinit();
    w.f.create_rep = try errReply(190, w.arena.allocator());
    try w.pair("a", "car1", false, .{});
    try w.pair("b", "car2", false, .{});
    try std.testing.expectEqual(exit.BLOCKED, pub1(&w, &.{}));
    const n = w.f.create_n.load(.acquire);
    try std.testing.expectEqual(exit.BLOCKED, pub1(&w, &.{}));
    try std.testing.expectEqual(n, w.f.create_n.load(.acquire));
}

test "copying a 64 MB file keeps memory flat" {
    var w: W = undefined;
    try w.init();
    defer w.deinit();
    const a = w.arena.allocator();
    const big = try std.fmt.allocPrint(a, "{s}/big.bin", .{w.src});
    var f = try Io.Dir.cwd().createFile(w.cx.io, big, .{ .truncate = true, .read = true });
    try f.setLength(w.cx.io, 64 * 1024 * 1024);
    f.close(w.cx.io);
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const s = try @import("rw-host.zig").stage(&w.cx, ar.allocator(), big);
    try std.testing.expect(s.file.len == 36);
    try std.testing.expect(ar.queryCapacity() < 4 * 1024 * 1024);
}
