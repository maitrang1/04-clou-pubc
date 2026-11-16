// =====================================================================
// Des: The sending engine shared by publish and recovery - streams the upload with resume, never uploads twice (asks the session after any lost answer), records posted, polls processing, and maps every error to the right ledger state, breaker or stop
// Flo: put bytes > done | resume (ask the session, continue at the byte it names) | lost answer = ask | expired = unsure | out of time or kill file = leave it `sending` (resumes next run) > posted written at once > poll status
// Cre: 2026-11-15                          - | Mod: 2026-11-15
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: Job (ctx, ledger, token, row key, file, size, session address)
// Out: Outcome (posted | failed | unsure | stopped) + a plain message; ledger, breaker and stop flags updated
// Run: not run directly - imported by cm-publish and cm-resolve
// =====================================================================
const std = @import("std");
const ctx_mod = @import("co-ctx.zig");
const util = @import("co-util.zig");
const log = @import("co-log.zig");
const kill = @import("co-kill.zig");
const send = @import("rw-send.zig");
const caps = @import("rw-caps.zig");
const call = @import("ap-call.zig");
const upload = @import("ap-upload.zig");
const status = @import("ap-status.zig");
const ap_err = @import("ap-err.zig");

pub const Outcome = enum { posted, failed, unsure, stopped };

pub const Job = struct {
    cx: *const ctx_mod.Ctx,
    a: std.mem.Allocator,
    l: send.Ledger,
    t: *call.Tok,
    pkey: []const u8,
    name: []const u8,
    mp4: []const u8,
    size: u64,
    uri: []const u8,
    t0_mono: i64,
    msg: []const u8 = "",
    video_id: []const u8 = "",
    url: []const u8 = "",
};

fn over(j: *const Job) bool {
    return util.monoMs(j.cx.io) - j.t0_mono > @as(i64, j.cx.cfg.limits.run_budget_s) * 1000;
}

fn backoff(j: *const Job, tries: u32, retry_after_s: u32) void {
    const shift: u5 = @intCast(@min(tries -| 1, 5));
    const base = @as(i64, j.cx.cfg.net.backoff_ms) << shift;
    j.cx.sleepMs(@min(@max(base, @as(i64, retry_after_s) * 1000), 60_000));
}

fn say(j: *Job, comptime fmt: []const u8, args: anytype) void {
    j.msg = std.fmt.allocPrint(j.a, fmt, args) catch "message too long";
}

// ledger write that must not fail silently: the message tells the owner what to check
fn mark(j: *Job, st: send.State, note: []const u8) void {
    j.l.setState(j.pkey, st, note, j.cx.nowMs()) catch say(j, "ledger write failed while marking {s}: check {s} by hand", .{ st.name(), j.name });
}

// nothing reached YouTube: queued again, and it does not count against the cap or the gap
fn requeue(j: *Job, note: []const u8) Outcome {
    j.l.requeue(j.pkey, note, j.cx.nowMs()) catch say(j, "ledger write failed while queueing {s} again: check it by hand", .{j.name});
    say(j, "{s}: queued again", .{note});
    return .stopped;
}

// the session is alive and the bytes may be partly there: keep the row `sending` so the next run resumes it
fn leave(j: *Job, why: []const u8) Outcome {
    mark(j, .sending, why);
    say(j, "{s}: it resumes next run", .{why});
    log.line(j.cx, "WARN", "left sending {s}: {s}", .{ j.name, why });
    return .stopped;
}

fn parkKey(j: *Job) []const u8 {
    return std.fmt.allocPrint(j.a, "park:{s}", .{j.pkey}) catch "park";
}

// a failed attempt to finish: counted across runs; after net.retries runs the row becomes unsure for a person
pub fn park(j: *Job, why: []const u8) Outcome {
    const k = parkKey(j);
    const n = (j.l.kvInt(k) catch 0) + 1;
    j.l.kvSetInt(k, n) catch {};
    if (n >= @max(1, j.cx.cfg.net.retries)) return unsure(j, why);
    return leave(j, why);
}

fn clearPark(j: *Job) void {
    j.l.kvSetInt(parkKey(j), 0) catch {};
}

// map a Google verdict to ledger/breaker/stop. post_bytes = the video bytes already left (then nothing is requeued)
pub fn recordApi(j: *Job, v: ap_err.Verdict, post_bytes: bool) Outcome {
    const now = j.cx.nowMs();
    switch (v.class) {
        .stop_quota, .stop_channel => {
            const which = if (v.class == .stop_quota) "API quota (quotaExceeded)" else "channel daily upload limit (uploadLimitExceeded)";
            caps.stopSet(j.l, caps.ptDay(now), which) catch {};
            log.line(j.cx, "WARN", "stop day {s} {s}", .{ j.name, which });
            if (post_bytes) {
                mark(j, .failed, which);
                say(j, "stopped until the next Pacific midnight: {s}", .{which});
                return .stopped;
            }
            _ = requeue(j, which);
            say(j, "stopped until the next Pacific midnight: {s}", .{which});
            return .stopped;
        },
        .hard => {
            caps.breakerHard(j.l, v.reason) catch {};
            mark(j, .failed, v.reason);
            say(j, "YouTube refused ({s}): breaker open, a person must look", .{v.reason});
            return .failed;
        },
        .blocked, .unauth => {
            if (post_bytes) {
                mark(j, .unsure, v.why);
                say(j, "blocked: {s}", .{v.why});
                return .unsure;
            }
            _ = requeue(j, v.why);
            say(j, "blocked: {s}", .{v.why});
            return .stopped;
        },
        .fail, .notfound, .unknown, .retry => {
            caps.breakerFail(j.l, now) catch {};
            const why = if (v.reason.len > 0) v.reason else v.why;
            mark(j, .failed, why);
            say(j, "failed: {s} (HTTP {d})", .{ why, v.status });
            return .failed;
        },
    }
}

