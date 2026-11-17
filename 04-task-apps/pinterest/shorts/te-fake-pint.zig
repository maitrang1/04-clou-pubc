// Fake Pinterest for tests: ONE loopback server plays graph + rupload (upload_url points back here). Spare port from the OS.
// Streams upload bodies (counts, never stores) so a 200 MB test file stays flat in RAM. Test-only: never linked into the release path.
const std = @import("std");
const Io = std.Io;

pub const Rep = struct { status: u16 = 200, headers: []const u8 = "", body: []const u8 = "", drop: bool = false, delay_ms: u32 = 0 };
pub const Mode = enum { uploading, upload_complete, processing, ready, ready_completed, draft_ready, proc_error, expired, upload_failed };

pub const Fake = struct {
    io: Io,
    server: Io.net.Server,
    port: u16,
    thread: ?std.Thread = null,
    stop_flag: std.atomic.Value(bool) = .init(false),
    active: std.atomic.Value(u32) = .init(0),
    // knobs (set by the test before the call)
    token: []const u8 = "TESTTOKEN",
    page_id: []const u8 = "1234567890",
    video_id: []const u8 = "9876543210",
    start_rep: ?Rep = null,
    upload_rep: ?Rep = null,
    finish_rep: ?Rep = null,
    status_rep: ?Rep = null,
    list_body: []const u8 = "{\"data\":[]}",
    debug_body: []const u8 = "{\"data\":{\"is_valid\":true,\"expires_at\":0,\"data_access_expires_at\":1900000000,\"scopes\":[\"pages_show_list\",\"pages_read_engagement\",\"pages_manage_posts\"]}}",
    usage_hdr: []const u8 = "",
    script: []const Mode = &.{.ready},
    finish_post_id: bool = false,
    cut_after: std.atomic.Value(i64) = .init(-1), // next upload: take N bytes then drop the connection
    have_on_start: u64 = 0, // bytes the server claims to hold right after start (offset-mismatch test)
    on_upload: ?[]const u8 = null, // test: append a byte to this file while the upload is in flight
    finish_drop: bool = false, // read the finish request, then vanish without an answer
    // state / counters
    have: std.atomic.Value(u64) = .init(0),
    total: std.atomic.Value(u64) = .init(0),
    start_n: std.atomic.Value(u32) = .init(0),
    upload_n: std.atomic.Value(u32) = .init(0),
    finish_n: std.atomic.Value(u32) = .init(0),
    status_n: std.atomic.Value(u32) = .init(0),
    list_n: std.atomic.Value(u32) = .init(0),
    reqlog: std.ArrayList(u8) = .empty, // every request line + whether the Authorization header was there
    finish_body: std.ArrayList(u8) = .empty,
    mu: Io.Mutex = .init,

    pub fn start(io: Io) !*Fake {
        var s = try (try Io.net.IpAddress.parse("127.0.0.1", 0)).listen(io, .{ .reuse_address = true });
        errdefer s.deinit(io);
        const self = try std.heap.page_allocator.create(Fake);
        self.* = .{ .io = io, .server = s, .port = s.socket.address.getPort() };
        self.thread = try std.Thread.spawn(.{}, loop, .{self});
        return self;
    }
    pub fn base(self: *const Fake, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "http://127.0.0.1:{d}", .{self.port}) catch buf[0..0];
    }
    pub fn stop(self: *Fake) void {
        self.stop_flag.store(true, .release);
        if (Io.net.IpAddress.parse("127.0.0.1", self.port)) |a| {
            if (a.connect(self.io, .{ .mode = .stream })) |st| st.close(self.io) else |_| {}
        } else |_| {}
        if (self.thread) |t| t.join();
        var n: u32 = 0;
        while (self.active.load(.acquire) > 0 and n < 400) : (n += 1) std.Io.sleep(self.io, .fromMilliseconds(10), .awake) catch {};
        self.server.deinit(self.io);
        self.reqlog.deinit(std.heap.page_allocator);
        self.finish_body.deinit(std.heap.page_allocator);
        std.heap.page_allocator.destroy(self);
    }
    pub fn logHas(self: *Fake, needle: []const u8) bool {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        return std.mem.indexOf(u8, self.reqlog.items, needle) != null;
    }
    pub fn finishText(self: *Fake, a: std.mem.Allocator) ![]u8 {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        return a.dupe(u8, self.finish_body.items);
    }
};

fn loop(self: *Fake) void {
    while (!self.stop_flag.load(.acquire)) {
        const st = self.server.accept(self.io) catch break;
        if (self.stop_flag.load(.acquire)) {
            st.close(self.io);
            break;
        }
        _ = self.active.fetchAdd(1, .acq_rel);
        const th = std.Thread.spawn(.{}, conn, .{ self, st }) catch {
            _ = self.active.fetchSub(1, .acq_rel);
            st.close(self.io);
            continue;
        };
        th.detach();
    }
}

