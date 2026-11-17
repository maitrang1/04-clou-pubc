// publish: oldest ready pair -> (lost-ledger probe, quota) -> host copy -> create container -> wait FINISHED -> [publish -> confirm]. Dry-run unless --live.
// Order is the safety: everything before `threads_publish` is reversible (a container expires after 24 h). The publish request is the point of no return:
// pub_at is written first (the cap counts it), and a lost answer, a timeout or any 5xx after it = unsure. A run that dies before it continues the SAME container next time.
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
const create_api = @import("ap-create.zig");
const st_api = @import("ap-status.zig");
const pub_api = @import("ap-publish.zig");
const look = @import("ap-lookup.zig");
const quota_api = @import("ap-quota.zig");
const err = @import("ap-error.zig");
const sq = @import("rw-sqlite.zig");
const send = @import("rw-send.zig");
const caps = @import("rw-caps.zig");
const pair = @import("rw-pair.zig");
const text = @import("rw-text.zig");
const host = @import("rw-host.zig");
const dupe = @import("rw-dupe.zig");
const tokc = @import("cm-token.zig");

pub const Result = struct { code: u8, state: []const u8, name: []const u8 = "", container: []const u8 = "", url: []const u8 = "", note: []const u8 = "" };

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
    out.json(cx, a, .{ .state = r.state, .name = r.name, .container = r.container, .url = r.url, .note = r.note, .exit = r.code });
}

const Plan = struct { name: []const u8, pkey: []const u8, mp4: []const u8, size: u64, text: []const u8, topic_tag: ?[]const u8, will_publish: bool, steps: []const []const u8, note: []const u8 };

fn pickable(cx: *const Ctx, a: std.mem.Allocator, db: *sq.Db, e: pair.Entry) !bool {
    if (e.kind == .ready) return true;
    if (e.kind != .pending) return false;
    const row = (try send.byPkey(db, a, e.pkey)) orelse return false;
    return row.state == .sending or (row.state == .staged and cx.cfg.post.public);
}

fn runInner(cx: *Ctx, a: std.mem.Allocator, av: []const []const u8) !Result {
    const want = args.value(av, "--video");
    const again = args.has(av, "--again");
    if (args.has(av, "--video") and want == null) return res(exit.USAGE, "usage", "--video needs a name");
    if (kill.killOn(cx)) return res(exit.BLOCKED, "blocked", "kill file is on (kill --off --live to clear)");
    if (cx.live and !cx.cfg.device.publisher) return res(exit.BLOCKED, "blocked", "device.publisher is false: only ONE device may publish for an account (set it true on that device)");
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
    if (cx.live) {
        const n = try send.recover(cx, &db);
        if (n > 0) log.log(cx, "warn", "{d} send(s) died after the publish request left, now unsure: run resolve", .{n});
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
            .pending => {
                if (try pickable(cx, a, &db, e)) pick = e else return replay(a, &db, e);
            },
            .done => {
                if (std.mem.eql(u8, e.reason, "failed") and again) pick = e else return replay(a, &db, e);
            },
        }
    } else {
        for (entries) |e| if (try pickable(cx, a, &db, e)) {
            pick = e;
            break;
        };
    }
    const e = pick orelse {
        var held: usize = 0;
        var bad: usize = 0;
        var staged: usize = 0;
        for (entries) |x| {
            if (x.kind == .held) held += 1;
            if (x.kind == .invalid) bad += 1;
            if (x.kind == .pending) staged += 1;
        }
        return res(exit.NOTHING, "nothing", try std.fmt.allocPrint(a, "no ready pair ({d} held, {d} invalid, {d} staged or waiting)", .{ held, bad, staged }));
    };
    const post = text.build(a, .{ .hooks = e.j.hooks, .description = e.j.description, .hashtags = e.j.hashtags, .ai_notice = e.j.ai_notice, .listing_url = e.j.listing_url }, .{ .text_max = cx.cfg.post.text_max, .margin = cx.cfg.post.text_margin, .unit = text.unitOf(cx.cfg.post.text_unit), .url_in_text = cx.cfg.post.url_in_text, .notice_required = cx.cfg.post.ai_notice_required }) catch |er| return .{ .code = exit.FAILED, .state = "refused", .name = e.name, .note = switch (er) {
        error.NoNotice => "no ai_notice in the json: every post must carry it",
        error.NoticeTooLong => "the AI notice (and link) alone are longer than the text limit",
        error.TooManyLinks => "more than 5 links in the text",
        else => "text cannot be built",
    } };
    if (!cx.live) {
        const steps = [_][]const u8{ "copy the mp4 into host.dir (random name)", "check the public url", "create the container (is_made_with_ai=true)", "wait for FINISHED", if (cx.cfg.post.public) "publish" else "stop here: staged (post.public is false)", "confirm" };
        const p = Plan{ .name = e.name, .pkey = e.pkey, .mp4 = e.mp4_path, .size = e.size, .text = post.text, .topic_tag = post.topic_tag, .will_publish = cx.cfg.post.public, .steps = &steps, .note = "dry-run: nothing copied, nothing sent" };
        out.say(cx, "dry-run: would post '{s}' ({d} MB), {s}\n  text ({d} units): {s}\n  topic tag: {s}\n  nothing was copied or sent. Add --live to send.", .{ e.name, e.size / (1024 * 1024), if (cx.cfg.post.public) "PUBLISHED" else "staged only", post.weight, post.text, post.topic_tag orelse "(none)" });
        out.json(cx, a, p);
        return .{ .code = exit.OK, .state = "dry-run", .name = e.name, .note = "nothing sent" };
    }
    if (!host.configured(cx)) return res(exit.USAGE, "config", "host.dir, host.done_dir and host.base_url must be set: Threads downloads the video from your own https folder");
    switch (tokc.refresh(cx, a, false)) { // auto-refresh when due; a failure is logged, the run goes on with the old token
        .done => log.log(cx, "info", "token refreshed before the run", .{}),
        else => {},
    }
    const tok = cx.token() orelse return res(exit.USAGE, "config", "no access token: set the env var or the file named in config account.token_*");
    var uid: []const u8 = cx.userId() orelse "";
    if (uid.len == 0) switch (auth.me(cx, a, tok)) {
        .ok => |m| uid = m.id,
        .fail => |f| return res(exit.BLOCKED, "blocked", try std.fmt.allocPrint(a, "cannot learn the account id: {s}", .{f.info.msg})),
    };
    return sendOne(cx, a, &db, e, post, tok, uid, again);
}

