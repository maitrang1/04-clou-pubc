// The other commands against the fake: resolve, approve/hold, token (+refresh), doctor, scan, status, kill, backup, config, dispatch.
const std = @import("std");
const Io = std.Io;
const W = @import("te-world.zig").World;
const fk = @import("te-fake-threads.zig");
const main = @import("main.zig");
const exit = @import("co-exit.zig");
const send = @import("rw-send.zig");
const pub_cmd = @import("cm-publish.zig");
const util = @import("co-util.zig");

const key = "car1:t1:thre-shor";

fn d(w: *W, av: []const []const u8) u8 {
    return main.dispatch(&w.cx, av);
}

// an unsure row: publish answered 500 but the post was made
fn unsureWorld(w: *W) !void {
    try w.init();
    w.f.publish_500_posted = true;
    try w.pair("a", "car1", false, .{});
    try std.testing.expectEqual(exit.UNSURE, pub_cmd.run(&w.cx, &.{}));
    w.f.publish_500_posted = false;
}

test "resolve: the post exists -> posted, never re-sends; dry-run writes nothing" {
    var w: W = undefined;
    try unsureWorld(&w);
    defer w.deinit();
    w.cx.live = false;
    try std.testing.expectEqual(exit.OK, d(&w, &.{ "resolve", "--video", "a" }));
    try std.testing.expectEqual(send.State.unsure, (try w.row(key)).?.state);
    w.cx.live = true;
    try std.testing.expectEqual(exit.OK, d(&w, &.{ "resolve", "--video", "a" }));
    const r = (try w.row(key)).?;
    try std.testing.expectEqual(send.State.posted, r.state);
    try std.testing.expectEqualStrings("9001", r.media_id);
    try std.testing.expectEqual(@as(u32, 1), w.f.publish_n.load(.acquire));
    try std.testing.expectEqual(@as(u32, 1), w.f.create_n.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), try w.count(w.done_dir)); // the hosted copy is given back
}

test "resolve: container still FINISHED and no post -> failed (nothing posted); --again can retry" {
    var w: W = undefined;
    try w.init();
    defer w.deinit();
    w.f.publish_drop = true;
    w.f.publish_no_post = true; // the request left, Threads never made the post
    try w.pair("a", "car1", false, .{});
    try std.testing.expectEqual(exit.UNSURE, pub_cmd.run(&w.cx, &.{}));
    w.f.status_n.store(0, .release);
    // a moment after the request Threads may still post it: no "failed" yet
    try std.testing.expectEqual(exit.UNSURE, d(&w, &.{ "resolve", "--video", "a" }));
    try std.testing.expectEqual(send.State.unsure, (try w.row(key)).?.state);
    w.cx.cfg.limits.unsure_wait_min = 0; // long after
    try std.testing.expectEqual(exit.OK, d(&w, &.{ "resolve", "--video", "a" }));
    try std.testing.expectEqual(send.State.failed, (try w.row(key)).?.state);
    w.f.publish_drop = false;
    w.f.publish_no_post = false;
    try std.testing.expectEqual(exit.OK, pub_cmd.run(&w.cx, &.{ "--video", "a", "--again" }));
    try std.testing.expectEqual(send.State.posted, (try w.row(key)).?.state);
    try std.testing.expectEqual(@as(usize, 1), w.f.postCount());
}

