// publish against the fake Instagram: staged default, public path, replay, every outcome of media_publish, failures, crash, caps, kill, lock, review hold.
const std = @import("std");
const Io = std.Io;
const W = @import("te-world.zig").World;
const fk = @import("te-fake-graph.zig");
const pub_cmd = @import("cm-publish.zig");
const exit = @import("co-exit.zig");
const send = @import("rw-send.zig");
const kill = @import("co-kill.zig");
const mp4 = @import("te-mp4.zig");
const call = @import("ap-call.zig");
const up = @import("ap-upload.zig");
const util = @import("co-util.zig");

const ready_soon = [_]fk.Mode{ .in_progress, .finished };
const PK = "car1:t1:inst-shor";

fn pub1(w: *W, extra: []const []const u8) u8 {
    return pub_cmd.run(&w.cx, extra);
}

fn errReply(code: i64, sub: i64, a: std.mem.Allocator) !fk.Rep {
    return .{ .status = 400, .body = try std.fmt.allocPrint(a, "{{\"error\":{{\"message\":\"m\",\"code\":{d},\"error_subcode\":{d}}}}}", .{ code, sub }) };
}

fn realNow(w: *W) i64 {
    return std.Io.Clock.real.now(w.cx.io).toMilliseconds();
}

test "dry-run sends nothing" {
    var w: W = undefined;
    try w.init();
    defer w.deinit();
    try w.pair("a", "car1", false, .{});
    w.cx.live = false;
    try std.testing.expectEqual(exit.OK, pub1(&w, &.{}));
    try std.testing.expectEqual(@as(u32, 0), w.f.container_n.load(.acquire));
    try std.testing.expect(!w.f.logHas("POST"));
    try std.testing.expect((try w.row(PK)) == null);
}

