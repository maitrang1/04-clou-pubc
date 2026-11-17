// Fake Threads for tests: ONE loopback server plays three roles on a spare port: the Threads API, Meta's downloader (on create it looks for the file the app hosted)
// and the owner's static host (GET /v/<file>, with Range). Test-only: never linked into the release path. Our reading of the docs, not Meta's code.
const std = @import("std");
const Io = std.Io;
const util = @import("co-util.zig");

pub const Rep = struct { status: u16 = 200, headers: []const u8 = "", body: []const u8 = "", drop: bool = false };
// what the container reports on each status read (the last entry repeats)
pub const Word = enum { in_progress, finished, published, err_download, err_duration, err_unknown, expired };

pub const Fake = struct {
    io: Io,
    server: Io.net.Server,
    port: u16,
    thread: ?std.Thread = null,
    stop_flag: std.atomic.Value(bool) = .init(false),
    active: std.atomic.Value(u32) = .init(0),
    // knobs (set by the test before the call)
    token: []const u8 = "TESTTOKEN",
    user_id: []const u8 = "7770001",
    host_root: []const u8 = "", // folder served at /v/ and searched on create
    script: []const Word = &.{.finished},
    create_rep: ?Rep = null,
    publish_rep: ?Rep = null,
    publish_drop: bool = false, // read the publish request, then vanish without an answer (the post IS made)
    publish_500_posted: bool = false, // the post IS made, the answer is a 500
    publish_no_post: bool = false, // answer ok but make no post (never used as a fact, only to test odd replies)
    status_first_404: u32 = 0, // this many first status reads answer 404
    me_rep: ?Rep = null,
    quota_usage: i64 = 0,
    quota_total: i64 = 250,
    quota_rep: ?Rep = null,
    list_rep: ?Rep = null,
    refresh_rep: ?Rep = null,
    debug_body: []const u8 = "{\"data\":{\"is_valid\":true,\"expires_at\":1900000000,\"scopes\":[\"threads_basic\",\"threads_content_publish\"],\"user_id\":\"7770001\"}}",
    ignore_range: bool = false,
    redirect_host: bool = false,
    no_head: bool = false, // HEAD answers 405
    big_error_page: bool = false, // every file request answers 404 with a 6 KB body
    // state / counters
    status_n: std.atomic.Value(u32) = .init(0),
    create_n: std.atomic.Value(u32) = .init(0),
    publish_n: std.atomic.Value(u32) = .init(0),
    list_n: std.atomic.Value(u32) = .init(0),
    refresh_n: std.atomic.Value(u32) = .init(0),
    next_container: std.atomic.Value(u32) = .init(5550),
    reqlog: std.ArrayList(u8) = .empty, // method + path (no query, no body) + whether a token was present
    create_body: std.ArrayList(u8) = .empty, // last create form (token removed)
    publish_body: std.ArrayList(u8) = .empty,
    conts: std.ArrayList(u8) = .empty, // lines: cid|found|form
    posts: std.ArrayList(u8) = .empty, // JSON items of made posts, comma separated
    fetched_ok: std.atomic.Value(bool) = .init(false), // the last create found its file
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
        self.create_body.deinit(std.heap.page_allocator);
        self.publish_body.deinit(std.heap.page_allocator);
        self.posts.deinit(std.heap.page_allocator);
        self.conts.deinit(std.heap.page_allocator);
        std.heap.page_allocator.destroy(self);
    }
    pub fn logHas(self: *Fake, needle: []const u8) bool {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        return std.mem.indexOf(u8, self.reqlog.items, needle) != null;
    }
    pub fn createText(self: *Fake, a: std.mem.Allocator) ![]u8 {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        return a.dupe(u8, self.create_body.items);
    }
    pub fn publishText(self: *Fake, a: std.mem.Allocator) ![]u8 {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        return a.dupe(u8, self.publish_body.items);
    }
    // a post that already exists on the account (late landing, restored ledger)
    pub fn fakePost(self: *Fake, txt: []const u8) !void {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const esc = try std.json.Stringify.valueAlloc(a, txt, .{});
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        if (self.posts.items.len > 0) try self.posts.append(std.heap.page_allocator, ',');
        try self.posts.appendSlice(std.heap.page_allocator, try std.fmt.allocPrint(a, "{{\"id\":\"9100\",\"permalink\":\"https://www.threads.com/@testuser/post/EARLY\",\"text\":{s},\"timestamp\":\"2099-01-01T00:00:00+0000\",\"media_type\":\"VIDEO\",\"cid\":\"0\"}}", .{esc}));
    }
    pub fn postCount(self: *Fake) usize {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        return std.mem.count(u8, self.posts.items, "\"id\"");
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

fn reply(w: *Io.Writer, rep: Rep, extra: []const u8) !void {
    if (rep.drop) return;
    try w.print("HTTP/1.1 {d} X\r\n{s}{s}Connection: close\r\nContent-Length: {d}\r\n\r\n", .{ rep.status, rep.headers, extra, rep.body.len });
    try w.writeAll(rep.body);
    try w.flush();
}

fn errBody(a: std.mem.Allocator, code: i64) []const u8 {
    return std.fmt.allocPrint(a, "{{\"error\":{{\"message\":\"fake error\",\"type\":\"OAuthException\",\"code\":{d}}}}}", .{code}) catch "";
}

// value of one form/query field (percent-decoded)
fn field(a: std.mem.Allocator, src: []const u8, name: []const u8) []const u8 {
    var it = std.mem.splitScalar(u8, src, '&');
    while (it.next()) |kv| {
        const eq = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
        if (std.mem.eql(u8, kv[0..eq], name)) return util.pctDecode(a, kv[eq + 1 ..]) catch "";
    }
    return "";
}

// the form without access_token (what we keep for the tests)
fn stripToken(a: std.mem.Allocator, form: []const u8) []const u8 {
    var o: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, form, '&');
    while (it.next()) |kv| {
        if (std.mem.startsWith(u8, kv, "access_token=")) continue;
        if (o.items.len > 0) o.append(a, '&') catch return "";
        o.appendSlice(a, kv) catch return "";
    }
    return o.items;
}

