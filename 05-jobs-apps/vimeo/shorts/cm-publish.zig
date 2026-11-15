// =====================================================================
// Des: The publish command - picks the oldest ready video, runs every gate (kill file, run lock, ledger, breaker, daily stop, cap, gap), then uploads it once and records the result; dry run unless --live
// Flo: kill? > lock > ledger > recover crashed sends > pick > gates > build text > dry run prints | live: token > row sending > session > streamed upload > posted > poll
// Cre: 2026-11-15                          - | Mod: 2026-11-15
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: publish [--video NAME] [--live] [--config FILE] [--json]
// Out: exit 0 ok · 1 failed · 2 usage/config · 3 blocked · 4 nothing to do · 5 unsure; one result line
// Run: /home/mai_trang/04-clou-base/05-jobs-apps/vimeo/shorts/zig-out/bin/shorts publish --config 00-config.json
// =====================================================================
const std = @import("std");
const ctx_mod = @import("co-ctx.zig");
const util = @import("co-util.zig");
const args = @import("co-args.zig");
const exit = @import("co-exit.zig");
const kill = @import("co-kill.zig");
const lock = @import("co-lock.zig");
const log = @import("co-log.zig");
const disk = @import("co-disk.zig");
const send = @import("rw-send.zig");
const caps = @import("rw-caps.zig");
const pair = @import("rw-pair.zig");
const pick = @import("rw-pick.zig");
const text = @import("rw-text.zig");
const auth = @import("ap-auth.zig");
const call = @import("ap-call.zig");
const session = @import("ap-session.zig");
const upload = @import("ap-upload.zig");
const engine = @import("cm-send.zig");

pub fn privacyOf(p: @import("co-cfg.zig").Post) []const u8 {
    if (p.public) return "public";
    if (std.mem.eql(u8, p.visibility, "unlisted")) return "unlisted";
    return "private";
}

fn authFail(cx: *const ctx_mod.Ctx, e: auth.Err) u8 {
    switch (e) {
        error.NoClientId => util.eprint(cx.io, "error: no client id\nwhy: no env {s} and no file {s} in the secrets folder\nfix: do \"Create your Google client id\" in 10-HOW-TO\n", .{ cx.cfg.google.client_id_env, cx.cfg.google.client_id_file }),
        error.NoRefreshToken => util.eprint(cx.io, "error: not logged in\nwhy: no refresh token file\nfix: run: shorts login --live\n", .{}),
        error.InvalidGrant => util.eprint(cx.io, "error: refresh token dead\nwhy: Google says invalid_grant (revoked, or Testing mode 7-day limit)\nfix: set the consent screen to In production, then run: shorts login --live --force\n", .{}),
        else => {
            util.eprint(cx.io, "error: sign-in failed ({s})\nwhy: network or Google problem\nfix: try again; run: shorts doctor\n", .{@errorName(e)});
            return exit.failed;
        },
    }
    return exit.blocked;
}

fn show(cx: *const ctx_mod.Ctx, a: std.mem.Allocator, json: bool, action: []const u8, name: []const u8, state: []const u8, msg: []const u8, id: []const u8, url: []const u8) void {
    if (json) {
        const J = struct { action: []const u8, name: []const u8, state: []const u8, message: []const u8, video_uri: []const u8, url: []const u8 };
        const s = util.jsonStr(a, J{ .action = action, .name = name, .state = state, .message = msg, .video_uri = id, .url = url }) catch return;
        util.printAll(cx.io, s);
        util.printAll(cx.io, "\n");
    } else {
        util.print(cx.io, "{s} {s}: {s}{s}{s}\n", .{ action, name, msg, if (url.len > 0) " " else "", url });
    }
}

fn code(o: engine.Outcome) u8 {
    return switch (o) {
        .posted => exit.ok,
        .failed => exit.failed,
        .unsure => exit.unsure,
        .stopped => exit.blocked,
    };
}

// a crashed earlier send (row still `sending`): ask its session, resume or park it. Returns the worst exit code seen.
const Rec = struct { worst: u8 = exit.ok, acted: bool = false };