test "default (public=false): container FINISHED then STAGED, media_publish never called, AI flag + notice sent, token only in the header" {
    var w: W = undefined;
    try w.init();
    defer w.deinit();
    w.f.script = &ready_soon;
    try w.pair("a", "car1", false, .{});
    try std.testing.expectEqual(exit.OK, pub1(&w, &.{}));
    try std.testing.expectEqual(@as(u32, 1), w.f.container_n.load(.acquire));
    try std.testing.expectEqual(@as(u32, 1), w.f.upload_n.load(.acquire));
    try std.testing.expectEqual(@as(u32, 0), w.f.publish_n.load(.acquire));
    const cb = try w.f.containerText(w.arena.allocator());
    try std.testing.expect(std.mem.indexOf(u8, cb, "\"is_ai_generated\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, cb, "\"media_type\":\"REELS\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, cb, "\"upload_type\":\"resumable\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, cb, "Made with AI.") != null);
    try std.testing.expect(std.mem.indexOf(u8, cb, "video_url") == null); // nothing is hosted publicly
    try std.testing.expect(!w.f.logHas("TESTTOKEN"));
    try std.testing.expect(!w.f.logHas("access_token"));
    const r = (try w.row(PK)).?;
    try std.testing.expectEqual(send.State.staged, r.state);
    try std.testing.expectEqualStrings("9876543210", r.cont_id);
    try std.testing.expectEqual(@as(i64, 0), r.pub_at);
    // replay: nothing new is sent, answered from the ledger
    try std.testing.expectEqual(exit.NOTHING, pub1(&w, &.{}));
    try std.testing.expectEqual(exit.OK, pub1(&w, &.{ "--video", "a" }));
    try std.testing.expectEqual(@as(u32, 1), w.f.container_n.load(.acquire));
    try std.testing.expectEqual(@as(u32, 0), w.f.publish_n.load(.acquire));
}

test "post.public true publishes; permalink stored; replay is a no-op" {
    var w: W = undefined;
    try w.init();
    defer w.deinit();
    w.f.script = &ready_soon;
    w.cx.cfg.post.public = true;
    try w.pair("a", "car1", false, .{});
    try std.testing.expectEqual(exit.OK, pub1(&w, &.{}));
    try std.testing.expectEqual(@as(u32, 1), w.f.publish_n.load(.acquire));
    const pb = try w.f.publishText(w.arena.allocator());
    try std.testing.expect(std.mem.indexOf(u8, pb, "\"creation_id\":\"9876543210\"") != null);
    const r = (try w.row(PK)).?;
    try std.testing.expectEqual(send.State.posted, r.state);
    try std.testing.expectEqualStrings("17900001", r.media_id);
    try std.testing.expect(std.mem.indexOf(u8, r.url, "FAKE123") != null);
    try std.testing.expect(r.pub_at > 0);
    try std.testing.expectEqual(exit.NOTHING, pub1(&w, &.{}));
    try std.testing.expectEqual(exit.OK, pub1(&w, &.{ "--video", "a" }));
    try std.testing.expectEqual(@as(u32, 1), w.f.publish_n.load(.acquire));
    try std.testing.expectEqual(@as(u32, 1), w.f.container_n.load(.acquire));
}

test "partial success (config_issue) is posted with the issue noted; AI flag read back false is warned" {
    var w: W = undefined;
    try w.init();
    defer w.deinit();
    w.f.script = &ready_soon;
    w.f.publish_issue = true;
    w.f.ai_flag = false;
    w.cx.cfg.post.public = true;
    try w.pair("a", "car1", false, .{});
    try std.testing.expectEqual(exit.OK, pub1(&w, &.{}));
    const r = (try w.row(PK)).?;
    try std.testing.expectEqual(send.State.posted, r.state);
    try std.testing.expect(std.mem.indexOf(u8, r.note, "CAPTION_NOT_ATTACHED") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.note, "is_ai_generated=false") != null);
    try std.testing.expectEqual(@as(u32, 1), w.f.publish_n.load(.acquire)); // never retried
}

test "a staged container goes public later: same container, no new upload" {
    var w: W = undefined;
    try w.init();
    defer w.deinit();
    w.f.script = &ready_soon;
    try w.pair("a", "car1", false, .{});
    try std.testing.expectEqual(exit.OK, pub1(&w, &.{}));
    try std.testing.expectEqual(send.State.staged, (try w.row(PK)).?.state);
    w.cx.cfg.post.public = true;
    w.f.status_n.store(0, .release);
    try std.testing.expectEqual(exit.OK, pub1(&w, &.{}));
    try std.testing.expectEqual(send.State.posted, (try w.row(PK)).?.state);
    try std.testing.expectEqual(@as(u32, 1), w.f.container_n.load(.acquire));
    try std.testing.expectEqual(@as(u32, 1), w.f.upload_n.load(.acquire));
    try std.testing.expectEqual(@as(u32, 1), w.f.publish_n.load(.acquire));
}

test "staged for more than 24 h expires; --again makes a new container" {
    var w: W = undefined;
    try w.init();
    defer w.deinit();
    w.f.script = &ready_soon;
    try w.pair("a", "car1", false, .{});
    try std.testing.expectEqual(exit.OK, pub1(&w, &.{}));
    w.cx.fake_now_ms = realNow(&w) + 25 * 3600 * 1000;
    try std.testing.expectEqual(exit.NOTHING, pub1(&w, &.{}));
    try std.testing.expectEqual(send.State.expired, (try w.row(PK)).?.state);
    try std.testing.expectEqual(exit.FAILED, pub1(&w, &.{ "--video", "a" }));
    w.f.status_n.store(0, .release);
    try std.testing.expectEqual(exit.OK, pub1(&w, &.{ "--video", "a", "--again" }));
    try std.testing.expectEqual(@as(u32, 2), w.f.container_n.load(.acquire));
    try std.testing.expectEqual(send.State.staged, (try w.row(PK)).?.state);
}

test "oldest pair first, then the next" {
    var w: W = undefined;
    try w.init();
    defer w.deinit();
    w.f.script = &ready_soon;
    try w.pair("first", "c1", false, .{});
    std.Io.sleep(w.cx.io, .fromMilliseconds(1100), .awake) catch {};
    try w.pair("second", "c2", false, .{});
    try std.testing.expectEqual(exit.OK, pub1(&w, &.{}));
    try std.testing.expect((try w.row("c1:t1:inst-shor")) != null);
    try std.testing.expect((try w.row("c2:t1:inst-shor")) == null);
    try std.testing.expectEqual(exit.OK, pub1(&w, &.{}));
    try std.testing.expect((try w.row("c2:t1:inst-shor")) != null);
}

test "review:true is held until approved, never auto-sent" {
    var w: W = undefined;
    try w.init();
    defer w.deinit();
    w.f.script = &ready_soon;
    try w.pair("h", "car9", true, .{});
    try std.testing.expectEqual(exit.NOTHING, pub1(&w, &.{}));
    try std.testing.expectEqual(exit.BLOCKED, pub1(&w, &.{ "--video", "h" }));
    try std.testing.expectEqual(@as(u32, 0), w.f.container_n.load(.acquire));
    try std.testing.expectEqual(exit.OK, @import("cm-approve.zig").run(&w.cx, &.{ "--video", "h" }, true));
    try std.testing.expectEqual(exit.OK, pub1(&w, &.{}));
    try std.testing.expectEqual(@as(u32, 1), w.f.container_n.load(.acquire));
}

test "missing ai_notice: refused, nothing sent" {
    var w: W = undefined;
    try w.init();
    defer w.deinit();
    try w.pair("a", "car1", false, .{});
    const jp = try std.fmt.allocPrint(w.arena.allocator(), "{s}/a.json", .{w.src});
    try Io.Dir.cwd().writeFile(w.cx.io, .{ .sub_path = jp, .data = "{\"car\":\"car1\",\"template\":\"t1\",\"mp4\":\"a.mp4\",\"description\":\"x\",\"ai_notice\":\"\"}" });
    try std.testing.expectEqual(exit.FAILED, pub1(&w, &.{ "--video", "a" }));
    try std.testing.expectEqual(@as(u32, 0), w.f.container_n.load(.acquire));
}

test "a file that is not fast-start (moov after mdat) or has edit lists never reaches Instagram" {
    var w: W = undefined;
    try w.init();
    defer w.deinit();
    try w.pair("slow", "car1", false, .{ .moov_first = false });
    try w.pair("edit", "car2", false, .{ .elst = true });
    try std.testing.expectEqual(exit.NOTHING, pub1(&w, &.{}));
    try std.testing.expectEqual(exit.FAILED, pub1(&w, &.{ "--video", "slow" }));
    try std.testing.expectEqual(exit.FAILED, pub1(&w, &.{ "--video", "edit" }));
    try std.testing.expectEqual(@as(u32, 0), w.f.container_n.load(.acquire));
}

test "interrupted upload restarts at offset 0 on the same container" {
    var w: W = undefined;
    try w.init();
    defer w.deinit();
    w.f.script = &ready_soon;
    try w.pair("a", "car1", false, .{ .mdat_mb = 2 });
    w.f.cut_after.store(100_000, .release);
    try std.testing.expectEqual(exit.OK, pub1(&w, &.{}));
    try std.testing.expectEqual(@as(u32, 2), w.f.upload_n.load(.acquire));
    try std.testing.expectEqual(@as(u32, 1), w.f.container_n.load(.acquire));
    try std.testing.expectEqual(send.State.staged, (try w.row(PK)).?.state);
    try std.testing.expectEqual(w.f.total.load(.acquire), w.f.have.load(.acquire));
}

test "ProcessingFailedError on upload: one more try, then failed (never publishes)" {
    var w: W = undefined;
    try w.init();
    defer w.deinit();
    w.cx.cfg.post.public = true;
    w.f.upload_rep = .{ .status = 200, .body = "{\"debug_info\":{\"retriable\":false,\"type\":\"ProcessingFailedError\"}}" };
    try w.pair("a", "car1", false, .{});
    try std.testing.expectEqual(exit.FAILED, pub1(&w, &.{}));
    try std.testing.expectEqual(@as(u32, 2), w.f.upload_n.load(.acquire));
    try std.testing.expectEqual(@as(u32, 0), w.f.publish_n.load(.acquire));
    try std.testing.expectEqual(send.State.failed, (try w.row(PK)).?.state);
}

test "container ERROR -> failed with the subcode; EXPIRED -> expired; neither publishes" {
    var w: W = undefined;
    try w.init();
    defer w.deinit();
    w.cx.cfg.post.public = true;
    const s1 = [_]fk.Mode{.error_code};
    w.f.script = &s1;
    try w.pair("a", "car1", false, .{});
    try std.testing.expectEqual(exit.FAILED, pub1(&w, &.{}));
    const r = (try w.row(PK)).?;
    try std.testing.expectEqual(send.State.failed, r.state);
    try std.testing.expect(std.mem.indexOf(u8, r.note, "2207026") != null);
    var w2: W = undefined;
    try w2.init();
    defer w2.deinit();
    w2.cx.cfg.post.public = true;
    const s2 = [_]fk.Mode{.expired};
    w2.f.script = &s2;
    try w2.pair("a", "car1", false, .{});
    try std.testing.expectEqual(exit.FAILED, pub1(&w2, &.{}));
    try std.testing.expectEqual(send.State.expired, (try w2.row(PK)).?.state);
    try std.testing.expectEqual(@as(u32, 0), w.f.publish_n.load(.acquire) + w2.f.publish_n.load(.acquire));
}

test "container still IN_PROGRESS after the poll window: row stays sending, next run moves it on" {
    var w: W = undefined;
    try w.init();
    defer w.deinit();
    const slow = [_]fk.Mode{.in_progress};
    w.f.script = &slow;
    try w.pair("a", "car1", false, .{});
    try std.testing.expectEqual(exit.BLOCKED, pub1(&w, &.{}));
    try std.testing.expectEqual(send.State.sending, (try w.row(PK)).?.state);
    try std.testing.expectEqual(@as(u32, 0), w.f.publish_n.load(.acquire));
    const ok = [_]fk.Mode{.finished};
    w.f.script = &ok;
    w.f.status_n.store(0, .release);
    try std.testing.expectEqual(exit.NOTHING, pub1(&w, &.{})); // resumed first: the row became staged, nothing else is ready
    try std.testing.expectEqual(send.State.staged, (try w.row(PK)).?.state);
    try std.testing.expectEqual(@as(u32, 1), w.f.container_n.load(.acquire));
}

test "media_publish errors: documented answers fail or stop; hard ones stop for good" {
    const cases = [_]struct { code: i64, sub: i64, exit_code: u8, st: send.State }{
        .{ .code = 100, .sub = 0, .exit_code = exit.FAILED, .st = .failed },
        .{ .code = 352, .sub = 2207026, .exit_code = exit.FAILED, .st = .failed },
        .{ .code = 190, .sub = 0, .exit_code = exit.BLOCKED, .st = .failed },
        .{ .code = 4, .sub = 2207051, .exit_code = exit.BLOCKED, .st = .failed },
        .{ .code = 25, .sub = 2207050, .exit_code = exit.BLOCKED, .st = .failed },
        .{ .code = 613, .sub = 0, .exit_code = exit.BLOCKED, .st = .failed },
        .{ .code = 9, .sub = 2207042, .exit_code = exit.BLOCKED, .st = .failed },
        .{ .code = -2, .sub = 2207020, .exit_code = exit.FAILED, .st = .expired },
    };
    for (cases) |c| {
        var w: W = undefined;
        try w.init();
        defer w.deinit();
        w.cx.cfg.post.public = true;
        w.f.script = &ready_soon;
        w.f.publish_rep = try errReply(c.code, c.sub, w.arena.allocator());
        try w.pair("a", "car1", false, .{});
        try std.testing.expectEqual(c.exit_code, pub1(&w, &.{}));
        try std.testing.expectEqual(c.st, (try w.row(PK)).?.state);
        if (c.sub == 2207051 or c.sub == 2207050 or c.code == 613 or c.sub == 2207042) {
            // the next run is blocked before any call
            try w.pair("b", "car2", false, .{});
            const n = w.f.container_n.load(.acquire);
            try std.testing.expectEqual(exit.BLOCKED, pub1(&w, &.{}));
            try std.testing.expectEqual(n, w.f.container_n.load(.acquire));
            if (c.sub == 2207051 or c.sub == 2207050) {
                w.cx.fake_now_ms = realNow(&w) + 365 * 24 * 3600 * 1000; // time does not clear a restriction
                try std.testing.expectEqual(exit.BLOCKED, pub1(&w, &.{}));
            }
        }
    }
}

test "2207027 not ready: keep polling and publish again, never a failure; gives up as failed, never unsure" {
    var w: W = undefined;
    try w.init();
    defer w.deinit();
    w.cx.cfg.post.public = true;
    w.f.script = &ready_soon;
    w.f.notready_first.store(1, .release);
    try w.pair("a", "car1", false, .{});
    try std.testing.expectEqual(exit.OK, pub1(&w, &.{}));
    try std.testing.expectEqual(@as(u32, 2), w.f.publish_n.load(.acquire));
    try std.testing.expectEqual(send.State.posted, (try w.row(PK)).?.state);
    var w2: W = undefined;
    try w2.init();
    defer w2.deinit();
    w2.cx.cfg.post.public = true;
    w2.f.script = &ready_soon;
    w2.f.notready_first.store(99, .release);
    try w2.pair("a", "car1", false, .{});
    try std.testing.expectEqual(exit.FAILED, pub1(&w2, &.{}));
    try std.testing.expectEqual(@as(u32, 1 + w2.cx.cfg.retry_publish), w2.f.publish_n.load(.acquire));
    try std.testing.expectEqual(send.State.failed, (try w2.row(PK)).?.state);
}

test "unclear publish answers are unsure: lost, 5xx, server error -1/2207001, unknown code; never retried by themselves" {
    const reps = [_]?fk.Rep{
        null, // answer lost (publish_drop)
        .{ .status = 503, .body = "down" },
        .{ .status = 400, .body = "{\"error\":{\"code\":-1,\"error_subcode\":2207001,\"message\":\"server\"}}" },
        .{ .status = 400, .body = "{\"error\":{\"code\":77777,\"error_subcode\":5,\"message\":\"unknown\"}}" },
        .{ .status = 200, .body = "{\"weird\":true}" },
    };
    for (reps) |rep| {
        var w: W = undefined;
        try w.init();
        defer w.deinit();
        w.cx.cfg.post.public = true;
        w.f.script = &ready_soon;
        if (rep) |r| w.f.publish_rep = r else w.f.publish_drop = true;
        try w.pair("a", "car1", false, .{});
        try std.testing.expectEqual(exit.UNSURE, pub1(&w, &.{}));
        try std.testing.expectEqual(send.State.unsure, (try w.row(PK)).?.state);
        try std.testing.expectEqual(exit.NOTHING, pub1(&w, &.{}));
        try std.testing.expectEqual(exit.UNSURE, pub1(&w, &.{ "--video", "a" }));
        try std.testing.expectEqual(@as(u32, 1), w.f.publish_n.load(.acquire));
        try std.testing.expectEqual(@as(u32, 1), w.f.container_n.load(.acquire));
    }
}

test "a failed pair: auto-pick skips it, a person retries with --again" {
    var w: W = undefined;
    try w.init();
    defer w.deinit();
    w.cx.cfg.post.public = true;
    w.f.script = &ready_soon;
    w.f.publish_rep = try errReply(100, 0, w.arena.allocator());
    try w.pair("a", "car1", false, .{});
    try std.testing.expectEqual(exit.FAILED, pub1(&w, &.{}));
    try std.testing.expectEqual(exit.NOTHING, pub1(&w, &.{}));
    try std.testing.expectEqual(exit.FAILED, pub1(&w, &.{ "--video", "a" }));
    w.f.publish_rep = null;
    w.f.status_n.store(0, .release);
    try std.testing.expectEqual(exit.OK, pub1(&w, &.{ "--video", "a", "--again" }));
    try std.testing.expectEqual(@as(i64, 2), (try w.row(PK)).?.attempts);
}

test "crash before the publish call leaves a reusable container: the next run stages it, nothing is double-sent" {
    var w: W = undefined;
    try w.init();
    defer w.deinit();
    w.f.script = &ready_soon;
    try w.pair("a", "car1", false, .{});
    w.cx.crash_at = 2; // after the upload
    try std.testing.expectEqual(@as(u8, 99), pub1(&w, &.{}));
    try std.testing.expectEqual(send.State.sending, (try w.row(PK)).?.state);
    try std.testing.expectEqual(@as(u32, 0), w.f.publish_n.load(.acquire));
    w.cx.crash_at = 0;
    w.f.status_n.store(0, .release);
    try w.pair("b", "car2", false, .{});
    try std.testing.expectEqual(exit.OK, pub1(&w, &.{})); // the other pair goes on
    try std.testing.expectEqual(send.State.staged, (try w.row(PK)).?.state); // resumed from its container
    try std.testing.expectEqual(@as(u32, 2), w.f.container_n.load(.acquire)); // one per pair, none repeated
    // crash right after the container (before the upload)
    var w1: W = undefined;
    try w1.init();
    defer w1.deinit();
    w1.f.script = &ready_soon;
    try w1.pair("a", "car1", false, .{});
    w1.cx.crash_at = 1;
    try std.testing.expectEqual(@as(u8, 99), pub1(&w1, &.{}));
    w1.cx.crash_at = 0;
    try std.testing.expectEqual(exit.NOTHING, pub1(&w1, &.{}));
    try std.testing.expectEqual(@as(u32, 0), w1.f.publish_n.load(.acquire));
}

test "crash right after the publish call is unsure after recovery; the call was counted" {
    var w: W = undefined;
    try w.init();
    defer w.deinit();
    w.cx.cfg.post.public = true;
    w.f.script = &ready_soon;
    try w.pair("a", "car1", false, .{});
    w.cx.crash_at = 3;
    try std.testing.expectEqual(@as(u8, 99), pub1(&w, &.{}));
    w.cx.crash_at = 0;
    try std.testing.expectEqual(exit.NOTHING, pub1(&w, &.{}));
    const r = (try w.row(PK)).?;
    try std.testing.expectEqual(send.State.unsure, r.state);
    try std.testing.expect(r.pub_at > 0);
    try std.testing.expectEqual(@as(u32, 1), w.f.publish_n.load(.acquire));
}

test "daily cap counts publishes; kill file and run lock stop everything" {
    var w: W = undefined;
    try w.init();
    defer w.deinit();
    w.cx.cfg.post.public = true;
    w.f.script = &ready_soon;
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
    w.f.status_n.store(0, .release);
    w.cx.fake_now_ms = realNow(&w) + 2 * 3600 * 1000; // past the gap
    try std.testing.expectEqual(exit.OK, pub1(&w, &.{}));
    try std.testing.expectEqual(@as(u32, 2), w.f.publish_n.load(.acquire));
}

test "container cap stops staged runs too" {
    var w: W = undefined;
    try w.init();
    defer w.deinit();
    w.f.script = &ready_soon;
    w.cx.cfg.limits.container_cap = 1;
    try w.pair("a", "c1", false, .{});
    try w.pair("b", "c2", false, .{});
    try std.testing.expectEqual(exit.OK, pub1(&w, &.{}));
    try std.testing.expectEqual(exit.BLOCKED, pub1(&w, &.{}));
    try std.testing.expectEqual(@as(u32, 1), w.f.container_n.load(.acquire));
}

test "Meta's own allowance: full = blocked before any container; unreadable = ledger cap still applies" {
    var w: W = undefined;
    try w.init();
    defer w.deinit();
    w.cx.cfg.post.public = true;
    w.f.script = &ready_soon;
    w.f.quota_body = "{\"data\":[{\"quota_usage\":25,\"config\":{\"quota_total\":100,\"quota_duration\":86400}}]}"; // our meta_cap 25 is the lower
    try w.pair("a", "c1", false, .{});
    try std.testing.expectEqual(exit.BLOCKED, pub1(&w, &.{}));
    try std.testing.expectEqual(@as(u32, 0), w.f.container_n.load(.acquire));
    try std.testing.expect((try w.row("c1:t1:inst-shor")) == null); // the pair stays ready
    w.f.quota_body = "{\"data\":[{\"quota_usage\":10,\"config\":{\"quota_total\":10,\"quota_duration\":86400}}]}"; // Meta's total is the lower
    w.cx.fake_now_ms = realNow(&w) + 2 * 3600 * 1000;
    try std.testing.expectEqual(exit.BLOCKED, pub1(&w, &.{}));
    w.f.quota_body = "{\"data\":[{\"quota_usage\":0,\"config\":{\"quota_total\":50,\"quota_duration\":86400}}]}";
    w.cx.fake_now_ms = realNow(&w) + 4 * 3600 * 1000;
    try std.testing.expectEqual(exit.OK, pub1(&w, &.{}));
    var w2: W = undefined;
    try w2.init();
    defer w2.deinit();
    w2.cx.cfg.post.public = true;
    w2.f.script = &ready_soon;
    w2.f.quota_rep = .{ .status = 400, .body = "{\"error\":{\"code\":100,\"message\":\"x\"}}" };
    try w2.pair("a", "c1", false, .{});
    try std.testing.expectEqual(exit.OK, pub1(&w2, &.{}));
}

test "usage near the limit blocks the next run" {
    var w: W = undefined;
    try w.init();
    defer w.deinit();
    w.f.script = &ready_soon;
    w.f.usage_hdr = "X-App-Usage: {\"call_count\":95,\"total_time\":10,\"total_cputime\":1}\r\n";
    try w.pair("a", "c1", false, .{});
    try w.pair("b", "c2", false, .{});
    try std.testing.expectEqual(exit.BLOCKED, pub1(&w, &.{})); // stopped before any byte went up
    try std.testing.expectEqual(@as(u32, 0), w.f.upload_n.load(.acquire));
    try std.testing.expect((try w.row("c1:t1:inst-shor")) == null);
    w.f.usage_hdr = "";
    try std.testing.expectEqual(exit.BLOCKED, pub1(&w, &.{})); // the stop is remembered
    w.cx.fake_now_ms = realNow(&w) + 2 * 3600 * 1000;
    try std.testing.expectEqual(exit.OK, pub1(&w, &.{}));
}

test "5xx on the container is retried then gives up without a ledger row" {
    var w: W = undefined;
    try w.init();
    defer w.deinit();
    w.f.container_rep = .{ .status = 503, .body = "down" };
    try w.pair("a", "c1", false, .{});
    try std.testing.expectEqual(exit.FAILED, pub1(&w, &.{}));
    try std.testing.expectEqual(@as(u32, 1 + w.cx.cfg.retry_pre_send), w.f.container_n.load(.acquire));
    try std.testing.expect((try w.row("c1:t1:inst-shor")) == null);
}

test "breaker opens after N failures and holds across a restart" {
    var w: W = undefined;
    try w.init();
    defer w.deinit();
    w.cx.cfg.post.public = true;
    w.f.script = &ready_soon;
    w.f.publish_rep = try errReply(100, 0, w.arena.allocator());
    w.cx.cfg.breaker.fails = 2;
    try w.pair("a", "c1", false, .{});
    try w.pair("b", "c2", false, .{});
    try w.pair("c", "c3", false, .{});
    try std.testing.expectEqual(exit.FAILED, pub1(&w, &.{}));
    try std.testing.expectEqual(exit.FAILED, pub1(&w, &.{}));
    const n = w.f.container_n.load(.acquire);
    try std.testing.expectEqual(exit.BLOCKED, pub1(&w, &.{}));
    try std.testing.expectEqual(n, w.f.container_n.load(.acquire));
}

test "upload streams: 200 MB file, memory stays flat" {
    var w: W = undefined;
    try w.init();
    defer w.deinit();
    const a = w.arena.allocator();
    const big = try std.fmt.allocPrint(a, "{s}/big.bin", .{w.src});
    var f = try Io.Dir.cwd().createFile(w.cx.io, big, .{ .truncate = true, .read = true });
    try f.setLength(w.cx.io, 200 * 1024 * 1024);
    f.close(w.cx.io);
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/rupload/ig-api-upload/v27.0/9876543210", .{w.f.port});
    const r = up.upload(&w.cx, ar.allocator(), "TESTTOKEN", url, big, 200 * 1024 * 1024, 0);
    try std.testing.expect(r == .ok);
    try std.testing.expectEqual(@as(u64, 200 * 1024 * 1024), w.f.have.load(.acquire));
    try std.testing.expect(ar.queryCapacity() < 4 * 1024 * 1024);
}

test "190 at the container does not burn the pair; it stays ready and the run is blocked" {
    var w: W = undefined;
    try w.init();
    defer w.deinit();
    w.f.container_rep = try errReply(190, 0, w.arena.allocator());
    try w.pair("a", "c1", false, .{});
    try std.testing.expectEqual(exit.BLOCKED, pub1(&w, &.{}));
    try std.testing.expect((try w.row("c1:t1:inst-shor")) == null);
    w.f.container_rep = null;
    w.f.script = &ready_soon;
    try std.testing.expectEqual(exit.OK, pub1(&w, &.{})); // token fixed: the same pair goes out
}

test "an error body that echoes a token or has odd UTF-8 never reaches the ledger or output raw" {
    var w: W = undefined;
    try w.init();
    defer w.deinit();
    w.cx.cfg.post.public = true;
    w.f.script = &ready_soon;
    w.f.publish_rep = .{ .status = 400, .body = "{\"error\":{\"code\":100,\"message\":\"bad access_token=SEKRET9 and \\\"token\\\":\\\"SEKRET8\\\" " ++ "\xe1\xbb\x87" ** 150 ++ "\"}}" };
    try w.pair("a", "c1", false, .{});
    try std.testing.expectEqual(exit.FAILED, pub1(&w, &.{}));
    const r = (try w.row("c1:t1:inst-shor")).?;
    try std.testing.expect(std.mem.indexOf(u8, r.note, "SEKRET9") == null);
    try std.testing.expect(std.unicode.utf8ValidateSlice(r.note));
    const lp = try w.cx.dataPath(w.arena.allocator(), "run.jsonl");
    const lt = try util.readAll(w.arena.allocator(), w.cx.io, lp, 1 << 20);
    try std.testing.expect(std.mem.indexOf(u8, lt, "TESTTOKEN") == null);
    try std.testing.expect(std.mem.indexOf(u8, lt, "SEKRET9") == null);
}

test "a missing ledger next to old files is refused (wrong folder)" {
    var w: W = undefined;
    try w.init();
    defer w.deinit();
    w.f.script = &ready_soon;
    try w.pair("a", "c1", false, .{});
    try std.testing.expectEqual(exit.OK, pub1(&w, &.{}));
    const lp = try send.dbPath(&w.cx, w.arena.allocator());
    const moved = try std.fmt.allocPrint(w.arena.allocator(), "{s}.moved", .{lp});
    try Io.Dir.cwd().rename(lp, Io.Dir.cwd(), moved, w.cx.io);
    try std.testing.expectEqual(exit.BLOCKED, pub1(&w, &.{}));
    try std.testing.expectEqual(@as(u32, 1), w.f.container_n.load(.acquire));
}

test "the mp4 changing during upload stops before publish" {
    var w: W = undefined;
    try w.init();
    defer w.deinit();
    w.cx.cfg.post.public = true;
    w.f.script = &ready_soon;
    try w.pair("a", "c1", false, .{ .mdat_mb = 1 });
    const mp = try std.fmt.allocPrint(w.arena.allocator(), "{s}/a.mp4", .{w.src});
    w.f.on_upload = mp;
    try std.testing.expectEqual(exit.FAILED, pub1(&w, &.{}));
    try std.testing.expectEqual(@as(u32, 0), w.f.publish_n.load(.acquire));
    try std.testing.expectEqual(send.State.failed, (try w.row("c1:t1:inst-shor")).?.state);
}

test "--again still counts the earlier publish call toward the cap" {
    var w: W = undefined;
    try w.init();
    defer w.deinit();
    w.cx.cfg.post.public = true;
    w.f.script = &ready_soon;
    w.cx.cfg.limits.daily_cap = 2;
    w.f.publish_rep = try errReply(100, 0, w.arena.allocator());
    try w.pair("a", "c1", false, .{});
    try std.testing.expectEqual(exit.FAILED, pub1(&w, &.{ "--video", "a" }));
    w.f.status_n.store(0, .release);
    try std.testing.expectEqual(exit.FAILED, pub1(&w, &.{ "--video", "a", "--again" }));
    try std.testing.expectEqual(exit.BLOCKED, pub1(&w, &.{ "--video", "a", "--again" })); // two publish calls went out: cap 2 reached
    try std.testing.expectEqual(@as(u32, 2), w.f.publish_n.load(.acquire));
}

test "--video with no value is a usage error, not 'the oldest'" {
    var w: W = undefined;
    try w.init();
    defer w.deinit();
    try w.pair("a", "c1", false, .{});
    try std.testing.expectEqual(exit.USAGE, pub1(&w, &.{"--video"}));
    try std.testing.expectEqual(@as(u32, 0), w.f.container_n.load(.acquire));
}