fn statusJson(a: std.mem.Allocator, w: Word, cid: []const u8) []const u8 {
    const st: []const u8 = switch (w) {
        .in_progress => "IN_PROGRESS",
        .finished => "FINISHED",
        .published => "PUBLISHED",
        .err_download, .err_duration, .err_unknown => "ERROR",
        .expired => "EXPIRED",
    };
    const em: []const u8 = switch (w) {
        .err_download => ",\"error_message\":\"FAILED_DOWNLOADING_VIDEO\"",
        .err_duration => ",\"error_message\":\"INVALID_DURATION\"",
        .err_unknown => ",\"error_message\":\"BRAND_NEW_REASON\"",
        else => "",
    };
    return std.fmt.allocPrint(a, "{{\"status\":\"{s}\"{s},\"id\":\"{s}\"}}", .{ st, em, cid }) catch "";
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
    var body: []u8 = &.{};
    if (clen > 0) {
        body = try a.alloc(u8, @intCast(@min(clen, 1 << 20)));
        try r.readSliceAll(body);
    }
    const qi = std.mem.indexOfScalar(u8, target, '?');
    const path = target[0 .. qi orelse target.len];
    const query = if (qi) |i| target[i + 1 ..] else "";
    // token: query (GET) or form body (POST) or Bearer header
    var tok = field(a, query, "access_token");
    if (tok.len == 0) tok = field(a, body, "access_token");
    const bearer = hdr(head.items, "authorization");
    if (tok.len == 0 and std.mem.startsWith(u8, bearer, "Bearer ")) tok = bearer[7..];
    {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        try self.reqlog.print(std.heap.page_allocator, "{s} {s} tok={s}\n", .{ method, path, if (tok.len > 0) "yes" else "no" });
    }
    // ---- the owner's static host ----
    if (std.mem.startsWith(u8, path, "/v/")) return serveFile(self, a, w, path[3..], hdr(head.items, "range"), std.mem.eql(u8, method, "HEAD"));
    // ---- the API ----
    const is_dbg = std.mem.endsWith(u8, path, "/debug_token");
    if (!is_dbg and !std.mem.eql(u8, tok, self.token)) return reply(w, .{ .status = 400, .body = errBody(a, 190) }, "");
    if (std.mem.endsWith(u8, path, "/refresh_access_token")) {
        _ = self.refresh_n.fetchAdd(1, .acq_rel);
        if (self.refresh_rep) |rep| return reply(w, rep, "");
        return reply(w, .{ .body = "{\"access_token\":\"NEWTOKEN1234567\",\"token_type\":\"bearer\",\"expires_in\":5183944}" }, "");
    }
    if (is_dbg) return reply(w, .{ .body = self.debug_body }, "");
    if (std.mem.endsWith(u8, path, "/me")) {
        if (self.me_rep) |rep| return reply(w, rep, "");
        return reply(w, .{ .body = try std.fmt.allocPrint(a, "{{\"id\":\"{s}\",\"username\":\"testuser\"}}", .{self.user_id}) }, "");
    }
    if (std.mem.endsWith(u8, path, "/threads_publishing_limit")) {
        if (self.quota_rep) |rep| return reply(w, rep, "");
        return reply(w, .{ .body = try std.fmt.allocPrint(a, "{{\"data\":[{{\"quota_usage\":{d},\"config\":{{\"quota_total\":{d},\"quota_duration\":86400}}}}]}}", .{ self.quota_usage, self.quota_total }) }, "");
    }
    if (std.mem.endsWith(u8, path, "/threads_publish") and std.mem.eql(u8, method, "POST")) {
        _ = self.publish_n.fetchAdd(1, .acq_rel);
        {
            self.mu.lockUncancelable(self.io);
            defer self.mu.unlock(self.io);
            self.publish_body.clearRetainingCapacity();
            try self.publish_body.appendSlice(std.heap.page_allocator, stripToken(a, body));
        }
        if (self.publish_rep) |rep| return reply(w, rep, "");
        const made = !self.publish_no_post;
        if (made) try makePost(self, a, field(a, body, "creation_id"));
        if (self.publish_drop) return;
        if (self.publish_500_posted) return reply(w, .{ .status = 500, .body = "{\"error\":{\"message\":\"Unexpected error\",\"code\":2}}" }, "");
        return reply(w, .{ .body = "{\"id\":\"9001\"}" }, "");
    }
    if (std.mem.endsWith(u8, path, "/threads") and std.mem.eql(u8, method, "POST")) {
        _ = self.create_n.fetchAdd(1, .acq_rel);
        const form = stripToken(a, body);
        {
            self.mu.lockUncancelable(self.io);
            defer self.mu.unlock(self.io);
            self.create_body.clearRetainingCapacity();
            try self.create_body.appendSlice(std.heap.page_allocator, form);
        }
        if (self.create_rep) |rep| return reply(w, rep, "");
        // Meta's downloader: the file must be where video_url says
        const url = field(a, body, "video_url");
        const slash = std.mem.lastIndexOfScalar(u8, url, '/') orelse 0;
        const fname = url[slash + 1 ..];
        const fp = try std.fmt.allocPrint(a, "{s}/{s}", .{ self.host_root, fname });
        const found = fname.len > 0 and (Io.Dir.cwd().access(self.io, fp, .{})) != error.FileNotFound and !std.mem.eql(u8, self.host_root, "");
        self.fetched_ok.store(found, .release);
        const cid = self.next_container.fetchAdd(1, .acq_rel);
        const cid_s = try std.fmt.allocPrint(a, "{d}", .{cid});
        try remember(self, a, cid_s, form, found);
        return reply(w, .{ .body = try std.fmt.allocPrint(a, "{{\"id\":\"{s}\"}}", .{cid_s}) }, "");
    }
    if (std.mem.endsWith(u8, path, "/threads") and std.mem.eql(u8, method, "GET")) {
        _ = self.list_n.fetchAdd(1, .acq_rel);
        if (self.list_rep) |rep| return reply(w, rep, "");
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        return reply(w, .{ .body = try std.fmt.allocPrint(a, "{{\"data\":[{s}]}}", .{self.posts.items}) }, "");
    }
    // /v1.0/<id>?fields=...: a container (status) or a post
    const last = path[(std.mem.lastIndexOfScalar(u8, path, '/') orelse 0) + 1 ..];
    if (std.mem.indexOf(u8, query, "fields=status") != null) {
        const n = self.status_n.fetchAdd(1, .acq_rel);
        if (n < self.status_first_404) return reply(w, .{ .status = 404, .body = errBody(a, 100) }, "");
        const idx = n - @min(n, self.status_first_404);
        const word = self.script[@min(idx, self.script.len - 1)];
        // a container that was turned into a post reads PUBLISHED
        if (isPosted(self, a, last)) return reply(w, .{ .body = statusJson(a, .published, last) }, "");
        return reply(w, .{ .body = statusJson(a, word, last) }, "");
    }
    return reply(w, .{ .body = try postJson(self, a, last) }, "");
}

