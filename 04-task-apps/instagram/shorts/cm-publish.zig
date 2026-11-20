// publish: oldest ready pair -> container -> upload (stream) -> poll FINISHED -> staged | media_publish -> ledger. Dry-run unless --live.
// Order is the safety: the ledger row (with the container id) exists before the first byte; media_publish is the point of no return.
// Outcome of media_publish: 200 = posted · a documented 4xx proving "not published" = failed (or keep polling for 2207027) · anything unclear = unsure.
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
const cont_api = @import("ap-container.zig");
const up_api = @import("ap-upload.zig");
const st_api = @import("ap-status.zig");
const pub_api = @import("ap-publish.zig");
const quota_api = @import("ap-quota.zig");
const list_api = @import("ap-list.zig");
const sq = @import("rw-sqlite.zig");
const send = @import("rw-send.zig");
const caps = @import("rw-caps.zig");
const pair = @import("rw-pair.zig");
const text = @import("rw-text.zig");

const CF = .{ .stage_ttl_ms = 24 * 3600 * 1000, .min_wait_ms = 3600 * 1000 };

pub const Result = struct { code: u8, state: []const u8, name: []const u8 = "", cont_id: []const u8 = "", url: []const u8 = "", note: []const u8 = "" };

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
    out.json(cx, a, .{ .state = r.state, .name = r.name, .container_id = r.cont_id, .url = r.url, .note = r.note, .exit = r.code });
}