fn conn(self: *Fake, st_in: Io.net.Stream) void {
    defer _ = self.active.fetchSub(1, .acq_rel);
    var st = st_in;
    defer st.close(self.io);
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var rb: [16384]u8 = undefined;
    var wb: [4096]u8 = undefined;
    var r = st.reader(self.io, &rb);
    var w = st.writer(self.io, &wb);
    handle(self, arena.allocator(), &r.interface, &w.interface) catch {};
}

fn hdr(head: []const u8, name: []const u8) []const u8 {
    var it = std.mem.splitScalar(u8, head, '\n');
    while (it.next()) |l| {
        if (l.len > name.len and l[name.len] == ':' and std.ascii.eqlIgnoreCase(l[0..name.len], name)) return std.mem.trim(u8, l[name.len + 1 ..], " \r");
    }
    return "";
}

fn reply(self: *Fake, w: *Io.Writer, rep: Rep, extra: []const u8) !void {
    if (rep.delay_ms > 0) std.Io.sleep(self.io, .fromMilliseconds(rep.delay_ms), .awake) catch {};
    if (rep.drop) return;
    try w.print("HTTP/1.1 {d} X\r\n{s}{s}{s}Connection: close\r\nContent-Length: {d}\r\n\r\n", .{ rep.status, rep.headers, extra, self.usage_hdr, rep.body.len });
    try w.writeAll(rep.body);
    try w.flush();
}

fn errBody(a: std.mem.Allocator, code: i64) []const u8 {
    return std.fmt.allocPrint(a, "{{\"error\":{{\"message\":\"fake error\",\"type\":\"OAuthException\",\"code\":{d}}}}}", .{code}) catch "";
}

fn handle(self: *Fake, a: std.mem.Allocator, r: *Io.Reader, w: *Io.Writer) !void {
    const first = try r.takeDelimiterExclusive('\n');
    r.toss(1);
    const line = std.mem.trimEnd(u8, first, "\r");
    var it = std.mem.tokenizeScalar(u8, line, ' ');
    const method = try a.dupe(u8, it.next() orelse return);
    const target = try a.dupe(u8, it.next() orelse return);
    var head: std.ArrayList(u8) = .empty;
    var clen: u64 = 0;
    while (true) {
        const l = try r.takeDelimiterExclusive('\n');
        r.toss(1);
        const t = std.mem.trimEnd(u8, l, "\r");
        if (t.len == 0) break;
        try head.appendSlice(a, t);
        try head.append(a, '\n');
        if (std.ascii.startsWithIgnoreCase(t, "content-length:")) clen = std.fmt.parseInt(u64, std.mem.trim(u8, t[15..], " "), 10) catch 0;
    }
    const auth = hdr(head.items, "authorization");
    {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        try self.reqlog.print(std.heap.page_allocator, "{s} {s} auth={s}\n", .{ method, target, if (auth.len > 0) "yes" else "no" });
    }
    const want = try std.fmt.allocPrint(a, "OAuth {s}", .{self.token});
    const path = target[0 .. std.mem.indexOfScalar(u8, target, '?') orelse target.len];
    const is_up = std.mem.startsWith(u8, path, "/rupload/");
    // drain small bodies now; uploads are streamed below
    var body: []u8 = &.{};
    if (!is_up and clen > 0) {
        body = try a.alloc(u8, @intCast(@min(clen, 1 << 20)));
        try r.readSliceAll(body);
    }
    const is_dbg = std.mem.endsWith(u8, path, "/debug_token"); // debug_token is called with an app token
    if (!is_dbg and !std.mem.eql(u8, auth, want)) return reply(self, w, .{ .status = 400, .body = errBody(a, 190) }, "");
    if (is_up) return upload(self, a, r, w, head.items, clen);
    if (std.mem.endsWith(u8, path, "/video_reels") and std.mem.eql(u8, method, "POST")) {
        if (std.mem.indexOf(u8, body, "\"upload_phase\":\"start\"") != null or std.mem.indexOf(u8, body, "\"upload_phase\": \"start\"") != null) {
            _ = self.start_n.fetchAdd(1, .acq_rel);
            self.have.store(self.have_on_start, .release);
            self.status_n.store(0, .release); // a new session replays the status script
            if (self.start_rep) |rep| return reply(self, w, rep, "");
            const b = try std.fmt.allocPrint(a, "{{\"video_id\":\"{s}\",\"upload_url\":\"http://127.0.0.1:{d}/rupload/video-upload/{s}\"}}", .{ self.video_id, self.port, self.video_id });
            return reply(self, w, .{ .body = b }, "");
        }
        _ = self.finish_n.fetchAdd(1, .acq_rel);
        {
            self.mu.lockUncancelable(self.io);
            defer self.mu.unlock(self.io);
            self.finish_body.clearRetainingCapacity();
            try self.finish_body.appendSlice(std.heap.page_allocator, body);
        }
        if (self.finish_drop) return;
        if (self.finish_rep) |rep| return reply(self, w, rep, "");
        return reply(self, w, .{ .body = if (self.finish_post_id) "{\"success\":true,\"post_id\":\"1234567890_555\"}" else "{\"success\":true}" }, "");
    }
    if (std.mem.endsWith(u8, path, "/video_reels")) {
        _ = self.list_n.fetchAdd(1, .acq_rel);
        return reply(self, w, .{ .body = self.list_body }, "");
    }
    if (std.mem.endsWith(u8, path, "/debug_token")) return reply(self, w, .{ .body = self.debug_body }, "");
    if (std.mem.indexOf(u8, target, "fields=status") != null) {
        const n = self.status_n.fetchAdd(1, .acq_rel);
        if (self.status_rep) |rep| return reply(self, w, rep, "");
        const mode = self.script[@min(n, self.script.len - 1)];
        return reply(self, w, .{ .body = try statusJson(self, a, mode) }, "");
    }
    // anything else: the Page itself
    return reply(self, w, .{ .body = try std.fmt.allocPrint(a, "{{\"id\":\"{s}\",\"name\":\"Test Page\"}}", .{self.page_id}) }, "");
}

