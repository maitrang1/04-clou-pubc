// =====================================================================
// Des: A fake Google for tests - OAuth token endpoint plus the Vimeo calls the app makes (resumable upload, session query, video status, channel, uploads, categories) with knobs to break each one on purpose
// Flo: loopback server > route by method and path > check the Bearer token > answer from knobs and recorded state (sessions, bytes, hashes) > count every call
// Cre: 2026-11-15                          - | Mod: 2026-11-15
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: a Fake struct (knobs) and a running te-mini-srv
// Out: HTTP answers like Google's; counters and recorded uploads for the tests to check
// Run: not run directly - tests only, never shipped logic
// =====================================================================
const std = @import("std");
const ms = @import("te-mini-srv.zig");

pub const StartMode = enum { ok, quota, channel_limit, forbidden, invalid_title, srv_503_once, srv_503_always };
pub const PutMode = enum { ok, drop_after_complete, expire_after_complete, srv_503_once };

pub const Seg = struct { len: u64 = 0, sha: [32]u8 = @splat(0) };
pub const Session = struct {
    total: u64 = 0,
    stored: u64 = 0,
    completed: bool = false,
    expired: bool = false,
    vid: [16]u8 = @splat(0),
    vid_len: usize = 0,
    segs: [4]Seg = .{ .{}, .{}, .{}, .{} },
    seg_n: usize = 0,
};

pub const Counts = struct { token: u32 = 0, start: u32 = 0, put: u32 = 0, ask: u32 = 0, status: u32 = 0, channel: u32 = 0, list: u32 = 0, cats: u32 = 0, other: u32 = 0 };

pub const Fake = struct {
    // knobs
    refresh_ok: []const u8 = "RT-GOOD",
    invalid_grant: bool = false,
    start_mode: StartMode = .ok,
    put_mode: PutMode = .ok,
    status_script: []const []const u8 = &.{"processed"},
    channel_none: bool = false,
    listing_on: bool = true,
    bad_range: bool = false, // a 308 whose Range points past the end of the file
    put_401_once: bool = false, // the first PUT is refused with 401 whatever the token
    reject_tokens_up_to: u32 = 0, // tokens AT-1..AT-n get 401
    challenge: []const u8 = "", // expected PKCE challenge (S256 of the verifier), "" = unchecked
    // state
    port: u16 = 0,
    counts: Counts = .{},
    tokens_issued: u32 = 0,
    sessions: [4]Session = .{ .{}, .{}, .{}, .{} },
    sess_n: usize = 0,
    used_503: bool = false,
    used_401: bool = false,
    meta: [4096]u8 = undefined,
    meta_len: usize = 0,
    last_start_head: [1024]u8 = undefined,
    last_start_head_len: usize = 0,
    last_start_path: [512]u8 = undefined,
    last_start_path_len: usize = 0,
    saw_token_in_url: bool = false,

    pub fn metaStr(self: *const Fake) []const u8 {
        return self.meta[0..self.meta_len];
    }
};

fn formValue(body: []const u8, key: []const u8) []const u8 {
    var it = std.mem.tokenizeScalar(u8, body, '&');
    while (it.next()) |kv| {
        const eq = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
        if (std.mem.eql(u8, kv[0..eq], key)) return kv[eq + 1 ..];
    }
    return "";
}

fn gErr(a: std.mem.Allocator, status: u16, reason: []const u8) ms.Reply {
    const b = std.fmt.allocPrint(a, "{{\"error\":{{\"code\":{d},\"message\":\"fake\",\"errors\":[{{\"reason\":\"{s}\",\"domain\":\"fake\"}}]}}}}", .{ status, reason }) catch "{}";
    return .{ .status = status, .body = b, .headers = "Content-Type: application/json\r\n" };
}

fn json(body: []const u8) ms.Reply {
    return .{ .body = body, .headers = "Content-Type: application/json\r\n" };
}

fn tokenOk(f: *Fake, head: []const u8) bool {
    const h = ms.headerOf(head, "authorization");
    if (!std.mem.startsWith(u8, h, "Bearer AT-")) return false;
    const n = std.fmt.parseInt(u32, h["Bearer AT-".len..], 10) catch return false;
    return n > f.reject_tokens_up_to;
}

