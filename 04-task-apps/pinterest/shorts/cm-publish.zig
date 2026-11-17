// publish: oldest ready pair -> register media -> upload (multipart, streamed) -> confirm -> create Pin -> ledger. Dry-run unless --live.
// Order is the safety: the ledger row (with the media id) exists before the first byte; Pin create is the point of no return (a lost answer after it = unsure).
const std = @import("std");
const Ctx = @import("co-ctx.zig").Ctx;
const args = @import("co-args.zig");
const exit = @import("co-exit.zig");
const kill = @import("co-kill.zig");
const log = @import("co-log.zig");
const out = @import("co-out.zig");
const os = @import("co-os.zig");
const util = @import("co-util.zig");
const call = @import("ap-call.zig");
const auth = @import("ap-auth.zig");
const media_api = @import("ap-media.zig");
const multi_api = @import("ap-multi.zig");
const pin_api = @import("ap-pin.zig");
const sq = @import("rw-sqlite.zig");
const send = @import("rw-send.zig");
const caps = @import("rw-caps.zig");
const pair = @import("rw-pair.zig");
const text = @import("rw-text.zig");

pub const Result = struct { code: u8, state: []const u8, name: []const u8 = "", video_id: []const u8 = "", url: []const u8 = "", note: []const u8 = "" }; // video_id = the Pinterest media id

fn res(code: u8, state: []const u8, note: []const u8) Result {
    return .{ .code = code, .state = state, .note = note };
}