// a pair already in the ledger: answer from it, never send again
fn replay(a: std.mem.Allocator, db: *sq.Db, e: pair.Entry) !Result {
    const row = (try send.byPkey(db, a, e.pkey)) orelse return res(exit.FAILED, "failed", "ledger row vanished");
    const code: u8 = switch (row.state) {
        .posted => exit.OK,
        .staged => exit.OK,
        .unsure, .sending => exit.UNSURE,
        .failed => exit.FAILED,
    };
    const note = if (row.state == .failed) try std.fmt.allocPrint(a, "failed earlier ({s}); a person can retry with --again", .{row.note}) else if (row.state == .staged) "staged, never published (post.public is false)" else row.note;
    return .{ .code = code, .state = if (row.state == .posted) "already-posted" else send.stateName(row.state), .name = e.name, .container = row.container_id, .url = row.url, .note = note };
}

// settle a row. A finished row (posted, failed) gives its hosted copy back to done_dir; unsure/staged keep it (the container may still be fetched or published)
fn finishRow(cx: *Ctx, a: std.mem.Allocator, db: *sq.Db, row: send.Row, name: []const u8, st: send.State, code: u8, note: []const u8, media: []const u8, url: []const u8) !Result {
    const nn = text.safeNote(a, note, 400);
    try send.setState(cx, db, row.id, st, nn, media, url);
    if (st == .posted or st == .failed) host.finish(cx, a, row.host_file) catch |er| log.log(cx, "warn", "hosted copy not moved: {s}", .{@errorName(er)});
    log.log(cx, "info", "{s} {s}: {s}", .{ name, send.stateName(st), nn });
    return .{ .code = code, .state = send.stateName(st), .name = name, .container = row.container_id, .url = url, .note = nn };
}

// what a failed call means for the row and the run
fn failRow(cx: *Ctx, a: std.mem.Allocator, db: *sq.Db, row: send.Row, name: []const u8, f: call.Fail, stage: []const u8) !Result {
    const note = try std.fmt.allocPrint(a, "{s}: {s} (code {d}/{d}, http {d})", .{ stage, f.info.msg, f.info.code, f.info.sub, f.http }); // parsed fields only: a raw body could echo a secret
    switch (f.info.class) {
        .blocked => {
            try caps.blockFor(db, cx.nowMs(), caps.quotaBlockMs(cx), try std.fmt.allocPrint(a, "token or permission, code {d}", .{f.info.code}));
            return finishRow(cx, a, db, row, name, .failed, exit.BLOCKED, note, "", "");
        },
        .breaker => {
            try caps.hardStop(db);
            return finishRow(cx, a, db, row, name, .failed, exit.BLOCKED, note, "", "");
        },
        .stop_day => {
            try caps.blockFor(db, cx.nowMs(), caps.quotaBlockMs(cx), try std.fmt.allocPrint(a, "code {d}", .{f.info.code}));
            return finishRow(cx, a, db, row, name, .failed, exit.BLOCKED, note, "", "");
        },
        else => {
            try caps.recordFail(cx, db);
            return finishRow(cx, a, db, row, name, .failed, exit.FAILED, note, "", "");
        },
    }
}