fn statusJson(self: *Fake, a: std.mem.Allocator, mode: Mode) ![]const u8 {
    const have = self.have.load(.acquire);
    const total = self.total.load(.acquire);
    const done: []const u8 = if (mode == .ready_completed) "completed" else "complete";
    const vs: []const u8 = switch (mode) {
        .uploading => "uploading",
        .upload_complete => "upload_complete",
        .processing => "processing",
        .ready, .ready_completed, .draft_ready => "ready",
        .proc_error => "error",
        .expired => "expired",
        .upload_failed => "upload_failed",
    };
    const up: []const u8 = if (mode == .uploading) "in_progress" else if (mode == .upload_failed) "error" else done;
    const pr: []const u8 = switch (mode) {
        .uploading, .upload_complete => "not_started",
        .processing => "in_progress",
        .proc_error => "error",
        else => done,
    };
    const pu: []const u8 = switch (mode) {
        .ready, .ready_completed => "complete",
        .draft_ready => "complete",
        else => "not_started",
    };
    const ps: []const u8 = if (mode == .draft_ready) "draft" else "published";
    const perr: []const u8 = if (mode == .proc_error) ",\"error\":{\"message\":\"transcode failed\"}" else "";
    return std.fmt.allocPrint(a, "{{\"id\":\"{s}\",\"status\":{{\"video_status\":\"{s}\",\"uploading_phase\":{{\"status\":\"{s}\",\"bytes_transfered\":{d},\"source_file_size\":{d}}},\"processing_phase\":{{\"status\":\"{s}\"{s}}},\"publishing_phase\":{{\"status\":\"{s}\",\"publish_status\":\"{s}\"}}}}}}", .{ self.video_id, vs, up, have, total, pr, perr, pu, ps });
}

fn upload(self: *Fake, a: std.mem.Allocator, r: *Io.Reader, w: *Io.Writer, head: []const u8, clen: u64) !void {
    _ = self.upload_n.fetchAdd(1, .acq_rel);
    if (self.on_upload) |p| {
        if (Io.Dir.cwd().openFile(self.io, p, .{ .mode = .read_write })) |f| {
            const n = f.length(self.io) catch 0;
            f.writePositionalAll(self.io, "x", n) catch {};
            f.close(self.io);
        } else |_| {}
    }
    const off = std.fmt.parseInt(u64, hdr(head, "offset"), 10) catch 0;
    const fsz = std.fmt.parseInt(u64, hdr(head, "file_size"), 10) catch 0;
    self.total.store(fsz, .release);
    if (self.upload_rep) |rep| return reply(self, w, rep, "");
    if (off != self.have.load(.acquire)) return reply(self, w, .{ .status = 400, .body = "{\"debug_info\":{\"retriable\":false,\"type\":\"OffsetInvalidError\",\"message\":\"offset mismatch\"}}" }, "");
    var take = clen;
    const cut = self.cut_after.swap(-1, .acq_rel);
    if (cut >= 0) take = @min(clen, @as(u64, @intCast(cut)));
    var buf: [65536]u8 = undefined;
    var left = take;
    while (left > 0) {
        const n = r.readSliceShort(buf[0..@intCast(@min(buf.len, left))]) catch break;
        if (n == 0) break;
        left -= n;
        _ = self.have.fetchAdd(n, .acq_rel);
    }
    if (cut >= 0) return; // dropped mid-upload
    _ = a;
    try reply(self, w, .{ .body = "{\"success\":true}" }, "");
}