const Plan = struct { name: []const u8, pkey: []const u8, mp4: []const u8, size: u64, visibility: []const u8, caption: []const u8, is_ai_generated: bool, share_to_feed: bool, steps: []const []const u8, note: []const u8 };

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
        _ = try send.expireStaged(cx, &db, CF.stage_ttl_ms);
        const n = try send.recover(cx, &db);
        if (n > 0) log.log(cx, "warn", "{d} send(s) found mid-publish, now unsure: run resolve", .{n});
        if (cx.token()) |tok| try resumeSending(cx, a, &db, tok);
    }
    if (try caps.blocked(cx, &db, a)) |b| return res(exit.BLOCKED, "blocked", b.why);
    if (cx.cfg.limits.disk_min_mb > 0) {
        const dd = try cx.dataPath(a, "");
        if (os.diskFreeMb(a, std.mem.trimEnd(u8, dd, "/"))) |mb| if (mb < cx.cfg.limits.disk_min_mb) return res(exit.BLOCKED, "blocked", try std.fmt.allocPrint(a, "disk low: {d} MB free (min {d})", .{ mb, cx.cfg.limits.disk_min_mb }));
    }
    const entries = pair.scan(cx, a, &db) catch |e| return res(exit.USAGE, "config", if (e == error.NoSourceDir) "source.dir is not set or cannot be opened" else "cannot read the source folder");
    var pick: ?pair.Entry = null;
    var staged: ?pair.Entry = null; // a staged container that can now go public
    const can_publish_staged = cx.cfg.post.public;
    if (want) |name| {
        const e = pair.find(entries, name) orelse return res(exit.FAILED, "failed", "no such pair in the source folder");
        switch (e.kind) {
            .ready => pick = e,
            .invalid, .skipped => return .{ .code = exit.FAILED, .state = "invalid", .name = e.name, .note = e.reason },
            .done => {
                if (std.mem.eql(u8, e.reason, "staged") and can_publish_staged) staged = e else if ((std.mem.eql(u8, e.reason, "failed") or std.mem.eql(u8, e.reason, "expired")) and again) {
                    // a retry sends the file as it is NOW: judge it again, fully (spec check)
                    const fresh = pair.scanOne(cx, a, &db, e.name) catch return res(exit.FAILED, "failed", "cannot re-read the pair");
                    switch (fresh.kind) {
                        .ready => pick = fresh,
                        else => return .{ .code = exit.FAILED, .state = "invalid", .name = e.name, .note = fresh.reason },
                    }
                } else return replay(a, &db, e);
            },
        }
    } else {
        if (can_publish_staged) for (entries) |e| if (e.kind == .done and std.mem.eql(u8, e.reason, "staged")) {
            staged = e;
            break;
        };
        if (staged == null) for (entries) |e| if (e.kind == .ready) {
            pick = e;
            break;
        };
    }
    if (staged != null and !cx.live) {
        const e = staged.?;
        out.say(cx, "dry-run: would publish the staged container of '{s}'\n  nothing was sent. Add --live to send.", .{e.name});
        out.json(cx, a, .{ .name = e.name, .would = "media_publish of the staged container", .note = "dry-run: nothing sent" });
        return .{ .code = exit.OK, .state = "dry-run", .name = e.name, .note = "nothing sent" };
    }
    if (staged) |e| {
        const tok = cx.token() orelse return res(exit.USAGE, "config", "no access token: set the env var or the file named in config graph.token_*");
        const ig = cx.igId() orelse return res(exit.USAGE, "config", "no Instagram user id: set the env var or the file named in config account.ig_user_id_*");
        return publishStaged(cx, a, &db, e, tok, ig);
    }
    const e = pick orelse {
        var bad: usize = 0;
        for (entries) |x| if (x.kind == .invalid) {
            bad += 1;
        };
        return res(exit.NOTHING, "nothing", try std.fmt.allocPrint(a, "no ready pair ({d} invalid)", .{bad}));
    };
    const cap = text.build(a, .{ .hooks = e.j.hooks, .description = e.j.description, .hashtags = e.j.hashtags, .ai_notice = e.j.ai_notice }, .{ .desc_max = cx.cfg.post.caption_max, .tags_max = cx.cfg.post.tags_max, .notice_required = cx.cfg.post.ai_notice_required }) catch |er| return .{ .code = exit.FAILED, .state = "refused", .name = e.name, .note = if (er == error.NoNotice) "no ai_notice in the json: every post must carry it" else "caption cannot be built" };
    const vis: []const u8 = if (cx.cfg.post.public) "PUBLIC (media_publish)" else "STAGED (container only, no media_publish)";
    if (!cx.live) {
        const steps = [_][]const u8{ "create container (resumable)", "upload", "poll until FINISHED", if (cx.cfg.post.public) "media_publish" else "stop: staged" };
        const p = Plan{ .name = e.name, .pkey = e.pkey, .mp4 = e.mp4_path, .size = e.size, .visibility = vis, .caption = cap.description, .is_ai_generated = true, .share_to_feed = cx.cfg.post.share_to_feed, .steps = &steps, .note = "dry-run: nothing sent" };
        out.say(cx, "dry-run: would send '{s}' ({d} MB) as {s}\n  caption: {s}\n  nothing was sent. Add --live to send.", .{ e.name, e.size / (1024 * 1024), vis, cap.description });
        out.json(cx, a, p);
        return .{ .code = exit.OK, .state = "dry-run", .name = e.name, .note = "nothing sent" };
    }
    const tok = cx.token() orelse return res(exit.USAGE, "config", "no access token: set the env var or the file named in config graph.token_*");
    const ig = cx.igId() orelse return res(exit.USAGE, "config", "no Instagram user id: set the env var or the file named in config account.ig_user_id_*");
    return sendOne(cx, a, &db, e, cap, tok, ig, again);
}

// a pair already in the ledger: answer from it, never send again
fn replay(a: std.mem.Allocator, db: *sq.Db, e: pair.Entry) !Result {
    const row = (try send.byPkey(db, a, e.pkey)) orelse return res(exit.FAILED, "failed", "ledger row vanished");
    const code: u8 = switch (row.state) {
        .posted, .staged => exit.OK,
        .unsure, .sending => exit.UNSURE,
        .failed, .expired => exit.FAILED,
    };
    const note = if (row.state == .failed or row.state == .expired) try std.fmt.allocPrint(a, "{s} earlier ({s}); a person can retry with --again", .{ send.stateName(row.state), row.note }) else row.note;
    return .{ .code = code, .state = if (row.state == .posted) "already-posted" else send.stateName(row.state), .name = e.name, .cont_id = row.cont_id, .url = row.url, .note = note };
}

