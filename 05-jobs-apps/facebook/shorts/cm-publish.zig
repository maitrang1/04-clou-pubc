// publish: best ready pair (newest slot, oldest inside it, not older than source.max_age_h) -> start -> upload (stream, resume) -> poll -> finish -> poll -> ledger. Dry-run unless --live.
// Order is the safety: the ledger row (with the video_id) exists before the first byte; finish is the point of no return (a lost answer after it = unsure).
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
const start_api = @import("ap-start.zig");
const up_api = @import("ap-upload.zig");
const st_api = @import("ap-status.zig");
const fin_api = @import("ap-finish.zig");
const sq = @import("rw-sqlite.zig");
const send = @import("rw-send.zig");
const caps = @import("rw-caps.zig");
const pair = @import("rw-pair.zig");
const text = @import("rw-text.zig");

pub const Result = struct { code: u8, state: []const u8, name: []const u8 = "", video_id: []const u8 = "", url: []const u8 = "", note: []const u8 = "" };

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
    out.json(cx, a, .{ .state = r.state, .name = r.name, .video_id = r.video_id, .url = r.url, .note = r.note, .exit = r.code });
}

const Plan = struct { name: []const u8, pkey: []const u8, mp4: []const u8, size: u64, video_state: []const u8, title: ?[]const u8, description: []const u8, is_ai_generated: bool, steps: []const []const u8, note: []const u8 };

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
    if (cx.live) {
        const n = try send.recover(cx, &db);
        if (n > 0) log.log(cx, "warn", "{d} send(s) found mid-flight, now unsure: run resolve", .{n});
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
    const cap = text.build(a, .{ .hooks = e.j.hooks, .description = e.j.description, .hashtags = e.j.hashtags, .ai_notice = e.j.ai_notice }, .{ .desc_max = cx.cfg.post.desc_max, .title_max = cx.cfg.post.title_max, .tags_max = cx.cfg.post.tags_max, .notice_required = cx.cfg.post.ai_notice_required }) catch |er| return .{ .code = exit.FAILED, .state = "refused", .name = e.name, .note = if (er == error.NoNotice) "no ai_notice in the json: every post must carry it" else "caption cannot be built" };
    const vstate: []const u8 = if (cx.cfg.post.public) "PUBLISHED" else "DRAFT";
    if (!cx.live) {
        const steps = [_][]const u8{ "start", "upload", "poll", "finish", "poll" };
        const p = Plan{ .name = e.name, .pkey = e.pkey, .mp4 = e.mp4_path, .size = e.size, .video_state = vstate, .title = cap.title, .description = cap.description, .is_ai_generated = true, .steps = &steps, .note = "dry-run: nothing sent" };
        out.say(cx, "dry-run: would publish '{s}' ({d} MB) as {s}\n  caption: {s}\n  nothing was sent. Add --live to send.", .{ e.name, e.size / (1024 * 1024), vstate, cap.description });
        out.json(cx, a, p);
        return .{ .code = exit.OK, .state = "dry-run", .name = e.name, .note = "nothing sent" };
    }
    const tok = cx.pageToken() orelse return res(exit.USAGE, "config", "no Page token: set the env var or the file named in config graph.page_token_*");
    const page = cx.pageId() orelse return res(exit.USAGE, "config", "no Page id: set the env var or the file named in config account.page_id_*");
    return sendOne(cx, a, &db, e, cap, tok, page, again);
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
            try caps.blockFor(db, cx.nowMs(), ms, try std.fmt.allocPrint(a, "code {d}", .{f.info.code}));
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

const PollEnd = union(enum) { verdict: st_api.Verdict, status: st_api.Status, fail: call.Fail, timeout };

// poll status until `want_done` (uploaded or later) / final (published or draft) / failed; bounded by net.status_poll_max_s
fn poll(cx: *Ctx, a: std.mem.Allocator, tok: []const u8, vid: []const u8, final: bool) struct { end: PollEnd, st: st_api.Status } {
    const iters = @max(1, cx.cfg.net.status_poll_max_s / cx.cfg.net.status_poll_s);
    var last = st_api.Status{};
    var i: u32 = 0;
    while (i < iters) : (i += 1) {
        switch (st_api.get(cx, a, tok, vid)) {
            .fail => |f| {
                if (f.info.class != .retry) return .{ .end = .{ .fail = f }, .st = last };
            },
            .ok => |s| {
                last = s;
                const v = st_api.verdict(s);
                switch (v) {
                    .failed, .expired => return .{ .end = .{ .verdict = v }, .st = s },
                    .published, .draft => return .{ .end = .{ .verdict = v }, .st = s },
                    .uploaded, .processing => if (!final) return .{ .end = .{ .verdict = v }, .st = s },
                    .uploading, .unknown => {},
                }
            },
        }
        cx.sleepMs(@as(i64, cx.cfg.net.status_poll_s) * 1000);
    }
    return .{ .end = .timeout, .st = last };
}

fn sendOne(cx: *Ctx, a: std.mem.Allocator, db: *sq.Db, e: pair.Entry, cap: text.Caption, tok: []const u8, page: []const u8, again: bool) !Result {
    const t0 = util.monoMs(cx.io);
    const budget_ms = @as(i64, cx.cfg.limits.run_budget_s) * 1000;
    // 1 start (pre-send failures may retry)
    var attempt: u32 = 0;
    const sess: start_api.Session = while (true) {
        switch (start_api.start(cx, a, tok, page)) {
            .ok => |s| break s,
            .fail => |f| {
                if (f.info.class == .retry and attempt < cx.cfg.retry_pre_send) {
                    attempt += 1;
                    cx.sleepMs(@as(i64, cx.cfg.net.backoff_ms) * attempt);
                    continue;
                }
                // a dead token or a Facebook limit at start: nothing to burn a pair for. Stop the run, leave the pair ready
                if (f.info.class == .blocked or f.info.class == .stop_day or f.info.class == .breaker) {
                    if (f.info.class == .breaker) try caps.hardStop(db);
                    if (f.info.class == .stop_day) try caps.blockFor(db, cx.nowMs(), @max(caps.quotaBlockMs(cx), @as(i64, call.usage_regain) * 60_000), try std.fmt.allocPrint(a, "code {d}", .{f.info.code}));
                    return res(exit.BLOCKED, "blocked", try std.fmt.allocPrint(a, "start: {s} (code {d}, http {d}); the pair stays ready", .{ f.info.msg, f.info.code, f.http }));
                }
                // nothing was uploaded. A transient problem leaves no row (next run tries again); a final answer gets a row so a bad pair is not retried forever
                if (f.info.class == .retry) {
                    try caps.recordFail(cx, db);
                    return res(exit.FAILED, "failed", try std.fmt.allocPrint(a, "start: {s} (http {d}), will try again next run", .{ f.info.msg, f.http }));
                }
                const id = send.begin(cx, db, a, e.name, e.pkey, "", again) catch |er| if (er == error.Replay) return replay(a, db, e) else return er;
                return failRow(cx, a, db, id, e.name, "", f, "start");
            },
        }
    };
    if (call.usage_pct >= cx.cfg.limits.usage_stop_pct) { // too close to Facebook's limit: stop before any byte goes up
        try usageStop(cx, a, db);
        return res(exit.BLOCKED, "blocked", try std.fmt.allocPrint(a, "usage {d}% of Facebook's allowance: stopped before upload", .{call.usage_pct}));
    }
    // 2 ledger row with the video_id, BEFORE the first byte
    const id = send.begin(cx, db, a, e.name, e.pkey, sess.video_id, again) catch |er| if (er == error.Replay) return replay(a, db, e) else return er;
    if (cx.crash_at == 1) return error.Crash;
    // 3 upload, streamed; an interruption resumes from what Facebook already has
    var offset: u64 = 0;
    var tries: u32 = 0;
    while (true) {
        if (util.monoMs(cx.io) - t0 > budget_ms) return finishRow(cx, db, id, e.name, .failed, exit.FAILED, "run budget used up during upload", sess.video_id, "", "");
        switch (up_api.upload(cx, a, tok, sess.upload_url, e.mp4_path, e.size, offset)) {
            .ok => break,
            .fail => |f| {
                const resumable = f.info.class == .resume_up or f.info.class == .retry or f.info.class == .retry_once;
                if (!resumable) return failRow(cx, a, db, id, e.name, sess.video_id, f, "upload");
                if (tries >= cx.cfg.net.resume_max) return failRow(cx, a, db, id, e.name, sess.video_id, .{ .info = .{ .class = .failed, .msg = "upload gave up after retries" }, .http = f.http, .net = f.net, .body = f.body }, "upload");
                tries += 1;
                cx.sleepMs(@as(i64, cx.cfg.net.backoff_ms) * tries);
                switch (st_api.get(cx, a, tok, sess.video_id)) {
                    .ok => |s| {
                        if (s.bytes >= e.size or st_api.done(s.up_status)) break;
                        offset = @min(s.bytes, e.size);
                    },
                    .fail => |sf| if (sf.info.class != .retry) return failRow(cx, a, db, id, e.name, sess.video_id, sf, "status"),
                }
            },
        }
    }
    if (cx.crash_at == 2) return error.Crash;
    // 4 wait until Facebook has the whole file
    const p1 = poll(cx, a, tok, sess.video_id, false);
    switch (p1.end) {
        .fail => |f| return failRow(cx, a, db, id, e.name, sess.video_id, f, "status"),
        .timeout => return finishRow(cx, db, id, e.name, .failed, exit.FAILED, "Facebook did not confirm the upload in time (nothing published)", sess.video_id, "", ""),
        .status => {},
        .verdict => |v| switch (v) {
            .failed, .expired => {
                try caps.recordFail(cx, db);
                return finishRow(cx, db, id, e.name, .failed, exit.FAILED, try std.fmt.allocPrint(a, "upload {s}: {s}", .{ @tagName(v), p1.st.proc_err }), sess.video_id, "", "");
            },
            .published, .draft => return finishRow(cx, db, id, e.name, .unsure, exit.UNSURE, "already finished before finish was sent: run resolve", sess.video_id, "", ""),
            else => {},
        },
    }
    // the file must be the one we measured: a producer rewrite during the upload means mixed bytes
    const st2 = std.Io.Dir.cwd().statFile(cx.io, e.mp4_path, .{}) catch return finishRow(cx, db, id, e.name, .failed, exit.FAILED, "the mp4 vanished during upload", sess.video_id, "", "");
    if (st2.size != e.size or st2.mtime.toMilliseconds() != e.mp4_mtime_ms) return finishRow(cx, db, id, e.name, .failed, exit.FAILED, "the mp4 changed during upload: not finished", sess.video_id, "", "");
    // 5 finish = point of no return. finish_at is written first so the cap counts it even if we die here
    try send.finishAt(cx, db, id);
    const fr = fin_api.finish(cx, a, tok, page, sess.video_id, cx.cfg.post.public, cap.description, cap.title);
    const done: fin_api.Done = switch (fr) {
        .ok => |d| d,
        .fail => |f| {
            const definite = f.http >= 400 and f.http < 500 and f.info.class != .retry;
            if (definite or !f.sent) return failRow(cx, a, db, id, e.name, sess.video_id, f, "finish");
            // the request left and the answer is lost or unreadable: Facebook may have published
            try caps.setGap(cx, db);
            return finishRow(cx, db, id, e.name, .unsure, exit.UNSURE, try std.fmt.allocPrint(a, "finish sent, answer lost ({s}): run resolve", .{f.info.msg}), sess.video_id, "", "");
        },
    };
    if (cx.crash_at == 3) return error.Crash;
    try caps.setGap(cx, db);
    // 6 confirm it went through
    const p2 = poll(cx, a, tok, sess.video_id, true);
    const url = try std.fmt.allocPrint(a, "{s}/{s}", .{ std.mem.trimEnd(u8, cx.cfg.post.reel_url_base, "/"), sess.video_id });
    try usageStop(cx, a, db);
    switch (p2.end) {
        .verdict => |v| switch (v) {
            .published, .draft => {
                try caps.recordOk(db);
                const note: []const u8 = if (v == .draft) "saved as DRAFT on the Page (not public); set post.public to publish" else "published";
                return finishRow(cx, db, id, e.name, .posted, exit.OK, note, sess.video_id, done.post_id, url);
            },
            else => {
                try caps.recordFail(cx, db);
                return finishRow(cx, db, id, e.name, .failed, exit.FAILED, try std.fmt.allocPrint(a, "Facebook {s} after finish: {s}{s}", .{ @tagName(v), p2.st.proc_err, p2.st.pub_err }), sess.video_id, "", "");
            },
        },
        else => return finishRow(cx, db, id, e.name, .unsure, exit.UNSURE, "finish ok but the final state was not confirmed: run resolve", sess.video_id, done.post_id, ""),
    }
}