// ---- containers and posts (kept as text, enough for the tests) ----
fn remember(self: *Fake, a: std.mem.Allocator, cid: []const u8, form: []const u8, found: bool) !void {
    self.mu.lockUncancelable(self.io);
    defer self.mu.unlock(self.io);
    const line = try std.fmt.allocPrint(a, "{s}|{s}|{s}\n", .{ cid, if (found) "1" else "0", form });
    try self.conts.appendSlice(std.heap.page_allocator, line);
}
fn containerForm(self: *Fake, a: std.mem.Allocator, cid: []const u8) ?[]const u8 {
    self.mu.lockUncancelable(self.io);
    defer self.mu.unlock(self.io);
    var it = std.mem.splitScalar(u8, self.conts.items, '\n');
    while (it.next()) |l| {
        const p = std.mem.indexOfScalar(u8, l, '|') orelse continue;
        if (std.mem.eql(u8, l[0..p], cid)) return a.dupe(u8, l[p + 1 ..]) catch null;
    }
    return null;
}
fn makePost(self: *Fake, a: std.mem.Allocator, cid: []const u8) !void {
    const f = containerForm(self, a, cid) orelse return;
    const form = f[std.mem.indexOfScalar(u8, f, '|').? + 1 ..];
    const txt = field(a, form, "text");
    const esc = try std.json.Stringify.valueAlloc(a, txt, .{});
    self.mu.lockUncancelable(self.io);
    defer self.mu.unlock(self.io);
    if (self.posts.items.len > 0) try self.posts.append(std.heap.page_allocator, ',');
    const item = try std.fmt.allocPrint(a, "{{\"id\":\"9001\",\"permalink\":\"https://www.threads.com/@testuser/post/ABC{s}\",\"text\":{s},\"timestamp\":\"2099-01-01T00:00:00+0000\",\"media_type\":\"VIDEO\",\"cid\":\"{s}\"}}", .{ cid, esc, cid });
    try self.posts.appendSlice(std.heap.page_allocator, item);
}
fn isPosted(self: *Fake, a: std.mem.Allocator, cid: []const u8) bool {
    self.mu.lockUncancelable(self.io);
    defer self.mu.unlock(self.io);
    const needle = std.fmt.allocPrint(a, "\"cid\":\"{s}\"", .{cid}) catch return false;
    return std.mem.indexOf(u8, self.posts.items, needle) != null;
}
fn postJson(self: *Fake, a: std.mem.Allocator, id: []const u8) ![]const u8 {
    self.mu.lockUncancelable(self.io);
    defer self.mu.unlock(self.io);
    if (self.posts.items.len == 0) return "{\"id\":\"9001\",\"permalink\":\"https://www.threads.com/@testuser/post/ABC\",\"text\":\"\",\"media_type\":\"VIDEO\"}";
    _ = id;
    const end = std.mem.indexOf(u8, self.posts.items, "},{") orelse self.posts.items.len - 1;
    return try a.dupe(u8, self.posts.items[0 .. end + 1]);
}