fn finishRow(cx: *Ctx, db: *sq.Db, id: i64, name: []const u8, st: send.State, code: u8, note: []const u8, cid: []const u8, media_id: []const u8, url: []const u8) !Result {
    const nn = text.safeNote(std.heap.page_allocator, note, 400);
    try send.setState(cx, db, id, st, nn, media_id, url);
    log.log(cx, "info", "{s} {s}: {s}", .{ name, send.stateName(st), nn });
    return .{ .code = code, .state = send.stateName(st), .name = name, .cont_id = cid, .url = url, .note = nn };
}

// what a failed call means for the row and the run
fn failRow(cx: *Ctx, a: std.mem.Allocator, db: *sq.Db, id: i64, name: []const u8, cid: []const u8, f: call.Fail, stage: []const u8) !Result {
    const note = try std.fmt.allocPrint(a, "{s}: {s} (code {d}/{d}, http {d}) {s}", .{ stage, f.info.msg, f.info.code, f.info.sub, f.http, f.body[0..@min(f.body.len, 200)] });
    switch (f.info.class) {
        .blocked => return finishRow(cx, db, id, name, .failed, exit.BLOCKED, note, cid, "", ""),
        .breaker => {
            try caps.hardStop(db);
            return finishRow(cx, db, id, name, .failed, exit.BLOCKED, note, cid, "", "");
        },
        .stop_day => {
            const ms = @max(caps.quotaBlockMs(cx), @as(i64, call.usage_regain) * 60_000);
            try caps.blockFor(db, cx.nowMs(), ms, try std.fmt.allocPrint(a, "code {d}", .{f.info.code}));
            return finishRow(cx, db, id, name, .failed, exit.BLOCKED, note, cid, "", "");
        },
        .expired => return finishRow(cx, db, id, name, .expired, exit.FAILED, note, cid, "", ""),
        else => {
            try caps.recordFail(cx, db);
            return finishRow(cx, db, id, name, .failed, exit.FAILED, note, cid, "", "");
        },
    }
}

fn usageStop(cx: *Ctx, a: std.mem.Allocator, db: *sq.Db) !void {
    if (call.usage_pct >= cx.cfg.limits.usage_stop_pct) {
        const ms = @max(@as(i64, call.usage_regain) * 60_000, CF.min_wait_ms);
        try caps.blockFor(db, cx.nowMs(), ms, try std.fmt.allocPrint(a, "usage {d}%", .{call.usage_pct}));
    }
}

const Poll = union(enum) { finished, failed: st_api.Status, expired, published, timeout, fail: call.Fail };

// poll the container until FINISHED / ERROR / EXPIRED / PUBLISHED; bounded by net.status_poll_max_s (Meta: once a minute, at most 5 minutes)
fn pollFinished(cx: *Ctx, a: std.mem.Allocator, tok: []const u8, cid: []const u8) Poll {
    const iters = @max(1, cx.cfg.net.status_poll_max_s / cx.cfg.net.status_poll_s);
    var i: u32 = 0;
    while (i < iters) : (i += 1) {
        switch (st_api.get(cx, a, tok, cid)) {
            .fail => |f| if (f.info.class != .retry) return .{ .fail = f },
            .ok => |s| switch (st_api.verdict(s)) {
                .finished => return .finished,
                .failed => return .{ .failed = s },
                .expired => return .expired,
                .published => return .published,
                .in_progress, .unknown => {},
            },
        }
        if (i + 1 < iters) cx.sleepMs(@as(i64, cx.cfg.net.status_poll_s) * 1000);
    }
    return .timeout;
}

// Meta's own allowance (content_publishing_limit) on top of our ledger cap. A reply we cannot read falls back to the ledger cap; a dead token stops.
fn quotaGate(cx: *Ctx, a: std.mem.Allocator, db: *sq.Db, tok: []const u8, ig: []const u8) !?[]const u8 {
    switch (quota_api.get(cx, a, tok, ig)) {
        .ok => |q| {
            const lim = @min(q.total, cx.cfg.limits.meta_cap);
            if (q.usage + 1 > lim) {
                try caps.blockFor(db, cx.nowMs(), CF.min_wait_ms, "publishing limit full");
                return try std.fmt.allocPrint(a, "Instagram publishing allowance: {d} used of {d} (Meta total {d}, our cap {d}); the pair stays ready", .{ q.usage, lim, q.total, cx.cfg.limits.meta_cap });
            }
        },
        .fail => |f| {
            log.log(cx, "warn", "content_publishing_limit unreadable ({s}); the ledger cap still applies", .{f.info.msg});
            if (f.info.class == .blocked) return try std.fmt.allocPrint(a, "{s}; the pair stays ready", .{f.info.msg});
        },
    }
    return null;
}