pub fn run(cx: *Ctx, av: []const []const u8) u8 {
    var arena = std.heap.ArenaAllocator.init(cx.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const r = runInner(cx, a, av) catch |e| switch (e) {
        error.Crash => return 99,
        else => res(exit.BLOCKED, "blocked", std.fmt.allocPrint(a, "ledger or folder problem, run stopped: {s}", .{@errorName(e)}) catch "ledger problem, run stopped"),
    };
    report(cx, a, r);
    return r.code;
}

fn report(cx: *const Ctx, a: std.mem.Allocator, r: Result) void {
    out.say(cx, "{s}{s}{s}{s}{s}", .{ r.state, if (r.name.len > 0) ": " else "", r.name, if (r.note.len > 0) " | " else "", r.note });
    if (r.url.len > 0) out.say(cx, "url: {s}", .{r.url});
    out.json(cx, a, .{ .state = r.state, .name = r.name, .media_id = r.video_id, .url = r.url, .note = r.note, .exit = r.code });
}

const Plan = struct { name: []const u8, pkey: []const u8, mp4: []const u8, size: u64, board: []const u8, title: ?[]const u8, description: []const u8, link: ?[]const u8, ai_disclosures: []const []const u8, cover: []const u8, steps: []const []const u8, note: []const u8 };

fn runInner(cx: *Ctx, a: std.mem.Allocator, av: []const []const u8) !Result {
    const want = args.value(av, "--video");
    const again = args.has(av, "--again");
    if (args.has(av, "--video") and want == null) return res(exit.USAGE, "usage", "--video needs a name");
    if (kill.killOn(cx)) return res(exit.BLOCKED, "blocked", "kill file is on (config: kill --off --live to clear)");
    var lock: ?kill.Lock = null;
    if (cx.live) lock = kill.acquire(cx) catch |e| return res(exit.BLOCKED, "blocked", if (e == error.Busy) "another run is active" else "cannot take the run lock");
    defer if (lock) |*l| l.release();
    if (cx.live and !args.has(av, "--init")) {
        // a missing ledger next to other traces of an earlier install = wrong folder or lost file: caps and history would reset
        const lp = try send.dbPath(cx, a);
        if (!util.exists(cx.io, lp)) {
            const traces = [_][]const u8{ "run.jsonl", "KILL", "backup" };
            for (traces) |t| if (util.exists(cx.io, try cx.dataPath(a, t))) return res(exit.BLOCKED, "blocked", "the ledger is missing but this folder has older files: wrong data_dir/home, or a lost file. Restore it, or add --init to start fresh");
        }
    }
    var db = try send.open(cx);
    defer db.close();
    call.resetUsage();
    defer if (cx.live) caps.addCalls(cx, &db, call.calls_made) catch {}; // count every API call toward the day budget
    if (cx.live) {
        const n = try send.recover(cx, &db);
        if (n > 0) log.log(cx, "warn", "{d} send(s) found mid-flight: unsure (Pin create started) or failed (it never started)", .{n});
    }
    if (try caps.blocked(cx, &db, a)) |b| return res(exit.BLOCKED, "blocked", b.why);
    if (cx.cfg.limits.disk_min_mb > 0) {
        const dd = try cx.dataPath(a, "");
        if (os.diskFreeMb(a, std.mem.trimEnd(u8, dd, "/"))) |mb| if (mb < cx.cfg.limits.disk_min_mb) return res(exit.BLOCKED, "blocked", try std.fmt.allocPrint(a, "disk low: {d} MB free (min {d})", .{ mb, cx.cfg.limits.disk_min_mb }));
    }
    const entries = pair.scan(cx, a, &db) catch |e| return res(exit.USAGE, "config", if (e == error.NoSourceDir) "source.dir is not set or cannot be opened" else "cannot read the source folder");
    var pick: ?pair.Entry = null;
    if (want) |name| {
        const e = pair.find(entries, name) orelse return res(exit.FAILED, "failed", "no such pair in the source folder");
        switch (e.kind) {
            .ready => pick = e,
            .held => return .{ .code = exit.BLOCKED, .state = "held", .name = e.name, .note = e.reason },
            .invalid, .skipped => return .{ .code = exit.FAILED, .state = "invalid", .name = e.name, .note = e.reason },
            .done => {
                if (std.mem.eql(u8, e.reason, "failed") and again) pick = e else return replay(a, &db, e);
            },
        }
    } else {
        for (entries) |e| if (e.kind == .ready) {
            pick = e;
            break;
        };
    }
    const e = pick orelse {
        var held: usize = 0;
        var bad: usize = 0;
        for (entries) |x| {
            if (x.kind == .held) held += 1;
            if (x.kind == .invalid) bad += 1;
        }
        return res(exit.NOTHING, "nothing", try std.fmt.allocPrint(a, "no ready pair ({d} held, {d} invalid)", .{ held, bad }));
    };
    const cap = text.build(a, .{ .hooks = e.j.hooks, .description = e.j.description, .hashtags = e.j.hashtags, .ai_notice = e.j.ai_notice }, .{ .desc_max = cx.cfg.post.desc_max, .title_max = cx.cfg.post.title_max, .tags_max = cx.cfg.post.tags_max, .notice_required = cx.cfg.post.ai_notice_required }) catch |er| return .{ .code = exit.FAILED, .state = "refused", .name = e.name, .note = if (er == error.NoNotice) "no ai_notice in the json: every post must carry it" else "text cannot be built within the Pinterest limits" };
    const alt: ?[]const u8 = if (cap.title) |t| text.cut(t, cx.cfg.post.alt_max) else null;
    const link: ?[]const u8 = linkOf(cx, e.j.listing_url);
    const cover = coverOf(cx, a, e);
    const board = cx.boardId() orelse return res(exit.USAGE, "config", if (cx.cfg.post.public) "no public board id: set the env var or file named in config account.board_public_*" else "no SECRET board id: set the env var or file named in config account.board_secret_* (the safe default; post.public=false never writes to a public board)");
    if (!cx.live) {
        const steps = [_][]const u8{ "register media", "upload (multipart)", "confirm media", "create Pin" };
        const p = Plan{ .name = e.name, .pkey = e.pkey, .mp4 = e.mp4_path, .size = e.size, .board = if (cx.cfg.post.public) "public board" else "secret board", .title = cap.title, .description = cap.description, .link = link, .ai_disclosures = cx.cfg.post.ai_values, .cover = if (cover == .key_frame) "key frame" else "image file", .steps = &steps, .note = "dry-run: nothing sent" };
        out.say(cx, "dry-run: would publish '{s}' ({d} MB) to the {s}\n  title: {s}\n  text: {s}\n  nothing was sent. Add --live to send.", .{ e.name, e.size / (1024 * 1024), p.board, cap.title orelse "(none)", cap.description });
        out.json(cx, a, p);
        return .{ .code = exit.OK, .state = "dry-run", .name = e.name, .note = "nothing sent" };
    }
    const tok: []const u8 = switch (auth.ensure(cx, a, true)) {
        .ok => |t| t,
        .fail => |f| return res(exit.BLOCKED, "blocked", f.msg),
    };
    return sendOne(cx, a, &db, e, cap, alt, link, cover, board, tok, again);
}

// listing_url becomes the Pin link only when it is a plain http(s) address within the limit; else no link (never invented)
fn linkOf(cx: *const Ctx, u: []const u8) ?[]const u8 {
    const t = std.mem.trim(u8, u, " \r\n\t");
    if (t.len == 0 or t.len > cx.cfg.post.link_max) return null;
    if (!std.mem.startsWith(u8, t, "https://") and !std.mem.startsWith(u8, t, "http://")) return null;
    if (std.mem.indexOfAny(u8, t, " \r\n\t\"") != null) return null;
    return t;
}

// cover: a key frame by default; with cover_mode=data an image file beside the mp4 (name.jpg / name.png, up to 2 MB) is sent as base64
fn coverOf(cx: *const Ctx, a: std.mem.Allocator, e: pair.Entry) pin_api.Cover {
    const kf = pin_api.Cover{ .key_frame = cx.cfg.post.cover_key_frame_s };
    if (!std.mem.eql(u8, cx.cfg.post.cover_mode, "data")) return kf;
    if (!std.mem.endsWith(u8, e.mp4_path, ".mp4")) return kf;
    const stem = e.mp4_path[0 .. e.mp4_path.len - 4];
    const exts = [_]struct { x: []const u8, t: []const u8 }{ .{ .x = ".jpg", .t = "image/jpeg" }, .{ .x = ".png", .t = "image/png" } };
    for (exts) |x| {
        const p = std.fmt.allocPrint(a, "{s}{s}", .{ stem, x.x }) catch continue;
        const raw = util.readAll(a, cx.io, p, 2 * 1024 * 1024) catch continue;
        const enc = std.base64.standard.Encoder;
        const b = a.alloc(u8, enc.calcSize(raw.len)) catch continue;
        return .{ .data = .{ .b64 = enc.encode(b, raw), .content_type = x.t } };
    }
    return kf;
}

// a pair already in the ledger: answer from it, never send again
fn replay(a: std.mem.Allocator, db: *sq.Db, e: pair.Entry) !Result {
    const row = (try send.byPkey(db, a, e.pkey)) orelse return res(exit.FAILED, "failed", "ledger row vanished");
    const code: u8 = switch (row.state) {
        .posted => exit.OK,
        .unsure, .sending => exit.UNSURE,
        .failed => exit.FAILED,
    };
    const note = if (row.state == .failed) try std.fmt.allocPrint(a, "failed earlier ({s}); a person can retry with --again", .{row.note}) else row.note;
    return .{ .code = code, .state = if (row.state == .posted) "already-posted" else send.stateName(row.state), .name = e.name, .video_id = row.video_id, .url = row.url, .note = note };
}

fn finishRow(cx: *Ctx, db: *sq.Db, id: i64, name: []const u8, st: send.State, code: u8, note: []const u8, vid: []const u8, post_id: []const u8, url: []const u8) !Result {
    const nn = text.safeNote(std.heap.page_allocator, note, 400);
    try send.setState(cx, db, id, st, nn, post_id, url);
    log.log(cx, "info", "{s} {s}: {s}", .{ name, send.stateName(st), nn });
    return .{ .code = code, .state = send.stateName(st), .name = name, .video_id = vid, .url = url, .note = nn };
}

// what a failed call means for the row and the run
fn failRow(cx: *Ctx, a: std.mem.Allocator, db: *sq.Db, id: i64, name: []const u8, vid: []const u8, f: call.Fail, stage: []const u8) !Result {
    const note = try std.fmt.allocPrint(a, "{s}: {s} (code {d}, http {d}) {s}", .{ stage, f.info.msg, f.info.code, f.http, f.body[0..@min(f.body.len, 200)] });
    switch (f.info.class) {
        .blocked => return finishRow(cx, db, id, name, .failed, exit.BLOCKED, note, vid, "", ""),
        .breaker => {
            try caps.hardStop(db);
            return finishRow(cx, db, id, name, .failed, exit.BLOCKED, note, vid, "", "");
        },
        .stop_day => {
            const ms = @max(caps.quotaBlockMs(cx), @as(i64, call.usage_regain) * 60_000);
            try caps.blockFor(db, cx.nowMs(), ms, "HTTP 429");
            return finishRow(cx, db, id, name, .failed, exit.BLOCKED, note, vid, "", "");
        },
        else => {
            try caps.recordFail(cx, db);
            return finishRow(cx, db, id, name, .failed, exit.FAILED, note, vid, "", "");
        },
    }
}

fn usageStop(cx: *Ctx, a: std.mem.Allocator, db: *sq.Db) !void {
    if (call.usage_pct >= cx.cfg.limits.usage_stop_pct) {
        const ms = @max(@as(i64, call.usage_regain) * 60_000, 3600_000);
        try caps.blockFor(db, cx.nowMs(), ms, try std.fmt.allocPrint(a, "usage {d}%", .{call.usage_pct}));
    }
}

const PollEnd = union(enum) { ok, failed: []const u8, timeout, fail: call.Fail };

// ask the media status until succeeded / failed; bounded by net.status_poll_max_s
fn pollMedia(cx: *Ctx, a: std.mem.Allocator, tok: []const u8, mid: []const u8) PollEnd {
    const iters = @max(1, cx.cfg.net.status_poll_max_s / cx.cfg.net.status_poll_s);
    var i: u32 = 0;
    while (i < iters) : (i += 1) {
        switch (media_api.get(cx, a, tok, mid)) {
            .fail => |f| if (f.info.class != .retry) return .{ .fail = f },
            .ok => |s| switch (s.verdict) {
                .succeeded => return .ok,
                .failed => return .{ .failed = s.raw[0..@min(s.raw.len, 160)] },
                else => {},
            },
        }
        cx.sleepMs(@as(i64, cx.cfg.net.status_poll_s) * 1000);
    }
    return .timeout;
}

fn sendOne(cx: *Ctx, a: std.mem.Allocator, db: *sq.Db, e: pair.Entry, cap: text.Caption, alt: ?[]const u8, link: ?[]const u8, cover: pin_api.Cover, board: []const u8, tok: []const u8, again: bool) !Result {
    const t0 = util.monoMs(cx.io);
    const budget_ms = @as(i64, cx.cfg.limits.run_budget_s) * 1000;
    // 1 register the media (pre-send failures may retry)
    var attempt: u32 = 0;
    var sess: media_api.Session = while (true) {
        switch (media_api.register(cx, a, tok)) {
            .ok => |s| break s,
            .fail => |f| {
                if (f.info.class == .retry and attempt < cx.cfg.retry_pre_send) {
                    attempt += 1;
                    cx.sleepMs(@as(i64, cx.cfg.net.backoff_ms) * attempt);
                    continue;
                }
                // a dead token or a Pinterest limit at register: nothing to burn a pair for. Stop the run, leave the pair ready
                if (f.info.class == .blocked or f.info.class == .stop_day or f.info.class == .breaker) {
                    if (f.info.class == .breaker) try caps.hardStop(db);
                    if (f.info.class == .stop_day) try caps.blockFor(db, cx.nowMs(), @max(caps.quotaBlockMs(cx), @as(i64, call.usage_regain) * 60_000), "HTTP 429");
                    return res(exit.BLOCKED, "blocked", try std.fmt.allocPrint(a, "register: {s} (code {d}, http {d}); the pair stays ready", .{ f.info.msg, f.info.code, f.http }));
                }
                // nothing was uploaded. A transient problem leaves no row (next run tries again); a final answer gets a row so a bad pair is not retried forever
                if (f.info.class == .retry) {
                    try caps.recordFail(cx, db);
                    return res(exit.FAILED, "failed", try std.fmt.allocPrint(a, "register: {s} (http {d}), will try again next run", .{ f.info.msg, f.http }));
                }
                const id = send.begin(cx, db, a, e.name, e.pkey, "", again) catch |er| if (er == error.Replay) return replay(a, db, e) else return er;
                return failRow(cx, a, db, id, e.name, "", f, "register");
            },
        }
    };
    if (call.usage_pct >= cx.cfg.limits.usage_stop_pct) { // too close to Pinterest's limit: stop before any byte goes up
        try usageStop(cx, a, db);
        return res(exit.BLOCKED, "blocked", try std.fmt.allocPrint(a, "usage {d}% of Pinterest's allowance: stopped before upload", .{call.usage_pct}));
    }
    // 2 ledger row with the media id, BEFORE the first byte
    const id = send.begin(cx, db, a, e.name, e.pkey, sess.media_id, again) catch |er| if (er == error.Replay) return replay(a, db, e) else return er;
    if (cx.crash_at == 1) return error.Crash;
    // 3 upload, streamed. No resume protocol exists: a cut upload registers a fresh media and starts over (bounded by net.resume_max)
    var tries: u32 = 0;
    while (true) {
        if (util.monoMs(cx.io) - t0 > budget_ms) return finishRow(cx, db, id, e.name, .failed, exit.FAILED, "run budget used up during upload", sess.media_id, "", "");
        switch (multi_api.upload(cx, a, sess, e.mp4_path, e.size)) {
            .ok => break,
            .fail => |f| {
                const retryable = f.info.class == .retry;
                if (!retryable) return failRow(cx, a, db, id, e.name, sess.media_id, f, "upload");
                if (tries >= cx.cfg.net.resume_max) return failRow(cx, a, db, id, e.name, sess.media_id, .{ .info = .{ .class = .failed, .msg = "upload gave up after retries" }, .http = f.http, .net = f.net, .body = f.body }, "upload");
                tries += 1;
                cx.sleepMs(@as(i64, cx.cfg.net.backoff_ms) * tries);
                switch (media_api.register(cx, a, tok)) {
                    .ok => |s| {
                        sess = s;
                        try send.setVideo(db, id, s.media_id);
                    },
                    .fail => |rf| if (rf.info.class != .retry) return failRow(cx, a, db, id, e.name, sess.media_id, rf, "register"),
                }
            },
        }
    }
    if (cx.crash_at == 2) return error.Crash;
    // 4 wait until Pinterest has processed the file
    switch (pollMedia(cx, a, tok, sess.media_id)) {
        .ok => {},
        .fail => |f| return failRow(cx, a, db, id, e.name, sess.media_id, f, "media status"),
        .timeout => return finishRow(cx, db, id, e.name, .failed, exit.FAILED, "Pinterest did not confirm the upload in time (nothing published)", sess.media_id, "", ""),
        .failed => |raw| {
            try caps.recordFail(cx, db);
            return finishRow(cx, db, id, e.name, .failed, exit.FAILED, try std.fmt.allocPrint(a, "Pinterest could not process the video: {s}", .{raw}), sess.media_id, "", "");
        },
    }
    // the file must be the one we measured: a producer rewrite during the upload means mixed bytes
    const st2 = std.Io.Dir.cwd().statFile(cx.io, e.mp4_path, .{}) catch return finishRow(cx, db, id, e.name, .failed, exit.FAILED, "the mp4 vanished during upload", sess.media_id, "", "");
    if (st2.size != e.size or st2.mtime.toMilliseconds() != e.mp4_mtime_ms) return finishRow(cx, db, id, e.name, .failed, exit.FAILED, "the mp4 changed during upload: not created", sess.media_id, "", "");
    // 5 create the Pin = point of no return. finish_at is written first so the cap counts it even if we die here
    try send.finishAt(cx, db, id);
    const section = cx.sectionId();
    const cr = pin_api.create(cx, a, tok, .{ .board_id = board, .section_id = section, .title = cap.title, .description = cap.description, .alt_text = alt, .link = link, .ai_values = cx.cfg.post.ai_values, .media_id = sess.media_id, .cover = cover });
    const pin: pin_api.Created = switch (cr) {
        .ok => |d| d,
        .fail => |f| {
            const definite = f.http >= 400 and f.http < 500 and f.info.class != .retry;
            if (definite or !f.sent) return failRow(cx, a, db, id, e.name, sess.media_id, f, "create Pin");
            // the request left and the answer is lost or unreadable: Pinterest may have created the Pin
            try caps.setGap(cx, db);
            return finishRow(cx, db, id, e.name, .unsure, exit.UNSURE, try std.fmt.allocPrint(a, "create Pin sent, answer lost ({s}): run resolve", .{f.info.msg}), sess.media_id, "", "");
        },
    };
    if (cx.crash_at == 3) return error.Crash;
    try caps.setGap(cx, db);
    try caps.recordOk(db);
    try usageStop(cx, a, db);
    const url = urlOf(a, cx.cfg.post.url_template, pin.id);
    const note: []const u8 = if (cx.cfg.post.public) "Pin created on the public board" else "Pin created on the SECRET board (not public); set post.public to publish";
    return finishRow(cx, db, id, e.name, .posted, exit.OK, note, sess.media_id, pin.id, url);
}

pub fn urlOf(a: std.mem.Allocator, tpl: []const u8, id: []const u8) []const u8 {
    const at = std.mem.indexOf(u8, tpl, "{id}") orelse return tpl;
    return std.fmt.allocPrint(a, "{s}{s}{s}", .{ tpl[0..at], id, tpl[at + 4 ..] }) catch "";
}

test "url template and link rules" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("https://www.pinterest.com/pin/77/", urlOf(arena.allocator(), "https://www.pinterest.com/pin/{id}/", "77"));
}