fn serveFile(self: *Fake, a: std.mem.Allocator, w: *Io.Writer, name: []const u8, range: []const u8, head_only: bool) !void {
    if (self.redirect_host) return reply(w, .{ .status = 302, .headers = "Location: https://elsewhere.example/x\r\n" }, "");
    if (self.big_error_page) return reply(w, .{ .status = 404, .body = "x" ** 6000 }, "");
    if (std.mem.indexOfAny(u8, name, "/\\") != null or name.len == 0) return reply(w, .{ .status = 404 }, "");
    const fp = try std.fmt.allocPrint(a, "{s}/{s}", .{ self.host_root, name });
    const f = Io.Dir.cwd().openFile(self.io, fp, .{}) catch return reply(w, .{ .status = 404 }, "");
    defer f.close(self.io);
    const size = try f.length(self.io);
    if (self.big_error_page) return reply(w, .{ .status = 404, .body = "x" ** 6000 }, "");
    if (head_only) {
        if (self.no_head) return reply(w, .{ .status = 405 }, "");
        try w.print("HTTP/1.1 200 X\r\nConnection: close\r\nContent-Length: {d}\r\n\r\n", .{size});
        return w.flush();
    }
    if (std.mem.startsWith(u8, range, "bytes=") and !self.ignore_range) {
        const hd = try std.fmt.allocPrint(a, "Content-Range: bytes 0-1/{d}\r\n", .{size});
        var two: [2]u8 = undefined;
        const n = try f.readPositionalAll(self.io, &two, 0);
        return reply(w, .{ .status = 206, .headers = hd, .body = two[0..n] }, "");
    }
    // whole file (small test files only)
    const buf = try a.alloc(u8, @intCast(@min(size, 8 << 20)));
    const n = try f.readPositionalAll(self.io, buf, 0);
    return reply(w, .{ .body = buf[0..n] }, "");
}