fn rangeStart(head: []const u8) u64 {
    const cr = ms.headerOf(head, "content-range");
    if (!std.mem.startsWith(u8, cr, "bytes ")) return 0;
    const rest = cr[6..];
    const dash = std.mem.indexOfScalar(u8, rest, '-') orelse return 0;
    return std.fmt.parseInt(u64, rest[0..dash], 10) catch 0;
}

fn videoJson(a: std.mem.Allocator, s: *const Session) []const u8 {
    return std.fmt.allocPrint(a, "{{\"kind\":\"vimeo#video\",\"id\":\"{s}\"}}", .{s.vid[0..s.vid_len]}) catch "{}";
}

pub fn handler(ctx: *anyopaque, a: std.mem.Allocator, req: ms.Request) ms.Reply {
    const f: *Fake = @ptrCast(@alignCast(ctx));
    const path = req.path;
    if (std.mem.indexOf(u8, path, "access_token=") != null or std.mem.indexOf(u8, path, "Bearer") != null) f.saw_token_in_url = true;
    // ---- oauth ----
    if (std.mem.startsWith(u8, path, "/token")) {
        f.counts.token += 1;
        const grant = formValue(req.body, "grant_type");
        if (f.invalid_grant) return .{ .status = 400, .body = "{\"error\":\"invalid_grant\",\"error_description\":\"Token has been expired or revoked.\"}", .headers = "Content-Type: application/json\r\n" };
        if (std.mem.eql(u8, grant, "refresh_token")) {
            if (!std.mem.eql(u8, formValue(req.body, "refresh_token"), f.refresh_ok)) return .{ .status = 400, .body = "{\"error\":\"invalid_grant\"}", .headers = "Content-Type: application/json\r\n" };
            f.tokens_issued += 1;
            return json(std.fmt.allocPrint(a, "{{\"access_token\":\"AT-{d}\",\"expires_in\":3599,\"token_type\":\"Bearer\"}}", .{f.tokens_issued}) catch "{}");
        }
        if (std.mem.eql(u8, grant, "authorization_code")) {
            if (!std.mem.eql(u8, formValue(req.body, "code"), "CODE-1")) return .{ .status = 400, .body = "{\"error\":\"invalid_grant\"}", .headers = "Content-Type: application/json\r\n" };
            if (f.challenge.len > 0) {
                var h: [32]u8 = undefined;
                std.crypto.hash.sha2.Sha256.hash(formValue(req.body, "code_verifier"), &h, .{});
                const enc = std.base64.url_safe_no_pad.Encoder;
                var out: [64]u8 = undefined;
                const c = enc.encode(&out, &h);
                if (!std.mem.eql(u8, c, f.challenge)) return .{ .status = 400, .body = "{\"error\":\"invalid_grant\",\"error_description\":\"bad verifier\"}", .headers = "Content-Type: application/json\r\n" };
            }
            f.tokens_issued += 1;
            return json(std.fmt.allocPrint(a, "{{\"access_token\":\"AT-{d}\",\"refresh_token\":\"RT-NEW\",\"expires_in\":3599,\"token_type\":\"Bearer\"}}", .{f.tokens_issued}) catch "{}");
        }
        return .{ .status = 400, .body = "{\"error\":\"unsupported_grant_type\"}" };
    }
    // ---- everything else needs a good bearer token ----
    if (!tokenOk(f, req.head)) return gErr(a, 401, "authError");

    // ---- start a resumable session ----
    if (std.mem.eql(u8, req.method, "POST") and std.mem.startsWith(u8, path, "/upload/vimeo/v3/videos")) {
        f.counts.start += 1;
        const nh = @min(req.head.len, f.last_start_head.len);
        @memcpy(f.last_start_head[0..nh], req.head[0..nh]);
        f.last_start_head_len = nh;
        const np = @min(path.len, f.last_start_path.len);
        @memcpy(f.last_start_path[0..np], path[0..np]);
        f.last_start_path_len = np;
        const nm = @min(req.body.len, f.meta.len);
        @memcpy(f.meta[0..nm], req.body[0..nm]);
        f.meta_len = nm;
        switch (f.start_mode) {
            .quota => return gErr(a, 403, "quotaExceeded"),
            .channel_limit => return gErr(a, 400, "uploadLimitExceeded"),
            .forbidden => return gErr(a, 403, "forbidden"),
            .invalid_title => return gErr(a, 400, "invalidTitle"),
            .srv_503_always => return .{ .status = 503, .body = "{}" },
            .srv_503_once => if (!f.used_503) {
                f.used_503 = true;
                return .{ .status = 503, .body = "{}" };
            },
            .ok => {},
        }
        const total = std.fmt.parseInt(u64, ms.headerOf(req.head, "x-upload-content-length"), 10) catch return gErr(a, 400, "mediaBodyRequired");
        if (ms.headerOf(req.head, "x-upload-content-type").len == 0) return gErr(a, 400, "invalidVideoMetadata");
        if (f.sess_n >= f.sessions.len) return gErr(a, 400, "uploadLimitExceeded");
        f.sessions[f.sess_n] = .{ .total = total };
        const loc = std.fmt.allocPrint(a, "Location: http://127.0.0.1:{d}/upload/session/{d}\r\n", .{ f.port, f.sess_n }) catch "";
        f.sess_n += 1;
        return .{ .status = 200, .headers = loc, .body = "" };
    }
    // ---- the session: bytes or a question ----
    if (std.mem.eql(u8, req.method, "PUT") and std.mem.startsWith(u8, path, "/upload/session/")) {
        const idx = std.fmt.parseInt(usize, path["/upload/session/".len..], 10) catch return .{ .status = 404 };
        if (idx >= f.sess_n) return .{ .status = 404 };
        const s = &f.sessions[idx];
        if (req.clen == 0) {
            f.counts.ask += 1;
            if (s.expired) return .{ .status = 404 };
            if (s.completed) return .{ .status = 200, .body = videoJson(a, s), .headers = "Content-Type: application/json\r\n" };
            if (s.stored == 0) return .{ .status = 308 };
            return .{ .status = 308, .headers = std.fmt.allocPrint(a, "Range: bytes=0-{d}\r\n", .{s.stored - 1}) catch "" };
        }
        f.counts.put += 1;
        if (f.put_401_once and !f.used_401) {
            f.used_401 = true;
            return gErr(a, 401, "authError");
        }
        if (f.bad_range) return .{ .status = 308, .headers = std.fmt.allocPrint(a, "Range: bytes=0-{d}\r\n", .{s.total + 999}) catch "" };
        if (f.put_mode == .srv_503_once and !f.used_503) {
            f.used_503 = true;
            return .{ .status = 503, .body = "{}" };
        }
        const start = rangeStart(req.head);
        if (start != s.stored) return gErr(a, 400, "invalidVideoMetadata");
        if (s.seg_n < s.segs.len) {
            s.segs[s.seg_n] = .{ .len = req.body_len, .sha = req.body_sha };
            s.seg_n += 1;
        }
        s.stored += req.body_len;
        if (req.partial) return .{ .close_early = true };
        if (s.stored >= s.total) {
            s.completed = true;
            const id = std.fmt.bufPrint(&s.vid, "vid{d}", .{idx + 1}) catch "vid";
            s.vid_len = id.len;
            switch (f.put_mode) {
                .drop_after_complete => return .{ .close_early = true },
                .expire_after_complete => {
                    s.expired = true;
                    return .{ .close_early = true };
                },
                else => return .{ .status = 201, .body = videoJson(a, s), .headers = "Content-Type: application/json\r\n" },
            }
        }
        return .{ .status = 308, .headers = std.fmt.allocPrint(a, "Range: bytes=0-{d}\r\n", .{s.stored - 1}) catch "" };
    }
    // ---- video status ----
    if (std.mem.startsWith(u8, path, "/vimeo/v3/videos?")) {
        f.counts.status += 1;
        const i: usize = @min(f.counts.status - 1, f.status_script.len - 1);
        const e = f.status_script[i];
        if (std.mem.eql(u8, e, "notfound")) return json("{\"items\":[]}");
        var st = e;
        var reason: []const u8 = "";
        if (std.mem.indexOfScalar(u8, e, ':')) |c| {
            st = e[0..c];
            reason = e[c + 1 ..];
        }
        const field: []const u8 = if (std.mem.eql(u8, st, "failed")) "failureReason" else "rejectionReason";
        const extra = if (reason.len > 0) std.fmt.allocPrint(a, ",\"{s}\":\"{s}\"", .{ field, reason }) catch "" else "";
        const proc: []const u8 = if (std.mem.eql(u8, st, "processed")) "succeeded" else if (std.mem.eql(u8, st, "failed")) "failed" else "processing";
        return json(std.fmt.allocPrint(a, "{{\"items\":[{{\"id\":\"vid1\",\"status\":{{\"uploadStatus\":\"{s}\",\"privacyStatus\":\"private\"{s}}},\"processingDetails\":{{\"processingStatus\":\"{s}\"}}}}]}}", .{ st, extra, proc }) catch "{}");
    }
    if (std.mem.startsWith(u8, path, "/vimeo/v3/channels?")) {
        f.counts.channel += 1;
        if (f.channel_none) return json("{\"items\":[]}");
        return json("{\"items\":[{\"id\":\"UC1\",\"contentDetails\":{\"relatedPlaylists\":{\"uploads\":\"UU1\"}}}]}");
    }
    if (std.mem.startsWith(u8, path, "/vimeo/v3/playlistItems?")) {
        f.counts.list += 1;
        var found: ?*const Session = null;
        var k: usize = f.sess_n;
        while (k > 0) {
            k -= 1;
            if (f.sessions[k].completed) {
                found = &f.sessions[k];
                break;
            }
        }
        if (found == null or !f.listing_on) return json("{\"items\":[]}");
        const title = titleOf(f.metaStr());
        return json(std.fmt.allocPrint(a, "{{\"items\":[{{\"snippet\":{{\"title\":\"{s}\",\"publishedAt\":\"2099-01-01T00:00:00Z\",\"resourceId\":{{\"videoId\":\"{s}\"}}}}}}]}}", .{ title, found.?.vid[0..found.?.vid_len] }) catch "{}");
    }
    if (std.mem.startsWith(u8, path, "/vimeo/v3/videoCategories")) {
        f.counts.cats += 1;
        return json("{\"items\":[{\"id\":\"2\",\"snippet\":{\"title\":\"Autos & Vehicles\",\"assignable\":true}},{\"id\":\"29\",\"snippet\":{\"title\":\"Nonprofits\",\"assignable\":false}}]}");
    }
    f.counts.other += 1;
    return .{ .status = 404 };
}