// rows left `sending` before any publish call (a crashed or slow run): ask the container once and move them on
fn resumeSending(cx: *Ctx, a: std.mem.Allocator, db: *sq.Db, tok: []const u8) !void {
    const rows = try send.sendingRows(db, a);
    for (rows) |r| {
        if (r.cont_id.len == 0) continue;
        switch (st_api.get(cx, a, tok, r.cont_id)) {
            .fail => {},
            .ok => |s| switch (st_api.verdict(s)) {
                .finished => try send.setState(cx, db, r.id, .staged, "container FINISHED (found after an interrupted run): not published", "", ""),
                .failed => try send.setState(cx, db, r.id, .failed, try std.fmt.allocPrint(a, "container ERROR ({s}) after an interrupted run", .{s.sub}), "", ""),
                .expired => try send.setState(cx, db, r.id, .expired, "container expired after an interrupted run", "", ""),
                .published => try send.setState(cx, db, r.id, .unsure, "container shows PUBLISHED but the ledger never saw the call: run resolve", "", ""),
                .in_progress, .unknown => {},
            },
        }
    }
}

fn sendOne(cx: *Ctx, a: std.mem.Allocator, db: *sq.Db, e: pair.Entry, cap: text.Caption, tok: []const u8, ig: []const u8, again: bool) !Result {
    const t0 = util.monoMs(cx.io);
    const budget_ms = @as(i64, cx.cfg.limits.run_budget_s) * 1000;
    if (cx.cfg.post.public) if (try quotaGate(cx, a, db, tok, ig)) |why| return res(exit.BLOCKED, "blocked", why);
    // 1 container (pre-send failures may retry)
    var attempt: u32 = 0;
    const sess: cont_api.Session = while (true) {
        switch (cont_api.create(cx, a, tok, ig, cap.description)) {
            .ok => |s| break s,
            .fail => |f| {
                if (f.info.class == .retry and attempt < cx.cfg.retry_pre_send) {
                    attempt += 1;
                    cx.sleepMs(@as(i64, cx.cfg.net.backoff_ms) * attempt);
                    continue;
                }
                // a dead token or an Instagram limit at the start: nothing to burn a pair for. Stop the run, leave the pair ready
                if (f.info.class == .blocked or f.info.class == .stop_day or f.info.class == .breaker) {
                    if (f.info.class == .breaker) try caps.hardStop(db);
                    if (f.info.class == .stop_day) try caps.blockFor(db, cx.nowMs(), @max(caps.quotaBlockMs(cx), @as(i64, call.usage_regain) * 60_000), try std.fmt.allocPrint(a, "code {d}", .{f.info.code}));
                    return res(exit.BLOCKED, "blocked", try std.fmt.allocPrint(a, "container: {s} (code {d}/{d}, http {d}); the pair stays ready", .{ f.info.msg, f.info.code, f.info.sub, f.http }));
                }
                // nothing was uploaded. A transient problem leaves no row (next run tries again); a final answer gets a row so a bad pair is not retried forever
                if (f.info.class == .retry) {
                    try caps.recordFail(cx, db);
                    return res(exit.FAILED, "failed", try std.fmt.allocPrint(a, "container: {s} (http {d}), will try again next run", .{ f.info.msg, f.http }));
                }
                const id = send.begin(cx, db, a, e.name, e.pkey, "", again) catch |er| if (er == error.Replay) return replay(a, db, e) else return er;
                return failRow(cx, a, db, id, e.name, "", f, "container");
            },
        }
    };
    if (call.usage_pct >= cx.cfg.limits.usage_stop_pct) { // too close to Instagram's limit: stop before any byte goes up
        try usageStop(cx, a, db);
        return res(exit.BLOCKED, "blocked", try std.fmt.allocPrint(a, "usage {d}% of Instagram's allowance: stopped before upload", .{call.usage_pct}));
    }
    // 2 ledger row with the container id, BEFORE the first byte
    const id = send.begin(cx, db, a, e.name, e.pkey, sess.cont_id, again) catch |er| if (er == error.Replay) return replay(a, db, e) else return er;
    if (cx.crash_at == 1) return error.Crash;
    // 3 upload, streamed. A cut upload restarts at offset 0 on the same container (Meta documents no resume position)
    var tries: u32 = 0;
    while (true) {
        if (util.monoMs(cx.io) - t0 > budget_ms) return finishRow(cx, db, id, e.name, .failed, exit.FAILED, "run budget used up during upload", sess.cont_id, "", "");
        switch (up_api.upload(cx, a, tok, sess.uri, e.mp4_path, e.size, 0)) {
            .ok => break,
            .fail => |f| {
                const again_ok = f.info.class == .retry or f.info.class == .retry_once;
                if (!again_ok) return failRow(cx, a, db, id, e.name, sess.cont_id, f, "upload");
                if (tries >= cx.cfg.net.resume_max or (f.info.class == .retry_once and tries >= 1)) return failRow(cx, a, db, id, e.name, sess.cont_id, .{ .info = .{ .class = .failed, .msg = "upload gave up after retries (re-queue with --again for a new container)" }, .http = f.http, .net = f.net, .body = f.body }, "upload");
                tries += 1;
                cx.sleepMs(@as(i64, cx.cfg.net.backoff_ms) * tries);
            },
        }
    }
    if (cx.crash_at == 2) return error.Crash;
    // 4 wait until Instagram has processed it
    switch (pollFinished(cx, a, tok, sess.cont_id)) {
        .finished => {},
        .fail => |f| return failRow(cx, a, db, id, e.name, sess.cont_id, f, "status"),
        .timeout => return finishRow(cx, db, id, e.name, .sending, exit.BLOCKED, "container still processing: the next run asks again (nothing published)", sess.cont_id, "", ""),
        .expired => return finishRow(cx, db, id, e.name, .expired, exit.FAILED, "container expired before it was ready", sess.cont_id, "", ""),
        .published => return finishRow(cx, db, id, e.name, .unsure, exit.UNSURE, "container already shows PUBLISHED before any publish call: run resolve", sess.cont_id, "", ""),
        .failed => |s| {
            try caps.recordFail(cx, db);
            return finishRow(cx, db, id, e.name, .failed, exit.FAILED, try std.fmt.allocPrint(a, "container ERROR (subcode {s}); re-queue with --again for a new container", .{s.sub}), sess.cont_id, "", "");
        },
    }
    // the file must be the one we measured: a producer rewrite during the upload means mixed bytes
    const st2 = std.Io.Dir.cwd().statFile(cx.io, e.mp4_path, .{}) catch return finishRow(cx, db, id, e.name, .failed, exit.FAILED, "the mp4 vanished during upload", sess.cont_id, "", "");
    if (st2.size != e.size or st2.mtime.toMilliseconds() != e.mp4_mtime_ms) return finishRow(cx, db, id, e.name, .failed, exit.FAILED, "the mp4 changed during upload: not published", sess.cont_id, "", "");
    // 5 not public: stop at a finished container
    if (!cx.cfg.post.public) {
        try caps.recordOk(db);
        return finishRow(cx, db, id, e.name, .staged, exit.OK, "staged: container FINISHED, NOT published (invisible; expires in 24 h). Set post.public to publish", sess.cont_id, "", "");
    }
    return publishIt(cx, a, db, id, e.name, sess.cont_id, tok, ig);
}

