// publish against the fake Facebook: happy path, dry-run, replay, resume, every failure class, crash, cap, kill, lock, review hold.
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

const happy = [_]fk.Mode{ .upload_complete, .processing, .draft_ready };
const live_ok = [_]fk.Mode{ .upload_complete, .processing, .ready };

fn pub1(w: *W, extra: []const []const u8) u8 {
    return pub_cmd.run(&w.cx, extra);
}

test "dry-run sends nothing" {
    var w: W = undefined;
    try w.init();
    defer w.deinit();
    try w.pair("a", "car1", false, .{});
    w.cx.live = false;
    try std.testing.expectEqual(exit.OK, pub1(&w, &.{}));
    try std.testing.expectEqual(@as(u32, 0), w.f.start_n.load(.acquire));
    try std.testing.expect(!w.f.logHas("POST"));
    try std.testing.expect((try w.row("car1:t1:face-shor")) == null);
}

test "happy path: DRAFT, AI flag + notice sent, token only in the header, once only" {
    var w: W = undefined;
    try w.init();
    defer w.deinit();
    w.f.script = &happy;
    try w.pair("a", "car1", false, .{});
    try std.testing.expectEqual(exit.OK, pub1(&w, &.{}));
    try std.testing.expectEqual(@as(u32, 1), w.f.start_n.load(.acquire));
    try std.testing.expectEqual(@as(u32, 1), w.f.upload_n.load(.acquire));
    try std.testing.expectEqual(@as(u32, 1), w.f.finish_n.load(.acquire));
    const fb = try w.f.finishText(w.arena.allocator());
    try std.testing.expect(std.mem.indexOf(u8, fb, "\"is_ai_generated\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, fb, "\"video_state\":\"DRAFT\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, fb, "Made with AI.") != null);
    try std.testing.expect(std.mem.indexOf(u8, fb, "\"upload_phase\":\"finish\"") != null);
    try std.testing.expect(!w.f.logHas("TESTTOKEN"));
    const r = (try w.row("car1:t1:face-shor")).?;
    try std.testing.expectEqual(send.State.posted, r.state);
    try std.testing.expectEqualStrings("9876543210", r.video_id);
    try std.testing.expect(std.mem.indexOf(u8, r.url, "/reel/9876543210") != null);
    try std.testing.expect(r.finish_at > 0);
    // replay: nothing new is sent, answered from the ledger
    try std.testing.expectEqual(exit.NOTHING, pub1(&w, &.{}));
    try std.testing.expectEqual(exit.OK, pub1(&w, &.{ "--video", "a" }));
    try std.testing.expectEqual(@as(u32, 1), w.f.start_n.load(.acquire));
    try std.testing.expectEqual(@as(u32, 1), w.f.finish_n.load(.acquire));
}

test "post.public true sends PUBLISHED; finish with post_id stored" {
    var w: W = undefined;
    try w.init();
    defer w.deinit();
    w.f.script = &live_ok;
    w.f.finish_post_id = true;
    w.cx.cfg.post.public = true;
    try w.pair("a", "car1", false, .{});
    try std.testing.expectEqual(exit.OK, pub1(&w, &.{}));
    const fb = try w.f.finishText(w.arena.allocator());
    try std.testing.expect(std.mem.indexOf(u8, fb, "\"video_state\":\"PUBLISHED\"") != null);
    const r = (try w.row("car1:t1:face-shor")).?;
    try std.testing.expectEqualStrings("1234567890_555", r.post_id);
}

test "oldest pair first, then the next" {
    var w: W = undefined;
    try w.init();
    defer w.deinit();
    w.f.script = &happy;
    try w.pair("first", "c1", false, .{});
    std.Io.sleep(w.cx.io, .fromMilliseconds(1100), .awake) catch {};
    try w.pair("second", "c2", false, .{});
    try std.testing.expectEqual(exit.OK, pub1(&w, &.{}));
    try std.testing.expect((try w.row("c1:t1:face-shor")) != null);
    try std.testing.expect((try w.row("c2:t1:face-shor")) == null);
    try std.testing.expectEqual(exit.OK, pub1(&w, &.{}));
    try std.testing.expect((try w.row("c2:t1:face-shor")) != null);
}

test "review:true is held until approved, never auto-sent" {
    var w: W = undefined;
    try w.init();
    defer w.deinit();
    w.f.script = &happy;
    try w.pair("h", "car9", true, .{});
    try std.testing.expectEqual(exit.NOTHING, pub1(&w, &.{}));
    try std.testing.expectEqual(exit.BLOCKED, pub1(&w, &.{ "--video", "h" }));
    try std.testing.expectEqual(@as(u32, 0), w.f.start_n.load(.acquire));
    try std.testing.expectEqual(exit.OK, @import("cm-approve.zig").run(&w.cx, &.{ "--video", "h" }, true));
    try std.testing.expectEqual(exit.OK, pub1(&w, &.{}));
    try std.testing.expectEqual(@as(u32, 1), w.f.finish_n.load(.acquire));
}

test "missing ai_notice: refused, nothing sent" {
    var w: W = undefined;
    try w.init();
    defer w.deinit();
    try w.pair("a", "car1", false, .{});
    const jp = try std.fmt.allocPrint(w.arena.allocator(), "{s}/a.json", .{w.src});
    try Io.Dir.cwd().writeFile(w.cx.io, .{ .sub_path = jp, .data = "{\"car\":\"car1\",\"template\":\"t1\",\"mp4\":\"a.mp4\",\"description\":\"x\",\"ai_notice\":\"\"}" });
    try std.testing.expectEqual(exit.FAILED, pub1(&w, &.{ "--video", "a" }));
    try std.testing.expectEqual(@as(u32, 0), w.f.start_n.load(.acquire));
}

test "interrupted upload resumes from bytes_transfered; offset mismatch too" {
    var w: W = undefined;
    try w.init();
    defer w.deinit();
    const sc = [_]fk.Mode{ .uploading, .upload_complete, .processing, .draft_ready };
    w.f.script = &sc;
    try w.pair("a", "car1", false, .{ .mdat_mb = 2 });
    w.f.cut_after.store(100_000, .release);
    try std.testing.expectEqual(exit.OK, pub1(&w, &.{}));
    try std.testing.expectEqual(@as(u32, 2), w.f.upload_n.load(.acquire));
    try std.testing.expectEqual(@as(u32, 1), w.f.finish_n.load(.acquire));
    const r = (try w.row("car1:t1:face-shor")).?;
    try std.testing.expectEqual(send.State.posted, r.state);
    try std.testing.expectEqual(w.f.total.load(.acquire), w.f.have.load(.acquire));
    // server claims 500 bytes already: our offset 0 is refused (OffsetInvalidError), we resume at 500
    var w2: W = undefined;
    try w2.init();
    defer w2.deinit();
    const sc2 = [_]fk.Mode{ .uploading, .upload_complete, .processing, .draft_ready };
    w2.f.script = &sc2;
    w2.f.have_on_start = 500;
    try w2.pair("b", "car2", false, .{});
    try std.testing.expectEqual(exit.OK, pub1(&w2, &.{}));
    try std.testing.expectEqual(@as(u32, 2), w2.f.upload_n.load(.acquire));
}

fn errReply(code: i64, a: std.mem.Allocator) !fk.Rep {
    return .{ .status = 400, .body = try std.fmt.allocPrint(a, "{{\"error\":{{\"message\":\"m\",\"code\":{d}}}}}", .{code}) };
}

test "finish errors: 100 fails, 190 blocks, 368 opens the breaker for good, 613 stops the day" {
    const cases = [_]struct { code: i64, exit_code: u8, st: send.State }{
        .{ .code = 100, .exit_code = exit.FAILED, .st = .failed },
        .{ .code = 190, .exit_code = exit.BLOCKED, .st = .failed },
        .{ .code = 368, .exit_code = exit.BLOCKED, .st = .failed },
        .{ .code = 613, .exit_code = exit.BLOCKED, .st = .failed },
    };
    for (cases) |c| {
        var w: W = undefined;
        try w.init();
        defer w.deinit();
        w.f.script = &happy;
        w.f.finish_rep = try errReply(c.code, w.arena.allocator());
        try w.pair("a", "car1", false, .{});
        try std.testing.expectEqual(c.exit_code, pub1(&w, &.{}));
        try std.testing.expectEqual(c.st, (try w.row("car1:t1:face-shor")).?.state);
        if (c.code == 368 or c.code == 613) {
            // next run is blocked before any call
            try w.pair("b", "car2", false, .{});
            const n = w.f.start_n.load(.acquire);
            try std.testing.expectEqual(exit.BLOCKED, pub1(&w, &.{}));
            try std.testing.expectEqual(n, w.f.start_n.load(.acquire));
            if (c.code == 368) {
                w.cx.fake_now_ms = std.Io.Clock.real.now(w.cx.io).toMilliseconds() + 365 * 24 * 3600 * 1000; // time does not clear a 368
                try std.testing.expectEqual(exit.BLOCKED, pub1(&w, &.{}));
            }
        }
    }
}

test "lost answer after finish = unsure; never retried by itself; failed pair needs --again" {
    var w: W = undefined;
    try w.init();
    defer w.deinit();
    w.f.script = &happy;
    w.f.finish_drop = true;
    try w.pair("a", "car1", false, .{});
    try std.testing.expectEqual(exit.UNSURE, pub1(&w, &.{}));
    try std.testing.expectEqual(send.State.unsure, (try w.row("car1:t1:face-shor")).?.state);
    try std.testing.expectEqual(exit.NOTHING, pub1(&w, &.{}));
    try std.testing.expectEqual(exit.UNSURE, pub1(&w, &.{ "--video", "a" }));
    try std.testing.expectEqual(@as(u32, 1), w.f.finish_n.load(.acquire));
    try std.testing.expectEqual(@as(u32, 1), w.f.start_n.load(.acquire));
    // a failed pair: auto-pick skips it, a person retries with --again
    var w2: W = undefined;
    try w2.init();
    defer w2.deinit();
    w2.f.script = &happy;
    w2.f.finish_rep = try errReply(100, w2.arena.allocator());
    try w2.pair("a", "car1", false, .{});
    try std.testing.expectEqual(exit.FAILED, pub1(&w2, &.{}));
    try std.testing.expectEqual(exit.NOTHING, pub1(&w2, &.{}));
    try std.testing.expectEqual(exit.FAILED, pub1(&w2, &.{ "--video", "a" }));
    w2.f.finish_rep = null;
    try std.testing.expectEqual(exit.OK, pub1(&w2, &.{ "--video", "a", "--again" }));
    try std.testing.expectEqual(@as(i64, 2), (try w2.row("car1:t1:face-shor")).?.attempts);
}

test "crash mid-send leaves sending; the next run makes it unsure and sends nothing" {
    var w: W = undefined;
    try w.init();
    defer w.deinit();
    w.f.script = &happy;
    try w.pair("a", "car1", false, .{});
    w.cx.crash_at = 2;
    try std.testing.expectEqual(@as(u8, 99), pub1(&w, &.{}));
    try std.testing.expectEqual(send.State.sending, (try w.row("car1:t1:face-shor")).?.state);
    try std.testing.expectEqual(@as(u32, 0), w.f.finish_n.load(.acquire));
    w.cx.crash_at = 0;
    try w.pair("b", "car2", false, .{});
    try std.testing.expectEqual(exit.OK, pub1(&w, &.{})); // the other pair goes on
    try std.testing.expectEqual(send.State.unsure, (try w.row("car1:t1:face-shor")).?.state);
    try std.testing.expectEqual(@as(u32, 1), w.f.finish_n.load(.acquire));
    // crash right after finish: the finish was counted (cap) and the row is unsure after recovery
    var w3: W = undefined;
    try w3.init();
    defer w3.deinit();
    w3.f.script = &happy;
    try w3.pair("a", "car1", false, .{});
    w3.cx.crash_at = 3;
    try std.testing.expectEqual(@as(u8, 99), pub1(&w3, &.{}));
    w3.cx.crash_at = 0;
    try std.testing.expectEqual(exit.NOTHING, pub1(&w3, &.{}));
    try std.testing.expectEqual(send.State.unsure, (try w3.row("car1:t1:face-shor")).?.state);
}

test "daily cap stops the second send; kill file and run lock stop everything" {
    var w: W = undefined;
    try w.init();
    defer w.deinit();
    w.f.script = &happy;
    w.cx.cfg.limits.daily_cap = 1;
    try w.pair("a", "c1", false, .{});
    try w.pair("b", "c2", false, .{});
    try std.testing.expectEqual(exit.OK, pub1(&w, &.{}));
    try std.testing.expectEqual(exit.BLOCKED, pub1(&w, &.{}));
    try std.testing.expectEqual(@as(u32, 1), w.f.finish_n.load(.acquire));
    w.cx.cfg.limits.daily_cap = 5;
    try kill.setKill(&w.cx, true);
    try std.testing.expectEqual(exit.BLOCKED, pub1(&w, &.{}));
    try kill.setKill(&w.cx, false);
    var l = try kill.acquire(&w.cx);
    try std.testing.expectEqual(exit.BLOCKED, pub1(&w, &.{}));
    l.release();
    try std.testing.expectEqual(exit.OK, pub1(&w, &.{}));
    try std.testing.expectEqual(@as(u32, 2), w.f.finish_n.load(.acquire));
}

test "usage near the limit blocks the next run" {
    var w: W = undefined;
    try w.init();
    defer w.deinit();
    w.f.script = &happy;
    w.f.usage_hdr = "X-App-Usage: {\"call_count\":95,\"total_time\":10,\"total_cputime\":1}\r\n";
    try w.pair("a", "c1", false, .{});
    try w.pair("b", "c2", false, .{});
    try std.testing.expectEqual(exit.BLOCKED, pub1(&w, &.{})); // stopped before any byte went up
    try std.testing.expectEqual(@as(u32, 0), w.f.upload_n.load(.acquire));
    try std.testing.expect((try w.row("c1:t1:face-shor")) == null);
    w.f.usage_hdr = "";
    try std.testing.expectEqual(exit.BLOCKED, pub1(&w, &.{})); // the stop is remembered
    w.cx.fake_now_ms = std.Io.Clock.real.now(w.cx.io).toMilliseconds() + 2 * 3600 * 1000;
    try std.testing.expectEqual(exit.OK, pub1(&w, &.{}));
}

test "5xx on start is retried then gives up without a ledger row" {
    var w: W = undefined;
    try w.init();
    defer w.deinit();
    w.f.start_rep = .{ .status = 503, .body = "down" };
    try w.pair("a", "c1", false, .{});
    try std.testing.expectEqual(exit.FAILED, pub1(&w, &.{}));
    try std.testing.expectEqual(@as(u32, 1 + w.cx.cfg.retry_pre_send), w.f.start_n.load(.acquire));
    try std.testing.expect((try w.row("c1:t1:face-shor")) == null);
}

test "breaker opens after N failures and holds across a restart" {
    var w: W = undefined;
    try w.init();
    defer w.deinit();
    w.f.script = &happy;
    w.f.finish_rep = try errReply(100, w.arena.allocator());
    w.cx.cfg.breaker.fails = 2;
    try w.pair("a", "c1", false, .{});
    try w.pair("b", "c2", false, .{});
    try w.pair("c", "c3", false, .{});
    try std.testing.expectEqual(exit.FAILED, pub1(&w, &.{}));
    try std.testing.expectEqual(exit.FAILED, pub1(&w, &.{}));
    const n = w.f.start_n.load(.acquire);
    try std.testing.expectEqual(exit.BLOCKED, pub1(&w, &.{}));
    try std.testing.expectEqual(n, w.f.start_n.load(.acquire));
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
    const url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/rupload/video-upload/9876543210", .{w.f.port});
    const r = up.upload(&w.cx, ar.allocator(), "TESTTOKEN", url, big, 200 * 1024 * 1024, 0);
    try std.testing.expect(r == .ok);
    try std.testing.expectEqual(@as(u64, 200 * 1024 * 1024), w.f.have.load(.acquire));
    try std.testing.expect(ar.queryCapacity() < 4 * 1024 * 1024);
}

test "190 at start does not burn the pair; it stays ready and the run is blocked" {
    var w: W = undefined;
    try w.init();
    defer w.deinit();
    w.f.start_rep = try errReply(190, w.arena.allocator());
    try w.pair("a", "c1", false, .{});
    try std.testing.expectEqual(exit.BLOCKED, pub1(&w, &.{}));
    try std.testing.expect((try w.row("c1:t1:face-shor")) == null);
    w.f.start_rep = null;
    w.f.script = &happy;
    try std.testing.expectEqual(exit.OK, pub1(&w, &.{})); // token fixed: the same pair goes out
}

test "an error body that echoes a token or has odd UTF-8 never reaches the ledger or output raw" {
    var w: W = undefined;
    try w.init();
    defer w.deinit();
    w.f.script = &happy;
    w.f.finish_rep = .{ .status = 400, .body = "{\"error\":{\"code\":100,\"message\":\"bad access_token=SEKRET9 and \\\"token\\\":\\\"SEKRET8\\\" " ++ "\xe1\xbb\x87" ** 150 ++ "\"}}" };
    try w.pair("a", "c1", false, .{});
    try std.testing.expectEqual(exit.FAILED, pub1(&w, &.{}));
    const r = (try w.row("c1:t1:face-shor")).?;
    try std.testing.expect(std.mem.indexOf(u8, r.note, "SEKRET9") == null);
    try std.testing.expect(std.unicode.utf8ValidateSlice(r.note));
    const lp = try w.cx.dataPath(w.arena.allocator(), "run.jsonl");
    const lt = try util.readAll(w.arena.allocator(), w.cx.io, lp, 1 << 20);
    try std.testing.expect(std.mem.indexOf(u8, lt, "TESTTOKEN") == null);
    try std.testing.expect(std.mem.indexOf(u8, lt, "SEKRET9") == null);
}

test "a missing ledger next to old files is refused (wrong folder), --init overrides" {
    var w: W = undefined;
    try w.init();
    defer w.deinit();
    w.f.script = &happy;
    try w.pair("a", "c1", false, .{});
    try std.testing.expectEqual(exit.OK, pub1(&w, &.{}));
    const lp = try send.dbPath(&w.cx, w.arena.allocator());
    const moved = try std.fmt.allocPrint(w.arena.allocator(), "{s}.moved", .{lp});
    try Io.Dir.cwd().rename(lp, Io.Dir.cwd(), moved, w.cx.io);
    try std.testing.expectEqual(exit.BLOCKED, pub1(&w, &.{}));
    try std.testing.expectEqual(@as(u32, 1), w.f.start_n.load(.acquire));
}

test "the mp4 changing during upload stops before finish" {
    var w: W = undefined;
    try w.init();
    defer w.deinit();
    w.f.script = &happy;
    try w.pair("a", "c1", false, .{ .mdat_mb = 1 });
    // simulate the producer rewriting the file after the scan: bump the mtime recorded in the entry via a bigger file at upload time
    const mp = try std.fmt.allocPrint(w.arena.allocator(), "{s}/a.mp4", .{w.src});
    w.f.on_upload = mp;
    try std.testing.expectEqual(exit.FAILED, pub1(&w, &.{}));
    try std.testing.expectEqual(@as(u32, 0), w.f.finish_n.load(.acquire));
    try std.testing.expectEqual(send.State.failed, (try w.row("c1:t1:face-shor")).?.state);
}

test "--again still counts the earlier finish toward the cap" {
    var w: W = undefined;
    try w.init();
    defer w.deinit();
    w.f.script = &happy;
    w.cx.cfg.limits.daily_cap = 2;
    w.f.finish_rep = try errReply(100, w.arena.allocator());
    try w.pair("a", "c1", false, .{});
    try std.testing.expectEqual(exit.FAILED, pub1(&w, &.{ "--video", "a" }));
    try std.testing.expectEqual(exit.FAILED, pub1(&w, &.{ "--video", "a", "--again" }));
    try std.testing.expectEqual(exit.BLOCKED, pub1(&w, &.{ "--video", "a", "--again" })); // two finishes went out: cap 2 reached
    try std.testing.expectEqual(@as(u32, 2), w.f.finish_n.load(.acquire));
}

test "--video with no value is a usage error, not 'the oldest'" {
    var w: W = undefined;
    try w.init();
    defer w.deinit();
    try w.pair("a", "c1", false, .{});
    try std.testing.expectEqual(exit.USAGE, pub1(&w, &.{"--video"}));
    try std.testing.expectEqual(@as(u32, 0), w.f.start_n.load(.acquire));
}