// the "title" value out of the recorded start body (no escapes in test titles)
pub fn titleOf(meta: []const u8) []const u8 {
    const k = "\"title\":\"";
    const i = std.mem.indexOf(u8, meta, k) orelse return "";
    const rest = meta[i + k.len ..];
    const e = std.mem.indexOfScalar(u8, rest, '"') orelse return "";
    return rest[0..e];
}

pub fn serve(io: std.Io, f: *Fake) !*ms.Srv {
    const srv = try ms.Srv.start(io, handler, f);
    f.port = srv.port;
    return srv;
}

test "fake: token, start, ask, upload, status over real http" {
    const net = @import("co-net.zig");
    const guard = @import("co-guard.zig");
    var f = Fake{};
    const srv = try serve(std.testing.io, &f);
    defer srv.stop();
    var ar = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = ar.allocator();
    const Io = std.Io;
    const ip = try Io.net.IpAddress.parse("127.0.0.1", srv.port);
    var ub: [128]u8 = undefined;
    const t = try guard.parseUrl(a, srv.url(&ub, "/token"), .{ .allow_hosts = &.{}, .mock = true });
    const body = "grant_type=refresh_token&refresh_token=RT-GOOD&client_id=x";
    const r = try net.call(std.testing.io, a, t, ip, .{ .ua = "t", .timeout_s = 5, .cap_bytes = 4096, .method = "POST", .body = .{ .bytes = body } });
    try std.testing.expectEqual(@as(u16, 200), r.status);
    try std.testing.expect(std.mem.indexOf(u8, r.body, "AT-1") != null);
    try std.testing.expectEqual(@as(u32, 1), f.counts.token);
    // no token = 401
    const t2 = try guard.parseUrl(a, srv.url(&ub, "/vimeo/v3/channels?part=x"), .{ .allow_hosts = &.{}, .mock = true });
    const r2 = try net.call(std.testing.io, a, t2, ip, .{ .ua = "t", .timeout_s = 5, .cap_bytes = 4096 });
    try std.testing.expectEqual(@as(u16, 401), r2.status);
    try std.testing.expectEqualStrings("T", titleOf("{\"snippet\":{\"title\":\"T\"}}"));
}
// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
