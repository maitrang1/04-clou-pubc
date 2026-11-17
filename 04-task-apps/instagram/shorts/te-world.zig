// Test world: temp home + source folder + fake Instagram + secrets via env. Shared by the publish/resolve/admin tests.
const std = @import("std");
const Io = std.Io;
const fk = @import("te-fake-graph.zig");
const ctxm = @import("co-ctx.zig");
const mp4 = @import("te-mp4.zig");
const send = @import("rw-send.zig");
const call = @import("ap-call.zig");

pub const World = struct {
    arena: std.heap.ArenaAllocator,
    env: std.process.Environ.Map,
    tmp: std.testing.TmpDir,
    cx: ctxm.Ctx,
    f: *fk.Fake,
    src: []const u8,

    pub fn init(w: *World) !void {
        w.arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        errdefer w.arena.deinit();
        const a = w.arena.allocator();
        w.env = std.process.Environ.Map.init(std.testing.allocator);
        w.tmp = std.testing.tmpDir(.{});
        w.f = try fk.Fake.start(std.testing.io);
        const home = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{&w.tmp.sub_path});
        w.src = try std.fmt.allocPrint(a, "{s}/src", .{home});
        try Io.Dir.cwd().createDirPath(std.testing.io, w.src);
        try w.env.put("INST_SHOR_TOKEN", "TESTTOKEN");
        try w.env.put("INST_SHOR_USER_ID", "1784140000");
        var cx = ctxm.testCtx(a, &w.env, home);
        cx.cfg.data_dir = "~/data";
        cx.cfg.source.dir = w.src;
        cx.cfg.limits.gap_min_s = 0;
        cx.cfg.limits.gap_max_s = 0;
        cx.cfg.limits.daily_cap = 5;
        cx.cfg.limits.disk_min_mb = 0;
        cx.cfg.net.status_poll_s = 1;
        cx.cfg.net.status_poll_max_s = 6;
        cx.cfg.net.resume_max = 2;
        cx.cfg.net.notready_wait_s = 1;
        cx.cfg.net.timeout_s = 10;
        cx.cfg.net.upload_timeout_s = 60;
        var bb: [64]u8 = undefined;
        cx.cfg.graph.base = try a.dupe(u8, w.f.base(&bb));
        cx.live = true;
        w.cx = cx;
        call.resetUsage();
    }
    pub fn deinit(w: *World) void {
        w.f.stop();
        w.tmp.cleanup();
        w.env.deinit();
        w.arena.deinit();
    }
    // a pair the producer would hand over
    pub fn pair(w: *World, name: []const u8, car: []const u8, review: bool, spec: mp4.Spec) !void {
        const a = w.arena.allocator();
        const mp = try std.fmt.allocPrint(a, "{s}/{s}.mp4", .{ w.src, name });
        try mp4.write(a, w.cx.io, mp, spec);
        const js = try std.fmt.allocPrint(a, "{{\"car\":\"{s}\",\"code\":\"x\",\"template\":\"t1\",\"mp4\":\"{s}.mp4\",\"seconds\":10,\"width\":1080,\"height\":1920,\"hooks\":[\"Hook {s}\"],\"description\":\"Desc {s}.\",\"hashtags\":[\"cars\",\"vn\"],\"ai_notice\":\"Made with AI.\",\"review\":{s},\"plates\":\"band\",\"made_at\":\"2026-11-15\",\"listing_url\":\"\"}}", .{ car, name, name, name, if (review) "true" else "false" });
        const jp = try std.fmt.allocPrint(a, "{s}/{s}.json", .{ w.src, name });
        try Io.Dir.cwd().writeFile(w.cx.io, .{ .sub_path = jp, .data = js });
    }
    pub fn row(w: *World, pkey: []const u8) !?send.Row {
        var db = try send.open(&w.cx);
        defer db.close();
        return send.byPkey(&db, w.arena.allocator(), pkey);
    }
};