fn recover(cx: *const ctx_mod.Ctx, a: std.mem.Allocator, l: send.Ledger, items: []const pair.Item, live: bool, json: bool, t0: i64) Rec {
    const rows = l.listState(a, .sending) catch return .{};
    if (rows.len == 0) return .{};
    var worst: u8 = exit.ok;
    var acted = false;
    var tok: ?call.Tok = null;
    for (rows) |r| {
        if (!live) {
            util.print(cx.io, "dry run: would recover the crashed send {s}\n", .{r.name});
            continue;
        }
        if (r.upload_link.len == 0) {
            l.requeue(r.pkey, "crashed before the upload started", cx.nowMs()) catch {};
            show(cx, a, json, "recover", r.name, "ready", "crashed before the upload started: queued again", "", "");
            acted = true;
            continue;
        }
        if (tok == null) {
            tok = call.Tok.init(cx, a) catch |e| return .{ .worst = @max(worst, authFail(cx, e)), .acted = acted };
            l.kvSetInt("token_ok", cx.nowMs()) catch {};
        }
        var mp4: []const u8 = "";
        var file_size: u64 = 0;
        for (items) |it| if (std.mem.eql(u8, it.pkey, r.pkey)) {
            mp4 = it.mp4_path;
            if (it.facts) |f| file_size = f.size;
        };
        var j = engine.Job{ .cx = cx, .a = a, .l = l, .t = &tok.?, .pkey = r.pkey, .name = r.name, .mp4 = mp4, .size = @intCast(r.bytes), .uri = r.upload_link, .t0_mono = t0 };
        const o: engine.Outcome = switch (upload.ask(&tok.?, r.upload_link, j.size)) {
            .done => |id| engine.afterPosted(&j, id),
            .incomplete => |nx| blk: {
                if (mp4.len == 0 or file_size != r.bytes) {
                    const why = if (mp4.len == 0) "crashed mid-upload and the source file is gone" else "crashed mid-upload and the source file changed since";
                    l.setState(r.pkey, .unsure, why, cx.nowMs()) catch {};
                    j.msg = why;
                    break :blk engine.Outcome.unsure;
                }
                break :blk engine.uploadFrom(&j, nx.byte);
            },
            .expired => blk: {
                l.setState(r.pkey, .unsure, "crashed after sending and the upload session expired", cx.nowMs()) catch {};
                j.msg = "crashed after sending and the upload session expired";
                break :blk engine.Outcome.unsure;
            },
            // cannot tell now: stays `sending` and is asked again next run, a few runs at most
            .bad_reply, .api, .net, .file_error => engine.park(&j, "could not ask the upload session"),
        };
        show(cx, a, json, "recover", r.name, @tagName(o), j.msg, j.video_uri, j.url);
        worst = @max(worst, code(o));
        acted = true;
    }
    return .{ .worst = worst, .acted = acted };
}

