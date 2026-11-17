// The other commands against the fake: resolve, approve/hold, token, doctor, scan, status, kill, backup, config, dispatch.
const std = @import("std");
const Io = std.Io;
const W = @import("te-world.zig").World;
const fk = @import("te-fake-graph.zig");
const main = @import("main.zig");
const exit = @import("co-exit.zig");
const send = @import("rw-send.zig");
const pub_cmd = @import("cm-publish.zig");
const util = @import("co-util.zig");

const ready_soon = [_]fk.Mode{ .in_progress, .finished };
const PK = "car1:t1:inst-shor";

fn d(w: *W, av: []const []const u8) u8 {
    return main.dispatch(&w.cx, av);
}

// a send whose publish answer was lost: state unsure
fn unsureWorld(w: *W) !void {
    try w.init();
    w.cx.cfg.post.public = true;
    w.f.script = &ready_soon;
    w.f.publish_drop = true;
    try w.pair("a", "car1", false, .{});
    try std.testing.expectEqual(exit.UNSURE, pub_cmd.run(&w.cx, &.{}));
    w.f.publish_drop = false;
}

fn askAgain(w: *W, mode: fk.Mode) void {
    const S = struct {
        const a = [_]fk.Mode{.in_progress};
        const b = [_]fk.Mode{.finished};
        const c = [_]fk.Mode{.published};
        const d = [_]fk.Mode{.error_code};
        const e = [_]fk.Mode{.expired};
    };
    w.f.script = switch (mode) {
        .in_progress => &S.a,
        .finished => &S.b,
        .published => &S.c,
        .error_code => &S.d,
        .expired => &S.e,
    };
    w.f.status_n.store(0, .release);
}

test "resolve: container PUBLISHED + one new Reel in the list -> posted with its media id, never re-sends" {
    var w: W = undefined;
    try unsureWorld(&w);
    defer w.deinit();
    askAgain(&w, .published);
    w.f.list_body = "{\"data\":[{\"id\":\"17900009\",\"media_product_type\":\"REELS\",\"caption\":\"x\"}]}";
    w.cx.live = false;
    try std.testing.expectEqual(exit.OK, d(&w, &.{ "resolve", "--video", "a" }));
    try std.testing.expectEqual(send.State.unsure, (try w.row(PK)).?.state); // dry-run wrote nothing
    w.cx.live = true;
    try std.testing.expectEqual(exit.OK, d(&w, &.{ "resolve", "--video", "a" }));
    const r = (try w.row(PK)).?;
    try std.testing.expectEqual(send.State.posted, r.state);
    try std.testing.expectEqualStrings("17900009", r.media_id);
    try std.testing.expectEqual(@as(u32, 1), w.f.publish_n.load(.acquire));
    try std.testing.expectEqual(@as(u32, 1), w.f.container_n.load(.acquire));
}

test "resolve: PUBLISHED but no single new Reel -> still posted (the container is the proof), id left empty; rejected fields fall back to ids" {
    var w: W = undefined;
    try unsureWorld(&w);
    defer w.deinit();
    askAgain(&w, .published);
    w.f.list_body = "{\"data\":[]}";
    try std.testing.expectEqual(exit.OK, d(&w, &.{ "resolve", "--video", "a" }));
    const r = (try w.row(PK)).?;
    try std.testing.expectEqual(send.State.posted, r.state);
    try std.testing.expectEqualStrings("", r.media_id);
    var w2: W = undefined;
    try unsureWorld(&w2);
    defer w2.deinit();
    askAgain(&w2, .published);
    w2.f.list_reject_fields = true; // Meta rejects the extra fields: ids only
    w2.f.list_body = "{\"data\":[{\"id\":\"17900010\"}]}";
    try std.testing.expectEqual(exit.OK, d(&w2, &.{ "resolve", "--video", "a" }));
    try std.testing.expectEqualStrings("17900010", (try w2.row(PK)).?.media_id);
}