// a staged container goes public (post.public turned on later)
fn publishStaged(cx: *Ctx, a: std.mem.Allocator, db: *sq.Db, e: pair.Entry, tok: []const u8, ig: []const u8) !Result {
    const row = (try send.byPkey(db, a, e.pkey)) orelse return res(exit.FAILED, "failed", "ledger row vanished");
    if (row.state != .staged or row.cont_id.len == 0 or row.pub_at != 0) return replay(a, db, e);
    if (try quotaGate(cx, a, db, tok, ig)) |why| return res(exit.BLOCKED, "blocked", why);
    switch (pollFinished(cx, a, tok, row.cont_id)) {
        .finished => {},
        .fail => |f| return failRow(cx, a, db, row.id, e.name, row.cont_id, f, "status"),
        .timeout => return res(exit.BLOCKED, "blocked", "staged container not answering as FINISHED yet: try again"),
        .expired => return finishRow(cx, db, row.id, e.name, .expired, exit.FAILED, "staged container expired: re-queue with --again", row.cont_id, "", ""),
        .published => return finishRow(cx, db, row.id, e.name, .unsure, exit.UNSURE, "container already shows PUBLISHED: run resolve", row.cont_id, "", ""),
        .failed => |s| return finishRow(cx, db, row.id, e.name, .failed, exit.FAILED, try std.fmt.allocPrint(a, "staged container ERROR (subcode {s})", .{s.sub}), row.cont_id, "", ""),
    }
    try send.setState(cx, db, row.id, .sending, "publishing a staged container", "", "");
    return publishIt(cx, a, db, row.id, e.name, row.cont_id, tok, ig);
}

