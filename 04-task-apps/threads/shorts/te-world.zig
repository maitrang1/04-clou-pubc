// Test world: temp home + source folder + host folders + fake Threads + secrets via env. Shared by the publish/resolve/admin tests.
const std = @import("std");
const Io = std.Io;
const fk = @import("te-fake-threads.zig");
const ctxm = @import("co-ctx.zig");
const mp4 = @import("te-mp4.zig");
const send = @import("rw-send.zig");

pub const World = struct {
    arena: std.heap.ArenaAllocator,
    env: std.process.Environ.Map,
    tmp: std.testing.TmpDir,
    cx: ctxm.Ctx,
    f: *fk.Fake,
    src: []const u8,
    host_dir: []const u8,
    done_dir: []const u8,

    pub fn init(w: *World) !void {
        w.arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        errdefer w.arena.deinit();
        const a = w.arena.allocator();
        w.env = std.process.Environ.Map.init(std.testing.allocator);
        w.tmp = std.testing.tmpDir(.{});
        w.f = try fk.Fake.start(std.testing.io);
        const home = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{&w.tmp.sub_path});
        w.src = try std.fmt.allocPrint(a, "{s}/src", .{home});
        w.host_dir = try std.fmt.allocPrint(a, "{s}/web", .{home});
        w.done_dir = try std.fmt.allocPrint(a, "{s}/done", .{home});
        try Io.Dir.cwd().createDirPath(std.testing.io, w.src);
        try Io.Dir.cwd().createDirPath(std.testing.io, w.host_dir);
        w.f.host_root = w.host_dir;
        try w.env.put("THRE_SHOR_TOKEN", "TESTTOKEN");
        try w.env.put("THRE_SHOR_USER_ID", "7770001");
        var cx = ctxm.testCtx(a, &w.env, home);
        cx.cfg.data_dir = "~/data";
        cx.cfg.secrets_dir = "~/sec";
        cx.cfg.source.dir = w.src;
        cx.cfg.host = .{ .dir = w.host_dir, .done_dir = w.done_dir, .base_url = "", .selfcheck = true };
        cx.cfg.device.publisher = true;
        cx.cfg.limits.gap_min_s = 0;
        cx.cfg.limits.gap_max_s = 0;
        cx.cfg.limits.daily_cap = 5;
        cx.cfg.limits.disk_min_mb = 0;
        cx.cfg.post.public = true;
        cx.cfg.net.status_poll_s = 1;
        cx.cfg.net.status_poll_max_s = 4;
        cx.cfg.net.settle_s = 1;
        cx.cfg.net.timeout_s = 10;
        var bb: [64]u8 = undefined;
        const base = try a.dupe(u8, w.f.base(&bb));
        cx.cfg.graph.base = base;
        cx.cfg.host.base_url = try std.fmt.allocPrint(a, "{s}/v", .{base});
        cx.live = true;
        w.cx = cx;
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
        const js = try std.fmt.allocPrint(a, "{{\"car\":\"{s}\",\"code\":\"x\",\"template\":\"t1\",\"mp4\":\"{s}.mp4\",\"seconds\":10,\"width\":1080,\"height\":1920,\"hooks\":[\"Hook {s}\"],\"description\":\"Desc {s}.\",\"hashtags\":[\"cars\",\"vn\"],\"ai_notice\":\"Made with AI.\",\"review\":{s},\"plates\":\"band\",\"made_at\":\"2026-11-16\",\"listing_url\":\"\"}}", .{ car, name, name, name, if (review) "true" else "false" });
        const jp = try std.fmt.allocPrint(a, "{s}/{s}.json", .{ w.src, name });
        try Io.Dir.cwd().writeFile(w.cx.io, .{ .sub_path = jp, .data = js });
    }
    pub fn row(w: *World, pkey: []const u8) !?send.Row {
        var db = try send.open(&w.cx);
        defer db.close();
        return send.byPkey(&db, w.arena.allocator(), pkey);
    }
    // number of entries in a folder (hosted copies, done copies)
    pub fn count(w: *World, dir: []const u8) !usize {
        var d = Io.Dir.cwd().openDir(w.cx.io, dir, .{ .iterate = true }) catch return 0;
        defer d.close(w.cx.io);
        var n: usize = 0;
        var it = d.iterate();
        while (try it.next(w.cx.io)) |_| n += 1;
        return n;
    }
};