fn unsure(j: *Job, why: []const u8) Outcome {
    mark(j, .unsure, why);
    say(j, "unsure: {s}. Run: shorts resolve --video {s}", .{ why, j.name });
    log.line(j.cx, "WARN", "unsure {s}: {s}", .{ j.name, why });
    return .unsure;
}

// the video is on YouTube: write that first, then watch processing
pub fn afterPosted(j: *Job, id: []const u8) Outcome {
    const cx = j.cx;
    const url = std.fmt.allocPrint(j.a, "{s}{s}", .{ cx.cfg.google.watch_url, id }) catch "";
    j.video_id = id;
    j.url = url;
    j.l.setPosted(j.pkey, id, url, "", cx.nowMs()) catch {
        say(j, "uploaded as {s} but the ledger write failed: run resolve", .{id});
        return .unsure;
    };
    clearPark(j);
    caps.breakerOk(j.l) catch {};
    log.line(cx, "INFO", "posted {s} as {s}", .{ j.name, id });
    const n = cx.cfg.net;
    const polls: u32 = @max(1, n.status_poll_max_s / n.status_poll_s);
    var note: []const u8 = "";
    var i: u32 = 0;
    while (i < polls) : (i += 1) {
        switch (status.video(j.t, id)) {
            .ok => |v| {
                if (v.isDone()) {
                    say(j, "posted and processed: {s}", .{url});
                    return .posted;
                }
                if (v.isBad()) {
                    const reason = if (v.rejection_reason.len > 0) v.rejection_reason else v.failure_reason;
                    const why = std.fmt.allocPrint(j.a, "YouTube says {s} {s}", .{ v.upload_status, reason }) catch "YouTube refused the video";
                    mark(j, .failed, why);
                    if (std.mem.eql(u8, v.upload_status, "rejected")) caps.breakerHard(j.l, "rejected") catch {};
                    say(j, "{s}", .{why});
                    return .failed;
                }
                note = "still processing";
            },
            .api => |v| {
                note = if (v.class == .blocked) "processing not checked (the sign-in lacks the read-only permission)" else "processing check failed";
                if (v.class == .blocked) break;
            },
            .net, .bad_reply => note = "processing check failed",
        }
        if (i + 1 < polls) cx.sleepMs(@as(i64, n.status_poll_s) * 1000);
    }
    j.l.setState(j.pkey, .posted, note, cx.nowMs()) catch {};
    say(j, "posted, {s}: {s}", .{ note, url });
    return .posted;
}

// upload from byte `from`; resume by asking the session; never start a second session
pub fn uploadFrom(j: *Job, from: u64) Outcome {
    const cx = j.cx;
    var offset = from;
    var any_bytes = from > 0;
    var tries: u32 = 0;
    const max = cx.cfg.net.retries;
    while (true) {
        // a kill file or the run budget ends the run cleanly: queued again if no byte left, else resumable
        if (kill.isOn(cx, j.a)) return if (any_bytes) leave(j, "kill file is on") else requeue(j, "kill file is on");
        if (over(j)) return if (any_bytes) leave(j, "run budget ended mid-upload") else requeue(j, "run budget ended before the upload");
        const r = upload.put(j.t, j.uri, j.mp4, j.size, offset);
        var retry_after: u32 = 0;
        switch (r) {
            .done => |id| return afterPosted(j, id),
            .incomplete => |nx| {
                any_bytes = true;
                tries = if (nx.byte > offset) 0 else tries + 1;
                offset = nx.byte;
                if (tries > max) return park(j, "upload kept stopping short");
                backoff(j, 1, nx.retry_after_s);
                continue;
            },
            .expired => return if (any_bytes) unsure(j, "upload session expired mid-way") else requeue(j, "upload session expired before any byte"),
            .file_error => return if (any_bytes) unsure(j, "the source file became unreadable mid-upload") else blk: {
                mark(j, .failed, "the source file cannot be read");
                say(j, "failed: the source file cannot be read", .{});
                break :blk Outcome.failed;
            },
            .bad_reply => return unsure(j, "YouTube's answer was not understood"),
            .api => |v| {
                if (v.class != .retry) return recordApi(j, v, true);
                any_bytes = true; // a 5xx may follow bytes that arrived: ask
                retry_after = v.retry_after_s;
            },
            .net => |lost| {
                if (lost.sent > 0) any_bytes = true;
            },
        }
        // lost or 5xx answer: ask the session before anything else
        var asked = false;
        while (!asked) {
            tries += 1;
            if (tries > max) {
                if (any_bytes) return park(j, "answer lost and the session could not be asked");
                caps.breakerFail(j.l, cx.nowMs()) catch {};
                return requeue(j, "network kept failing before any byte");
            }
            backoff(j, tries, retry_after);
            retry_after = 0;
            switch (upload.ask(j.t, j.uri, j.size)) {
                .done => |id| return afterPosted(j, id),
                .incomplete => |nx| {
                    tries = if (nx.byte > offset) 0 else tries;
                    offset = nx.byte;
                    asked = true;
                },
                .expired => return if (any_bytes) unsure(j, "answer lost and the upload session expired") else requeue(j, "upload session expired before any byte"),
                .bad_reply => return unsure(j, "session answer not understood"),
                .file_error => {},
                .api => |v| {
                    if (v.class != .retry) return recordApi(j, v, any_bytes);
                    retry_after = v.retry_after_s;
                },
                .net => {},
            }
        }
    }
}
// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