test "resolve: after a publish call FINISHED/EXPIRED/IN_PROGRESS stay unsure; only PUBLISHED or ERROR settle" {
    var w: W = undefined;
    try unsureWorld(&w);
    defer w.deinit();
    askAgain(&w, .in_progress);
    try std.testing.expectEqual(exit.UNSURE, d(&w, &.{ "resolve", "--video", "a" }));
    try std.testing.expectEqual(send.State.unsure, (try w.row(PK)).?.state);
    askAgain(&w, .finished); // a publish call WAS sent: FINISHED cannot prove "not published" (slow publish vs lost) -> stays unsure
    try std.testing.expectEqual(exit.UNSURE, d(&w, &.{ "resolve", "--video", "a" }));
    try std.testing.expectEqual(send.State.unsure, (try w.row(PK)).?.state);
    askAgain(&w, .expired);
    try std.testing.expectEqual(exit.UNSURE, d(&w, &.{ "resolve", "--video", "a" }));
    try std.testing.expectEqual(send.State.unsure, (try w.row(PK)).?.state);
    var w2: W = undefined;
    try unsureWorld(&w2);
    defer w2.deinit();
    askAgain(&w2, .error_code);
    try std.testing.expectEqual(exit.OK, d(&w2, &.{ "resolve", "--video", "a" }));
    try std.testing.expectEqual(send.State.failed, (try w2.row(PK)).?.state);
}

test "resolve: a person can answer with --as; a settled row is left alone" {
    var w: W = undefined;
    try unsureWorld(&w);
    defer w.deinit();
    try std.testing.expectEqual(exit.USAGE, d(&w, &.{ "resolve", "--video", "a", "--as", "maybe" }));
    try std.testing.expectEqual(send.State.unsure, (try w.row(PK)).?.state);
    try std.testing.expectEqual(exit.OK, d(&w, &.{ "resolve", "--video", "a", "--as", "failed" }));
    try std.testing.expectEqual(send.State.failed, (try w.row(PK)).?.state);
    try std.testing.expectEqual(exit.OK, d(&w, &.{ "resolve", "--video", "a" }));
    try std.testing.expectEqual(exit.FAILED, d(&w, &.{ "resolve", "--video", "nope" }));
}

test "approve and hold write only with --live" {
    var w: W = undefined;
    try w.init();
    defer w.deinit();
    try w.pair("h", "car9", true, .{});
    w.cx.live = false;
    try std.testing.expectEqual(exit.OK, d(&w, &.{ "approve", "--video", "h" }));
    try std.testing.expectEqual(exit.NOTHING, pub_cmd.run(&w.cx, &.{}));
    w.cx.live = true;
    try std.testing.expectEqual(exit.OK, d(&w, &.{ "approve", "--video", "h" }));
    w.f.script = &ready_soon;
    try std.testing.expectEqual(exit.OK, pub_cmd.run(&w.cx, &.{}));
    var w2: W = undefined;
    try w2.init();
    defer w2.deinit();
    try w2.pair("h", "car9", true, .{});
    try std.testing.expectEqual(exit.OK, d(&w2, &.{ "approve", "--video", "h" }));
    try std.testing.expectEqual(exit.OK, d(&w2, &.{ "hold", "--video", "h" }));
    try std.testing.expectEqual(exit.NOTHING, pub_cmd.run(&w2.cx, &.{}));
    try std.testing.expectEqual(exit.USAGE, d(&w2, &.{"approve"}));
}

test "token: works for the account; a different account, a dead token, a missing secret" {
    var w: W = undefined;
    try w.init();
    defer w.deinit();
    try std.testing.expectEqual(exit.OK, d(&w, &.{"token"}));
    // no token ever rides in a URL: our own log and the fake's request log are clean
    try std.testing.expect(!w.f.logHas("TESTTOKEN"));
    try std.testing.expect(!w.f.logHas("access_token"));
    const lp = try w.cx.dataPath(w.arena.allocator(), "run.jsonl");
    if (util.exists(w.cx.io, lp)) {
        const lt = try util.readAll(w.arena.allocator(), w.cx.io, lp, 1 << 20);
        try std.testing.expect(std.mem.indexOf(u8, lt, "TESTTOKEN") == null);
    }
    w.f.ig_id = "999"; // the token answers for another account than the configured one
    try std.testing.expectEqual(exit.BLOCKED, d(&w, &.{"token"}));
    w.f.ig_id = "1784140000";
    w.f.token = "OTHER"; // Meta says the token is not valid
    try std.testing.expectEqual(exit.BLOCKED, d(&w, &.{"token"}));
    try w.env.put("INST_SHOR_TOKEN", "");
    try std.testing.expectEqual(exit.USAGE, d(&w, &.{"token"}));
}