// media_publish = point of no return. pub_at is written first so the cap counts it even if we die here
fn publishIt(cx: *Ctx, a: std.mem.Allocator, db: *sq.Db, id: i64, name: []const u8, cid: []const u8, tok: []const u8, ig: []const u8) !Result {
    try send.pubAt(cx, db, id);
    var attempt: u32 = 0;
    while (true) {
        if (attempt > 0) try send.pubAt(cx, db, id); // a repeated call is counted and stamped again
        switch (pub_api.publish(cx, a, tok, ig, cid)) {
            .ok => |d| {
                if (cx.crash_at == 3) return error.Crash;
                // record the fact first; the read-backs below are best effort and may be cut short by a kill
                var note: std.ArrayList(u8) = .empty;
                try note.appendSlice(a, "published");
                if (d.issue.len > 0) try note.print(a, "; Instagram says {s} (the media IS published)", .{d.issue});
                try send.setState(cx, db, id, .posted, note.items, d.media_id, "");
                try caps.setGap(cx, db);
                try caps.recordOk(db);
                try usageStop(cx, a, db);
                const inf = list_api.info(cx, a, tok, d.media_id);
                if (inf.ai) |ai| if (!ai) try note.appendSlice(a, "; WARNING: Instagram reads is_ai_generated=false");
                return finishRow(cx, db, id, name, .posted, exit.OK, note.items, cid, d.media_id, inf.permalink);
            },
            .fail => |f| {
                const known_no = f.info.definite or !f.sent;
                if (!known_no) {
                    // the request left and the answer is lost, unclear or a maybe-error: Instagram may have published
                    try caps.setGap(cx, db);
                    return finishRow(cx, db, id, name, .unsure, exit.UNSURE, try std.fmt.allocPrint(a, "publish sent, answer unclear ({s}, http {d}): run resolve", .{ f.info.msg, f.http }), cid, "", "");
                }
                if (f.info.definite and (f.info.class == .notready or f.info.class == .wait)) try send.clearPub(db, id); // proven: not published
                if (f.info.definite and (f.info.class == .notready or f.info.class == .wait) and attempt < cx.cfg.retry_publish) {
                    attempt += 1;
                    cx.sleepMs(@as(i64, cx.cfg.net.notready_wait_s) * 1000);
                    switch (pollFinished(cx, a, tok, cid)) {
                        .finished => continue,
                        .fail => |pf| return failRow(cx, a, db, id, name, cid, pf, "status"),
                        .timeout => return finishRow(cx, db, id, name, .sending, exit.BLOCKED, "container not FINISHED yet: the next run asks again (nothing published)", cid, "", ""),
                        .expired => return finishRow(cx, db, id, name, .expired, exit.FAILED, "container expired before publishing", cid, "", ""),
                        .published => return finishRow(cx, db, id, name, .unsure, exit.UNSURE, "container shows PUBLISHED: run resolve", cid, "", ""),
                        .failed => |s| return finishRow(cx, db, id, name, .failed, exit.FAILED, try std.fmt.allocPrint(a, "container ERROR (subcode {s})", .{s.sub}), cid, "", ""),
                    }
                }
                return failRow(cx, a, db, id, name, cid, f, "publish");
            },
        }
    }
}