fn reload(db: *sq.Db, a: std.mem.Allocator, id: i64, pkey: []const u8) !send.Row {
    _ = id;
    return (try send.byPkey(db, a, pkey)) orelse error.LedgerRowVanished;
}

const Polled = union(enum) { finished, status: st_api.Status, fail: call.Fail, timeout };

// poll the container until FINISHED / a final word / the budget ends. A 404 on the first two reads = still propagating.
fn poll(cx: *Ctx, a: std.mem.Allocator, tok: []const u8, container: []const u8, first: bool) Polled {
    const iters = @max(1, cx.cfg.net.status_poll_max_s / cx.cfg.net.status_poll_s);
    var i: u32 = 0;
    while (i < iters) : (i += 1) {
        switch (st_api.get(cx, a, tok, container)) {
            .fail => |f| {
                const young = f.http == 404 and (first and i < 2);
                if (f.info.class != .retry and !young) return .{ .fail = f };
            },
            .ok => |s| switch (s.kind) {
                .finished => return .finished,
                .published, .failed, .expired => return .{ .status = s },
                .in_progress, .unknown => {},
            },
        }
        cx.sleepMs(@as(i64, cx.cfg.net.status_poll_s) * 1000);
    }
    return .timeout;
}

fn sendOne(cx: *Ctx, a: std.mem.Allocator, db: *sq.Db, e: pair.Entry, post: text.Post, tok: []const u8, uid: []const u8, again: bool) anyerror!Result {
    const t0 = util.monoMs(cx.io);
    const budget_ms = @as(i64, cx.cfg.limits.run_budget_s) * 1000;
    const key = try dupe.prefix(a, post.text, cx.cfg.safety.dup_chars);
    const existing = try send.byPkey(db, a, e.pkey);
    // lost-ledger probe + server quota, BEFORE any row or file: a dead token or a limit leaves the pair ready.
    // Also for a failed row whose publish request once left (a late post may exist): --again must not double it.
    const past_pub = if (existing) |old| old.state == .failed and old.pub_at > 0 else false;
    if ((existing == null or past_pub) and cx.cfg.safety.dup_probe) {
        const days: i64 = @max(1, @as(i64, cx.cfg.source.max_age_days)); // a pair can wait that long in the folder
        const since = @divTrunc(cx.nowMs(), 1000) - days * 24 * 3600;
        switch (look.list(cx, a, tok, uid, since)) {
            .fail => |f| return res(exit.BLOCKED, "blocked", try std.fmt.allocPrint(a, "cannot read the account's recent posts ({s}): not sending blind; the pair stays ready", .{f.info.msg})),
            .ok => |items| {
                if (try dupe.match(a, post.text, items, cx.cfg.safety.dup_chars)) |hit| {
                    const note = try std.fmt.allocPrint(a, "looks already posted (account post {s}): run resolve", .{hit});
                    if (existing) |old| {
                        try send.setState(cx, db, old.id, .unsure, note, hit, "");
                    } else {
                        const id = send.begin(cx, db, a, e.name, e.pkey, key) catch |er| if (er == error.Replay) return replay(a, db, e) else return er;
                        try send.setState(cx, db, id, .unsure, note, hit, "");
                    }
                    return .{ .code = exit.UNSURE, .state = "unsure", .name = e.name, .note = "the account already has a post that starts like this one: nothing sent, run resolve" };
                }
                if (items.len >= look.list_limit) return res(exit.BLOCKED, "blocked", "the account has too many recent posts to be sure this one is not among them: not sending blind; raise nothing, wait or check by hand");
            },
        }
    }
    switch (quota_api.get(cx, a, tok, uid)) {
        .fail => |f| return res(exit.BLOCKED, "blocked", try std.fmt.allocPrint(a, "cannot read the publishing quota ({s}); the pair stays ready", .{f.info.msg})),
        .ok => |q| if (q.usage >= q.total - @as(i64, cx.cfg.limits.quota_margin)) {
            try caps.blockFor(db, cx.nowMs(), caps.quotaBlockMs(cx), try std.fmt.allocPrint(a, "quota {d}/{d}", .{ q.usage, q.total }));
            return res(exit.BLOCKED, "blocked", try std.fmt.allocPrint(a, "Threads quota {d} of {d} used: stopped before any copy", .{ q.usage, q.total }));
        },
    }
    // the row
    var row: send.Row = undefined;
    if (existing) |old| {
        switch (old.state) {
            .failed => {
                if (!again) return replay(a, db, e);
                try send.reuse(cx, db, old.id, true, "retry by a person");
            },
            .sending, .staged => {},
            else => return replay(a, db, e),
        }
        row = try reload(db, a, old.id, e.pkey);
    } else {
        const id = send.begin(cx, db, a, e.name, e.pkey, key) catch |er| if (er == error.Replay) return replay(a, db, e) else return er;
        row = try reload(db, a, id, e.pkey);
    }
    // 1 container: continue the stored one, else host + create
    var just_created = false;
    while (true) {
        if (util.monoMs(cx.io) - t0 > budget_ms) return res(exit.NOTHING, "waiting", "run budget used up; the next run continues this container");
        if (row.container_id.len > 0) {
            switch (st_api.get(cx, a, tok, row.container_id)) {
                .fail => |f| return res(exit.FAILED, "failed", try std.fmt.allocPrint(a, "cannot read the stored container ({s}); the row stays, the next run tries again", .{f.info.msg})),
                .ok => |s| switch (s.kind) {
                    .in_progress, .finished, .unknown => break,
                    .published => {
                        try send.setState(cx, db, row.id, .unsure, "the container is already PUBLISHED: run resolve", "", "");
                        return .{ .code = exit.UNSURE, .state = "unsure", .name = e.name, .container = row.container_id, .note = "the stored container is already published: run resolve" };
                    },
                    .failed, .expired => {
                        host.finish(cx, a, row.host_file) catch {};
                        if (row.tries >= cx.cfg.retry_pre_send) {
                            try caps.recordFail(cx, db);
                            return finishRow(cx, a, db, row, e.name, .failed, exit.FAILED, try std.fmt.allocPrint(a, "container {s}: {s}", .{ s.raw, err.containerError(a, s.error_message).why }), "", "");
                        }
                        try send.reuse(cx, db, row.id, false, "container ended, new attempt");
                        row = try reload(db, a, row.id, e.pkey);
                        continue;
                    },
                },
            }
        }
        kill.writeOk(cx) catch return res(exit.BLOCKED, "blocked", "kill file switched on during the run: stopped before copying");
        // host copy, public check, create
        const staged = host.stage(cx, a, e.mp4_path) catch |er| return finishRow(cx, a, db, row, e.name, .failed, exit.FAILED, try std.fmt.allocPrint(a, "could not copy the mp4 to host.dir: {s}", .{@errorName(er)}), "", "");
        try send.setHost(cx, db, row.id, staged.file);
        row.host_file = staged.file;
        if (cx.cfg.host.selfcheck) {
            const chk = host.selfCheck(cx, a, staged.url, e.size);
            if (!chk.ok) {
                try caps.recordFail(cx, db);
                return finishRow(cx, a, db, row, e.name, .failed, exit.FAILED, chk.note, "", "");
            }
        }
        switch (create_api.create(cx, a, tok, uid, .{ .video_url = staged.url, .text = post.text, .topic_tag = post.topic_tag, .reply_control = cx.cfg.post.reply_control })) {
            .ok => |cid| {
                try send.setContainer(cx, db, row.id, cid);
                row.container_id = cid;
                just_created = true;
                break;
            },
            .fail => |f| {
                if (f.info.class == .retry and row.tries < cx.cfg.retry_pre_send) {
                    host.finish(cx, a, staged.file) catch {};
                    cx.sleepMs(@as(i64, cx.cfg.net.backoff_ms) * @as(i64, @intCast(row.tries + 1)));
                    try send.reuse(cx, db, row.id, false, "create failed, new attempt");
                    row = try reload(db, a, row.id, e.pkey);
                    continue;
                }
                return failRow(cx, a, db, row, e.name, f, "create");
            },
        }
    }
    if (cx.crash_at == 1) return error.Crash;
    // 2 wait for FINISHED (Meta: wait about 30 s, then poll once a minute for at most 5 minutes)
    if (just_created) cx.sleepMs(@as(i64, cx.cfg.net.settle_s) * 1000);
    switch (poll(cx, a, tok, row.container_id, just_created)) {
        .finished => {},
        .timeout => return .{ .code = exit.NOTHING, .state = "waiting", .name = e.name, .container = row.container_id, .note = "Threads is still processing the video; the next run continues this container" },
        .fail => |f| return failRow(cx, a, db, row, e.name, f, "status"),
        .status => |s| switch (s.kind) {
            .published => {
                try send.setState(cx, db, row.id, .unsure, "the container is PUBLISHED before we sent publish: run resolve", "", "");
                return .{ .code = exit.UNSURE, .state = "unsure", .name = e.name, .container = row.container_id, .note = "container already published: run resolve" };
            },
            else => {
                const ce = err.containerError(a, s.error_message);
                if (ce.class == .retry and row.tries < cx.cfg.retry_pre_send) { // a download problem: new file name, new container
                    host.finish(cx, a, row.host_file) catch {};
                    try send.reuse(cx, db, row.id, false, ce.why);
                    return sendOne(cx, a, db, e, post, tok, uid, again);
                }
                try caps.recordFail(cx, db);
                return finishRow(cx, a, db, row, e.name, .failed, exit.FAILED, try std.fmt.allocPrint(a, "container {s}: {s} ({s})", .{ s.raw, s.error_message, ce.why }), "", "");
            },
        },
    }
    if (cx.crash_at == 2) return error.Crash;
    // 3 staged: FINISHED, nothing public
    if (!cx.cfg.post.public) {
        try send.setState(cx, db, row.id, .staged, "container FINISHED, not published (post.public is false); it expires in 24 h", "", "");
        log.log(cx, "info", "{s} staged", .{e.name});
        return .{ .code = exit.OK, .state = "staged", .name = e.name, .container = row.container_id, .note = "container FINISHED, nothing published (post.public is false)" };
    }
    // the file we measured must be the file we hosted: a producer rewrite means mixed bytes
    const st2 = std.Io.Dir.cwd().statFile(cx.io, e.mp4_path, .{}) catch return finishRow(cx, a, db, row, e.name, .failed, exit.FAILED, "the source mp4 vanished before publish", "", "");
    if (st2.size != e.size or st2.mtime.toMilliseconds() != e.mp4_mtime_ms) return finishRow(cx, a, db, row, e.name, .failed, exit.FAILED, "the source mp4 changed while hosted: not published", "", "");
    // 4 publish = the point of no return. pub_at first, so the cap counts it even if we die here
    kill.writeOk(cx) catch return res(exit.BLOCKED, "blocked", "kill file switched on during the run: not published; the row stays and the next run continues it");
    try send.markPub(cx, db, row.id);
    if (cx.crash_at == 3) return error.Crash;
    const pr = pub_api.publish(cx, a, tok, uid, row.container_id, false);
    const media: []const u8 = switch (pr) {
        .ok => |m| m,
        .fail => |f| {
            const definite = f.http >= 400 and f.http < 500 and f.info.class != .retry;
            if (!f.sent and f.http == 0) { // the request provably never left (DNS, connect or TLS failed: `sent` is set only after the handshake)
                try send.clearPub(db, row.id);
                return res(exit.FAILED, "failed", try std.fmt.allocPrint(a, "publish never left ({s}); the row stays, the next run tries again", .{f.info.msg}));
            }
            if (definite) return failRow(cx, a, db, row, e.name, f, "publish");
            // the request left and the answer is lost, a 5xx, or unreadable: Threads may have published
            try caps.setGap(cx, db);
            return finishRow(cx, a, db, row, e.name, .unsure, exit.UNSURE, try std.fmt.allocPrint(a, "publish sent, answer lost or {d} ({s}): run resolve", .{ f.http, f.info.msg }), "", "");
        },
    };
    if (cx.crash_at == 4) return error.Crash;
    try caps.setGap(cx, db);
    // 5 confirm
    var url: []const u8 = "";
    switch (look.media(cx, a, tok, media)) {
        .ok => |it| {
            url = it.permalink;
            if (!std.mem.eql(u8, it.media_type, "VIDEO") and it.media_type.len > 0) log.log(cx, "warn", "{s}: confirm read media_type {s}", .{ e.name, it.media_type });
        },
        .fail => log.log(cx, "warn", "{s}: posted but the confirm read failed", .{e.name}),
    }
    try caps.recordOk(db);
    if (tokc.daysLeft(cx)) |d| if (d < cx.cfg.token_warn_days) log.log(cx, "warn", "token has {d} days left", .{d});
    return finishRow(cx, a, db, row, e.name, .posted, exit.OK, "published", media, url);
}