test "doctor, scan, status, kill, backup, config" {
    var w: W = undefined;
    try w.init();
    defer w.deinit();
    w.f.script = &ready_soon;
    try w.pair("a", "car1", false, .{});
    try std.testing.expectEqual(exit.OK, d(&w, &.{"doctor"}));
    try std.testing.expect(w.f.quota_n.load(.acquire) >= 1); // doctor reads Meta's allowance
    try std.testing.expectEqual(exit.OK, d(&w, &.{"scan"}));
    try std.testing.expectEqual(exit.OK, d(&w, &.{"status"})); // no ledger yet
    try std.testing.expectEqual(exit.OK, pub_cmd.run(&w.cx, &.{}));
    try std.testing.expectEqual(exit.OK, d(&w, &.{"status"}));
    const q0 = w.f.quota_n.load(.acquire);
    try std.testing.expectEqual(exit.OK, d(&w, &.{ "status", "--verify" }));
    try std.testing.expect(w.f.quota_n.load(.acquire) > q0);
    // kill: on needs no --live, off needs it
    w.cx.live = false;
    try std.testing.expectEqual(exit.OK, d(&w, &.{ "kill", "--on" }));
    w.cx.live = true;
    try std.testing.expectEqual(exit.BLOCKED, pub_cmd.run(&w.cx, &.{}));
    try std.testing.expectEqual(exit.BLOCKED, d(&w, &.{"backup"}));
    w.cx.live = false;
    try std.testing.expectEqual(exit.OK, d(&w, &.{ "kill", "--off" }));
    w.cx.live = true;
    try std.testing.expectEqual(exit.OK, d(&w, &.{ "kill", "--off" }));
    try std.testing.expectEqual(exit.OK, d(&w, &.{"backup"}));
    try std.testing.expectEqual(exit.OK, d(&w, &.{"config"}));
    try std.testing.expectEqual(exit.OK, d(&w, &.{ "config", "--reset-breaker" }));
    try std.testing.expectEqual(exit.USAGE, d(&w, &.{"nonsense"}));
    try std.testing.expectEqual(exit.USAGE, d(&w, &.{}));
    // the backup opens and holds the posted row
    var found = false;
    const bdir = try w.cx.dataPath(w.arena.allocator(), "backup");
    var dir = try Io.Dir.cwd().openDir(w.cx.io, bdir, .{ .iterate = true });
    defer dir.close(w.cx.io);
    var it = dir.iterate();
    while (try it.next(w.cx.io)) |e| if (std.mem.endsWith(u8, e.name, ".db")) {
        found = true;
    };
    try std.testing.expect(found);
}

test "doctor flags a missing secret and a dead token" {
    var w: W = undefined;
    try w.init();
    defer w.deinit();
    try w.pair("a", "car1", false, .{});
    try w.env.put("INST_SHOR_USER_ID", "");
    try std.testing.expectEqual(exit.USAGE, d(&w, &.{"doctor"}));
}

test "resolve --live is blocked while a run holds the lock" {
    var w: W = undefined;
    try unsureWorld(&w);
    defer w.deinit();
    var l = try @import("co-kill.zig").acquire(&w.cx);
    try std.testing.expectEqual(exit.BLOCKED, d(&w, &.{ "resolve", "--video", "a", "--as", "failed" }));
    l.release();
    try std.testing.expectEqual(exit.OK, d(&w, &.{ "resolve", "--video", "a", "--as", "failed" }));
}

test "a new render under the same name loses its approval; json must name its own mp4" {
    var w: W = undefined;
    try w.init();
    defer w.deinit();
    w.f.script = &ready_soon;
    try w.pair("h", "car9", true, .{});
    try std.testing.expectEqual(exit.OK, d(&w, &.{ "approve", "--video", "h" }));
    // producer re-renders: different size
    const mp = try std.fmt.allocPrint(w.arena.allocator(), "{s}/h.mp4", .{w.src});
    try @import("te-mp4.zig").write(w.arena.allocator(), w.cx.io, mp, .{ .mdat_mb = 1 });
    try std.testing.expectEqual(exit.NOTHING, pub_cmd.run(&w.cx, &.{}));
    // a second json pointing at the held mp4 is refused
    const jp = try std.fmt.allocPrint(w.arena.allocator(), "{s}/other.json", .{w.src});
    try Io.Dir.cwd().writeFile(w.cx.io, .{ .sub_path = jp, .data = "{\"car\":\"x\",\"template\":\"t\",\"mp4\":\"h.mp4\",\"ai_notice\":\"AI\"}" });
    try std.testing.expectEqual(exit.NOTHING, pub_cmd.run(&w.cx, &.{}));
    try std.testing.expectEqual(@as(u32, 0), w.f.container_n.load(.acquire));
}