pub fn run(cx: *const ctx_mod.Ctx, av: []const []const u8, json: bool) u8 {
    var arena = std.heap.ArenaAllocator.init(cx.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const live = args.has(av, "--live");
    const only = args.value(av, "--video");
    const t0 = util.monoMs(cx.io);

    if (kill.isOn(cx, a)) {
        util.eprint(cx.io, "blocked: kill file is on\nwhy: {s}/{s} exists\nfix: shorts kill off\n", .{ cx.data_dir, cx.cfg.kill_file });
        return exit.blocked;
    }
    const lk = lock.take(cx, a) catch {
        util.eprint(cx.io, "blocked: another run is active\nwhy: the run lock is held\nfix: wait for it to end\n", .{});
        return exit.blocked;
    };
    defer lk.release();
    const l = send.Ledger.open(cx, a) catch {
        util.eprint(cx.io, "blocked: the ledger cannot be read\nwhy: a cap that fails open is no cap, so the run stops\nfix: check {s}/{s} (shorts backup, shorts doctor)\n", .{ cx.data_dir, cx.cfg.db_file });
        return exit.blocked;
    };
    defer l.close();
    const items = pair.scan(cx, a) catch |e| {
        util.eprint(cx.io, "error: {s}\nwhy: source.dir is empty or unreadable\nfix: set source.dir in the config to the producer's output folder\n", .{@errorName(e)});
        return exit.usage;
    };
    if (live) if (disk.freeMb(cx.data_dir)) |mb| if (mb < cx.cfg.limits.disk_min_mb) {
        util.eprint(cx.io, "blocked: low disk space ({d} MB free, limits.disk_min_mb {d})\nwhy: the ledger and log need room\nfix: free some space\n", .{ mb, cx.cfg.limits.disk_min_mb });
        return exit.blocked;
    };

    const rec = recover(cx, a, l, items, live, json, t0);
    // after recovery: a worse code wins; recovery that settled something is a successful run
    const rec_code: u8 = rec.worst;

    // choose the video
    var picked: ?pick.Picked = null;
    if (only) |n| {
        const it = pick.byName(items, n) orelse {
            util.eprint(cx.io, "error: no video named {s}\nwhy: not in source.dir\nfix: shorts scan\n", .{n});
            return exit.usage;
        };
        const row = l.find(a, it.pkey) catch null;
        const k = pick.kindOf(it, row);
        if (k == .posted) {
            show(cx, a, json, "replay", it.name, "posted", "already posted, nothing sent", row.?.video_uri, row.?.url);
            return exit.ok;
        }
        if (k != .ready and k != .approved) {
            util.eprint(cx.io, "nothing to do: {s} is {s}\nwhy: only ready or approved videos are sent{s}\nfix: shorts scan\n", .{ it.name, pick.label(k), if (k == .held) " (a review video needs: shorts approve)" else "" });
            return if (rec_code > exit.ok) rec_code else if (rec.acted) exit.ok else exit.nothing;
        }
        picked = .{ .item = it, .row = row };
    } else {
        picked = pick.next(a, l, items) catch {
            util.eprint(cx.io, "blocked: the ledger cannot be read\nwhy: a cap that fails open is no cap\nfix: shorts doctor\n", .{});
            return exit.blocked;
        };
    }
    const pk = picked orelse {
        util.print(cx.io, "nothing to do: no ready video\n", .{});
        return if (rec_code > exit.ok) rec_code else if (rec.acted) exit.ok else exit.nothing;
    };
    const it = pk.item;

    // gates
    const now = cx.nowMs();
    const drawn = util.randRange(cx.io, cx.cfg.limits.gap_min_s, cx.cfg.limits.gap_max_s);
    const v = caps.mayStart(a, l, cx.cfg, now, drawn) catch {
        util.eprint(cx.io, "blocked: the ledger cannot be read\nwhy: a cap that fails open is no cap\nfix: shorts doctor\n", .{});
        return exit.blocked;
    };
    switch (v) {
        .go => {},
        .wait => |m| {
            util.print(cx.io, "nothing to do now: {s}\n", .{m});
            return if (rec_code > exit.ok) rec_code else if (rec.acted) exit.ok else exit.nothing;
        },
        .blocked => |m| {
            util.eprint(cx.io, "blocked: {s}\nwhy: a safety limit\nfix: wait, or run: shorts status\n", .{m});
            return exit.blocked;
        },
    }

    // text and meta (the pair was checked at scan, so this cannot fail on a ready item)
    const tx = text.build(a, .{ .hooks = it.pair.hooks, .description = it.pair.description, .hashtags = it.pair.hashtags, .listing_url = it.pair.listing_url, .ai_notice = it.pair.ai_notice }, cx.cfg.post) catch {
        util.eprint(cx.io, "error: cannot build the text for {s}\nwhy: title or AI notice missing\nfix: shorts scan\n", .{it.name});
        return exit.failed;
    };
    const meta = session.Meta{ .title = tx.title, .description = tx.description, .tags = tx.tags, .category_id = cx.cfg.post.category_id, .privacy = privacyOf(cx.cfg.post), .made_for_kids = cx.cfg.post.made_for_kids, .notify = cx.cfg.post.notify_subscribers };
    const size = it.facts.?.size;

    if (!live) {
        const J = struct { dry_run: bool, name: []const u8, pkey: []const u8, title: []const u8, privacy: []const u8, bytes: u64, tags: usize, kids: bool, ai_label: bool, notify: bool, desc_bytes: usize };
        if (json) {
            const s = util.jsonStr(a, J{ .dry_run = true, .name = it.name, .pkey = it.pkey, .title = meta.title, .privacy = meta.privacy, .bytes = size, .tags = meta.tags.len, .kids = meta.made_for_kids, .ai_label = true, .notify = meta.notify, .desc_bytes = meta.description.len }) catch return exit.failed;
            util.printAll(cx.io, s);
            util.printAll(cx.io, "\n");
        } else {
            util.print(cx.io, "dry run: would upload {s} ({d} bytes)\n  title: {s}\n  privacy: {s} · kids: {} · AI label: on · notify: {} · tags: {d} · description: {d} bytes\n  nothing was sent. Add --live to send.\n", .{ it.name, size, meta.title, meta.privacy, meta.made_for_kids, meta.notify, meta.tags.len, meta.description.len });
        }
        return exit.ok;
    }

    // live: token first (no ledger change if sign-in fails)
    var tok = call.Tok.init(cx, a) catch |e| return authFail(cx, e);
    l.kvSetInt("token_ok", now) catch {};

    // the row: new, or an approved one going to `sending`
    if (pk.row == null) {
        const fresh = l.insertNew(it.name, it.pkey, .sending, meta.title, now) catch {
            util.eprint(cx.io, "blocked: the ledger cannot be written\nwhy: nothing was sent\nfix: shorts doctor\n", .{});
            return exit.blocked;
        };
        if (!fresh) {
            show(cx, a, json, "replay", it.name, "known", "already in the ledger, nothing sent", "", "");
            return exit.ok;
        }
    }
    l.begin(it.pkey, now, caps.ptDay(now), @intCast(size), meta.title) catch {
        util.eprint(cx.io, "blocked: the ledger cannot be written\nwhy: nothing was sent\nfix: shorts doctor\n", .{});
        return exit.blocked;
    };
    var j = engine.Job{ .cx = cx, .a = a, .l = l, .t = &tok, .pkey = it.pkey, .name = it.name, .mp4 = it.mp4_path, .size = size, .uri = "", .t0_mono = t0 };

    // session (pre-send: retries are safe, no byte has left)
    var attempt: u32 = 0;
    const uri = while (true) : (attempt += 1) {
        switch (session.start(&tok, meta, size)) {
            .ok => |u| break u,
            .api => |av2| {
                if (av2.class == .retry and attempt < cx.cfg.retry_pre_send) {
                    cx.sleepMs(@as(i64, cx.cfg.net.backoff_ms) << @intCast(@min(attempt, 5)));
                    continue;
                }
                if (av2.class == .retry) {
                    caps.breakerFail(l, cx.nowMs()) catch {};
                    l.requeue(it.pkey, "Vimeo kept answering with server errors", cx.nowMs()) catch {};
                    show(cx, a, json, "publish", it.name, "ready", "Vimeo kept answering with server errors: queued again", "", "");
                    return exit.failed;
                }
                const o = engine.recordApi(&j, av2, false);
                show(cx, a, json, "publish", it.name, @tagName(o), j.msg, "", "");
                return code(o);
            },
            .net, .bad_reply => {
                if (attempt < cx.cfg.retry_pre_send) {
                    cx.sleepMs(@as(i64, cx.cfg.net.backoff_ms) << @intCast(@min(attempt, 5)));
                    continue;
                }
                caps.breakerFail(l, cx.nowMs()) catch {};
                l.requeue(it.pkey, "could not start the upload session", cx.nowMs()) catch {};
                show(cx, a, json, "publish", it.name, "ready", "could not start the upload session (network or Google): queued again", "", "");
                return exit.failed;
            },
        }
    };
    j.uri = uri;
    l.setSession(it.pkey, uri, cx.nowMs()) catch {
        util.eprint(cx.io, "blocked: the ledger cannot be written\nwhy: no byte was sent\nfix: shorts doctor\n", .{});
        return exit.blocked;
    };
    log.line(cx, "INFO", "session started for {s} ({d} bytes, {s})", .{ it.name, size, meta.privacy });
    const o = engine.uploadFrom(&j, 0);
    show(cx, a, json, "publish", it.name, @tagName(o), j.msg, j.video_uri, j.url);
    return code(o);
}
// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