test "resolve: stays unsure while Threads is still working; a person can answer with --as" {
    var w: W = undefined;
    try w.init();
    defer w.deinit();
    w.f.publish_drop = true;
    w.f.publish_no_post = true;
    try w.pair("a", "car1", false, .{});
    try std.testing.expectEqual(exit.UNSURE, pub_cmd.run(&w.cx, &.{}));
    const sc = [_]fk.Word{.in_progress};
    w.f.script = &sc;
    try std.testing.expectEqual(exit.UNSURE, d(&w, &.{ "resolve", "--video", "a" }));
    try std.testing.expectEqual(send.State.unsure, (try w.row(key)).?.state);
    try std.testing.expectEqual(exit.USAGE, d(&w, &.{ "resolve", "--video", "a", "--as", "maybe" }));
    try std.testing.expectEqual(exit.OK, d(&w, &.{ "resolve", "--video", "a", "--as", "failed" }));
    try std.testing.expectEqual(send.State.failed, (try w.row(key)).?.state);
    try std.testing.expectEqual(exit.OK, d(&w, &.{ "resolve", "--video", "a" })); // not unsure any more: nothing to do
    try std.testing.expectEqual(exit.FAILED, d(&w, &.{ "resolve", "--video", "nope" }));
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

test "a new render under the same name loses its approval" {
    var w: W = undefined;
    try w.init();
    defer w.deinit();
    try w.pair("h", "car9", true, .{});
    try std.testing.expectEqual(exit.OK, d(&w, &.{ "approve", "--video", "h" }));
    const mp = try std.fmt.allocPrint(w.arena.allocator(), "{s}/h.mp4", .{w.src});
    try @import("te-mp4.zig").write(w.arena.allocator(), w.cx.io, mp, .{ .mdat_mb = 1 });
    try std.testing.expectEqual(exit.NOTHING, pub_cmd.run(&w.cx, &.{}));
    try std.testing.expectEqual(@as(u32, 0), w.f.create_n.load(.acquire));
}

test "token: valid, scopes checked with an app secret, missing scope, wrong stored id, no token" {
    var w: W = undefined;
    try w.init();
    defer w.deinit();
    try std.testing.expectEqual(exit.OK, d(&w, &.{"token"}));
    try w.env.put("THRE_SHOR_APP_ID", "111");
    try w.env.put("THRE_SHOR_APP_SECRET", "sss");
    try std.testing.expectEqual(exit.OK, d(&w, &.{"token"}));
    try std.testing.expect(w.f.logHas("/debug_token"));
    w.f.debug_body = "{\"data\":{\"is_valid\":true,\"scopes\":[\"threads_basic\"]}}";
    try std.testing.expectEqual(exit.BLOCKED, d(&w, &.{"token"}));
    w.f.debug_body = "{\"data\":{\"is_valid\":false,\"error\":{\"code\":190,\"message\":\"expired\"}}}";
    try std.testing.expectEqual(exit.BLOCKED, d(&w, &.{"token"}));
    try w.env.put("THRE_SHOR_USER_ID", "999");
    try std.testing.expectEqual(exit.BLOCKED, d(&w, &.{"token"}));
    try w.env.put("THRE_SHOR_TOKEN", "");
    try std.testing.expectEqual(exit.USAGE, d(&w, &.{"token"}));
}

fn tokenFiles(w: *W, token: []const u8, issued_s: i64) !void {
    const a = w.arena.allocator();
    try w.env.put("THRE_SHOR_TOKEN", "");
    const sd = try w.cx.path(a, w.cx.cfg.secrets_dir);
    try util.mkdirp(w.cx.io, sd);
    try util.writeAtomic(a, w.cx.io, try w.cx.secretPath(a, w.cx.cfg.account.token_file), token);
    try util.writeAtomic(a, w.cx.io, try w.cx.secretPath(a, w.cx.cfg.account.token_meta_file), try std.fmt.allocPrint(a, "{d}\n", .{issued_s}));
}

test "token --refresh: dry-run writes nothing; live rewrites the file atomically; too young is refused; env tokens are not touched" {
    var w: W = undefined;
    try w.init();
    defer w.deinit();
    const a = w.arena.allocator();
    w.cx.fake_now_ms = std.Io.Clock.real.now(w.cx.io).toMilliseconds();
    const now_s = @divTrunc(w.cx.fake_now_ms, 1000);
    try tokenFiles(&w, "TESTTOKEN", now_s - 40 * 86400);
    w.cx.live = false;
    try std.testing.expectEqual(exit.OK, d(&w, &.{ "token", "--refresh" }));
    try std.testing.expectEqual(@as(u32, 0), w.f.refresh_n.load(.acquire));
    w.cx.live = true;
    try std.testing.expectEqual(exit.OK, d(&w, &.{ "token", "--refresh" }));
    try std.testing.expectEqual(@as(u32, 1), w.f.refresh_n.load(.acquire));
    const tp = try w.cx.secretPath(a, w.cx.cfg.account.token_file);
    try std.testing.expectEqualStrings("NEWTOKEN1234567", try util.readAll(a, w.cx.io, tp, 100));
    try std.testing.expectEqual(@as(i64, 60), @import("cm-token.zig").daysLeft(&w.cx).?);
    // the new token is 0 h old: a second refresh is refused (Meta: at least 24 h)
    w.f.token = "NEWTOKEN1234567";
    try std.testing.expectEqual(exit.NOTHING, d(&w, &.{ "token", "--refresh" }));
    // an env token is never rewritten
    try w.env.put("THRE_SHOR_TOKEN", "TESTTOKEN");
    w.f.token = "TESTTOKEN";
    try std.testing.expectEqual(exit.FAILED, d(&w, &.{ "token", "--refresh" }));
    try std.testing.expectEqual(@as(u32, 1), w.f.refresh_n.load(.acquire));
}

test "publish refreshes a token that is due, then goes on with the new one" {
    var w: W = undefined;
    try w.init();
    defer w.deinit();
    const a = w.arena.allocator();
    w.cx.fake_now_ms = std.Io.Clock.real.now(w.cx.io).toMilliseconds();
    try tokenFiles(&w, "TESTTOKEN", @divTrunc(w.cx.fake_now_ms, 1000) - 40 * 86400); // 20 days left < 30
    try w.pair("a", "car1", false, .{}); // the fake accepts only TESTTOKEN: the refresh call carries it, the new token will be refused
    const r = pub_cmd.run(&w.cx, &.{});
    // refresh happened (old token accepted), then the run used the new one, which the fake now refuses: the run is blocked, not lost
    try std.testing.expectEqual(@as(u32, 1), w.f.refresh_n.load(.acquire));
    try std.testing.expectEqualStrings("NEWTOKEN1234567", try util.readAll(a, w.cx.io, try w.cx.secretPath(a, w.cx.cfg.account.token_file), 100));
    try std.testing.expect(r == exit.BLOCKED);
    try std.testing.expect((try w.row("car1:t1:thre-shor")) == null); // the pair was not burned
    w.f.token = "NEWTOKEN1234567";
    try std.testing.expectEqual(exit.OK, pub_cmd.run(&w.cx, &.{}));
}

test "doctor, scan, status, kill, backup, config" {
    var w: W = undefined;
    try w.init();
    defer w.deinit();
    try w.pair("a", "car1", false, .{});
    w.cx.live = false;
    try std.testing.expectEqual(exit.OK, d(&w, &.{"doctor"}));
    w.cx.live = true;
    try std.testing.expectEqual(exit.OK, d(&w, &.{"doctor"})); // live: the 16-byte probe goes through the public url
    try std.testing.expectEqual(@as(usize, 0), try w.count(w.host_dir));
    try std.testing.expectEqual(exit.OK, d(&w, &.{"scan"}));
    try std.testing.expectEqual(exit.OK, d(&w, &.{"status"})); // no ledger yet
    try std.testing.expectEqual(exit.OK, pub_cmd.run(&w.cx, &.{}));
    try std.testing.expectEqual(exit.OK, d(&w, &.{"status"}));
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

test "doctor flags a missing token, an unset host, and a redirecting host" {
    var w: W = undefined;
    try w.init();
    defer w.deinit();
    try w.pair("a", "car1", false, .{});
    w.cx.live = false;
    try w.env.put("THRE_SHOR_TOKEN", "");
    try std.testing.expectEqual(exit.USAGE, d(&w, &.{"doctor"}));
    try w.env.put("THRE_SHOR_TOKEN", "TESTTOKEN");
    w.cx.live = true;
    w.f.redirect_host = true;
    try std.testing.expectEqual(exit.BLOCKED, d(&w, &.{"doctor"}));
    w.f.redirect_host = false;
    w.cx.cfg.host.base_url = "";
    try std.testing.expectEqual(exit.USAGE, d(&w, &.{"doctor"}));
}

test "status shows staged and the publisher flag; scan counts pending" {
    var w: W = undefined;
    try w.init();
    defer w.deinit();
    w.cx.cfg.post.public = false;
    try w.pair("a", "car1", false, .{});
    try std.testing.expectEqual(exit.OK, pub_cmd.run(&w.cx, &.{}));
    try std.testing.expectEqual(exit.OK, d(&w, &.{"status"}));
    var db = try send.open(&w.cx);
    defer db.close();
    try std.testing.expectEqual(@as(i64, 1), try send.count(&db, .staged));
}
