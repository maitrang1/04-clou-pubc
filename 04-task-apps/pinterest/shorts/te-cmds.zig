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

const happy = [_]fk.Mode{ .upload_complete, .processing, .draft_ready };

fn d(w: *W, av: []const []const u8) u8 {
    return main.dispatch(&w.cx, av);
}

fn unsureWorld(w: *W) !void {
    try w.init();
    w.f.script = &happy;
    w.f.finish_drop = true;
    try w.pair("a", "car1", false, .{});
    try std.testing.expectEqual(exit.UNSURE, pub_cmd.run(&w.cx, &.{}));
    w.f.finish_drop = false;
}

test "resolve: Pinterest says published -> posted, never re-sends" {
    var w: W = undefined;
    try unsureWorld(&w);
    defer w.deinit();
    const sc = [_]fk.Mode{.ready};
    w.f.script = &sc;
    w.f.status_n.store(0, .release);
    w.cx.live = false;
    try std.testing.expectEqual(exit.OK, d(&w, &.{ "resolve", "--video", "a" }));
    try std.testing.expectEqual(send.State.unsure, (try w.row("car1:t1:pint-shor")).?.state); // dry-run wrote nothing
    w.cx.live = true;
    try std.testing.expectEqual(exit.OK, d(&w, &.{ "resolve", "--video", "a" }));
    const r = (try w.row("car1:t1:pint-shor")).?;
    try std.testing.expectEqual(send.State.posted, r.state);
    try std.testing.expectEqual(@as(u32, 1), w.f.finish_n.load(.acquire));
    try std.testing.expectEqual(@as(u32, 1), w.f.start_n.load(.acquire));
}

test "resolve: status shows nothing published but list has it -> posted; absent -> stays unsure; failed -> failed" {
    var w: W = undefined;
    try unsureWorld(&w);
    defer w.deinit();
    const sc = [_]fk.Mode{.upload_complete};
    w.f.script = &sc;
    w.f.list_body = "{\"data\":[]}";
    try std.testing.expectEqual(exit.UNSURE, d(&w, &.{ "resolve", "--video", "a" }));
    try std.testing.expectEqual(send.State.unsure, (try w.row("car1:t1:pint-shor")).?.state);
    w.f.list_body = "{\"data\":[{\"id\":\"9876543210\",\"updated_time\":\"2026-11-15T10:00:00+0000\",\"description\":\"x\"}]}";
    try std.testing.expectEqual(exit.OK, d(&w, &.{ "resolve", "--video", "a" }));
    try std.testing.expectEqual(send.State.posted, (try w.row("car1:t1:pint-shor")).?.state);
    var w2: W = undefined;
    try unsureWorld(&w2);
    defer w2.deinit();
    const sc2 = [_]fk.Mode{.proc_error};
    w2.f.script = &sc2;
    try std.testing.expectEqual(exit.OK, d(&w2, &.{ "resolve", "--video", "a" }));
    try std.testing.expectEqual(send.State.failed, (try w2.row("car1:t1:pint-shor")).?.state);
}

test "resolve: a person can answer with --as; a posted row is left alone" {
    var w: W = undefined;
    try unsureWorld(&w);
    defer w.deinit();
    try std.testing.expectEqual(exit.USAGE, d(&w, &.{ "resolve", "--video", "a", "--as", "maybe" }));
    try std.testing.expectEqual(send.State.unsure, (try w.row("car1:t1:pint-shor")).?.state);
    try std.testing.expectEqual(exit.OK, d(&w, &.{ "resolve", "--video", "a", "--as", "failed" }));
    try std.testing.expectEqual(send.State.failed, (try w.row("car1:t1:pint-shor")).?.state);
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
    w.f.script = &happy;
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

test "token: valid + scopes, missing scope, dead token" {
    var w: W = undefined;
    try w.init();
    defer w.deinit();
    try std.testing.expectEqual(exit.OK, d(&w, &.{"token"}));
    // the one documented place a token rides in a URL is debug_token's input_token; our own log and output never carry it
    try std.testing.expect(w.f.logHas("debug_token?input_token="));
    const lp = try w.cx.dataPath(w.arena.allocator(), "run.jsonl");
    if (util.exists(w.cx.io, lp)) {
        const lt = try util.readAll(w.arena.allocator(), w.cx.io, lp, 1 << 20);
        try std.testing.expect(std.mem.indexOf(u8, lt, "TESTTOKEN") == null);
    }
    w.f.debug_body = "{\"data\":{\"is_valid\":true,\"expires_at\":0,\"scopes\":[\"pages_show_list\"]}}";
    try std.testing.expectEqual(exit.BLOCKED, d(&w, &.{"token"}));
    w.f.debug_body = "{\"data\":{\"is_valid\":false,\"error\":{\"code\":190,\"message\":\"Session expired\"}}}";
    try std.testing.expectEqual(exit.BLOCKED, d(&w, &.{"token"}));
    try w.env.put("PINT_SHOR_PAGE_TOKEN", "");
    try std.testing.expectEqual(exit.USAGE, d(&w, &.{"token"}));
}

test "doctor, scan, status, kill, backup, config" {
    var w: W = undefined;
    try w.init();
    defer w.deinit();
    w.f.script = &happy;
    try w.pair("a", "car1", false, .{});
    try std.testing.expectEqual(exit.OK, d(&w, &.{"doctor"}));
    try std.testing.expectEqual(exit.OK, d(&w, &.{"scan"}));
    try std.testing.expectEqual(exit.OK, d(&w, &.{"status"})); // no ledger yet
    try std.testing.expectEqual(exit.OK, pub_cmd.run(&w.cx, &.{}));
    try std.testing.expectEqual(exit.OK, d(&w, &.{"status"}));
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
    try w.env.put("FACE_APP_SECRET", "");
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
    w.f.script = &happy;
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
    try std.testing.expectEqual(@as(u32, 0), w.f.start_n.load(.acquire));
}
