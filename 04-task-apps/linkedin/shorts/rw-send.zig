// The ledger (SQLite): one row per send, pkey UNIQUE = once-only. States: sending -> posted | staged | failed | unsure. Plus meta (breaker, gap, blocks, db_created) and approvals.
// Phases of a sending row: init (session asked) -> parts -> finalized -> available -> creating (the post request is about to leave: the point of no return).
const std = @import("std");
const sq = @import("rw-sqlite.zig");
const Ctx = @import("co-ctx.zig").Ctx;
const kill = @import("co-kill.zig");
const util = @import("co-util.zig");
const text = @import("rw-text.zig");

pub const State = enum { sending, posted, staged, failed, unsure };
pub const Row = struct {
    id: i64,
    name: []const u8,
    pkey: []const u8,
    state: State,
    video_id: []const u8,
    post_id: []const u8,
    url: []const u8,
    attempts: i64,
    created: i64,
    updated: i64,
    finish_at: i64,
    note: []const u8,
    upload_token: []const u8,
    instr: []const u8, // one line per part: first,last,url (the signed URLs: a secret, never printed)
    parts: []const u8, // ETags so far, one per line, in part order
    phase: []const u8,
    expires_at: i64,
};
pub const Err = sq.Err || kill.Err || error{ Replay, BadState, NoDataDir };

const schema =
    \\CREATE TABLE IF NOT EXISTS send(
    \\ id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, pkey TEXT NOT NULL UNIQUE, state TEXT NOT NULL,
    \\ video_id TEXT NOT NULL DEFAULT '', post_id TEXT NOT NULL DEFAULT '', url TEXT NOT NULL DEFAULT '',
    \\ attempts INTEGER NOT NULL DEFAULT 1, created INTEGER NOT NULL, updated INTEGER NOT NULL,
    \\ finish_at INTEGER NOT NULL DEFAULT 0, note TEXT NOT NULL DEFAULT '',
    \\ upload_token TEXT NOT NULL DEFAULT '', instr TEXT NOT NULL DEFAULT '', parts TEXT NOT NULL DEFAULT '', phase TEXT NOT NULL DEFAULT 'init', expires_at INTEGER NOT NULL DEFAULT 0);
    \\CREATE TABLE IF NOT EXISTS fin(id INTEGER PRIMARY KEY AUTOINCREMENT, send_id INTEGER NOT NULL, at INTEGER NOT NULL);
    \\CREATE TABLE IF NOT EXISTS meta(k TEXT PRIMARY KEY, v TEXT NOT NULL);
    \\CREATE TABLE IF NOT EXISTS appr(name TEXT PRIMARY KEY, state TEXT NOT NULL, at INTEGER NOT NULL);
    \\PRAGMA user_version=1;
;

pub fn stateName(s: State) []const u8 {
    return @tagName(s);
}
fn stateOf(s: []const u8) State {
    inline for (@typeInfo(State).@"enum".fields) |f| if (std.mem.eql(u8, s, f.name)) return @enumFromInt(f.value);
    return .unsure; // unknown text in the file = never auto-retried
}

pub fn dbPath(cx: *const Ctx, a: std.mem.Allocator) ![]u8 {
    return cx.dataPath(a, cx.cfg.db_file);
}

// open (creates the data dir and tables). Caller closes.
pub fn open(cx: *const Ctx) Err!sq.Db {
    const d = cx.dataPath(cx.gpa, "") catch return Err.NoDataDir;
    defer cx.gpa.free(d);
    util.mkdirp(cx.io, std.mem.trimEnd(u8, d, "/")) catch return Err.NoDataDir;
    const p = dbPath(cx, cx.gpa) catch return Err.NoDataDir;
    defer cx.gpa.free(p);
    var db = try sq.Db.open(p, cx.gpa);
    errdefer db.close();
    try db.exec(schema);
    var uv = try db.prepare("PRAGMA user_version");
    defer uv.finalize();
    _ = try uv.step();
    if (uv.colInt(0) > 1) return Err.BadState; // a newer app wrote this ledger: do not guess
    var ins = try db.prepare("INSERT OR IGNORE INTO meta(k,v) VALUES('db_created',?1)");
    defer ins.finalize();
    var nb: [32]u8 = undefined;
    try ins.text(1, std.fmt.bufPrint(&nb, "{d}", .{cx.nowMs()}) catch "0");
    _ = try ins.step();
    return db;
}

fn rowOf(st: *sq.Stmt, a: std.mem.Allocator) sq.Err!Row {
    const sname = try st.col(a, 3);
    return .{
        .id = st.colInt(0),
        .name = try st.col(a, 1),
        .pkey = try st.col(a, 2),
        .state = stateOf(sname),
        .video_id = try st.col(a, 4),
        .post_id = try st.col(a, 5),
        .url = try st.col(a, 6),
        .attempts = st.colInt(7),
        .created = st.colInt(8),
        .updated = st.colInt(9),
        .finish_at = st.colInt(10),
        .note = try st.col(a, 11),
        .upload_token = try st.col(a, 12),
        .instr = try st.col(a, 13),
        .parts = try st.col(a, 14),
        .phase = try st.col(a, 15),
        .expires_at = st.colInt(16),
    };
}
const cols = "id,name,pkey,state,video_id,post_id,url,attempts,created,updated,finish_at,note,upload_token,instr,parts,phase,expires_at";

pub fn byPkey(db: *sq.Db, a: std.mem.Allocator, pkey: []const u8) Err!?Row {
    var st = try db.prepare("SELECT " ++ cols ++ " FROM send WHERE pkey=?1");
    defer st.finalize();
    try st.text(1, pkey);
    if (!try st.step()) return null;
    return try rowOf(&st, a);
}
pub fn byName(db: *sq.Db, a: std.mem.Allocator, name: []const u8) Err!?Row {
    var st = try db.prepare("SELECT " ++ cols ++ " FROM send WHERE name=?1 ORDER BY id DESC");
    defer st.finalize();
    try st.text(1, name);
    if (!try st.step()) return null;
    return try rowOf(&st, a);
}
pub fn all(db: *sq.Db, a: std.mem.Allocator) Err![]Row {
    var st = try db.prepare("SELECT " ++ cols ++ " FROM send ORDER BY id");
    defer st.finalize();
    var out: std.ArrayList(Row) = .empty;
    while (try st.step()) out.append(a, try rowOf(&st, a)) catch return Err.OutOfMemory;
    return out.items;
}

// new send, or a person-approved new attempt on a failed one. Same pkey in any other state = Replay (answered from the ledger).
pub fn begin(cx: *const Ctx, db: *sq.Db, a: std.mem.Allocator, name: []const u8, pkey: []const u8, video_id: []const u8, again: bool) Err!i64 {
    try kill.writeOk(cx);
    const now = cx.nowMs();
    if (try byPkey(db, a, pkey)) |old| {
        if (old.state != .failed or !again) return Err.Replay;
        var u = try db.prepare("UPDATE send SET state='sending', video_id=?2, attempts=attempts+1, updated=?3, finish_at=0, note='retry', upload_token='', instr='', parts='', phase='init', expires_at=0 WHERE id=?1");
        defer u.finalize();
        try u.int(1, old.id);
        try u.text(2, video_id);
        try u.int(3, now);
        _ = try u.step();
        return old.id;
    }
    var st = try db.prepare("INSERT INTO send(name,pkey,state,video_id,created,updated) VALUES(?1,?2,'sending',?3,?4,?4)");
    defer st.finalize();
    try st.text(1, name);
    try st.text(2, pkey);
    try st.text(3, video_id);
    try st.int(4, now);
    _ = try st.step();
    return db.lastId();
}

pub fn finishAt(cx: *const Ctx, db: *sq.Db, id: i64) Err!void {
    var st = try db.prepare("UPDATE send SET finish_at=?2, updated=?2 WHERE id=?1");
    defer st.finalize();
    try st.int(1, id);
    try st.int(2, cx.nowMs());
    _ = try st.step();
    var f = try db.prepare("INSERT INTO fin(send_id,at) VALUES(?1,?2)"); // one row per finish ever sent: the cap counts these, even after --again
    defer f.finalize();
    try f.int(1, id);
    try f.int(2, cx.nowMs());
    _ = try f.step();
}

pub fn setState(cx: *const Ctx, db: *sq.Db, id: i64, state: State, note: []const u8, post_id: []const u8, url: []const u8) Err!void {
    var st = try db.prepare("UPDATE send SET state=?2, note=?3, post_id=CASE WHEN ?4<>'' THEN ?4 ELSE post_id END, url=CASE WHEN ?5<>'' THEN ?5 ELSE url END, updated=?6 WHERE id=?1");
    defer st.finalize();
    try st.int(1, id);
    try st.text(2, stateName(state));
    var nb: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&nb);
    try st.text(3, text.safeNote(fba.allocator(), note, 400));
    try st.text(4, post_id);
    try st.text(5, url);
    try st.int(6, cx.nowMs());
    _ = try st.step();
}

// a run that died AFTER the post request was about to leave (phase creating) = unsure, never retried by itself.
// A run that died earlier left nothing public: that row stays `sending` and the next run continues the same video.
pub fn recover(cx: *const Ctx, db: *sq.Db) Err!i64 {
    var st = try db.prepare("UPDATE send SET state='unsure', note='run ended while the post was being created: run resolve', updated=?1 WHERE state='sending' AND phase='creating'");
    defer st.finalize();
    try st.int(1, cx.nowMs());
    _ = try st.step();
    return db.changes();
}

// post requests started in the rolling window: what the daily cap counts
pub fn countSince(db: *sq.Db, since_ms: i64) Err!i64 {
    var st = try db.prepare("SELECT COUNT(*) FROM fin WHERE at>=?1");
    defer st.finalize();
    try st.int(1, since_ms);
    _ = try st.step();
    return st.colInt(0);
}

pub fn lastFinish(db: *sq.Db) Err!i64 {
    var st = try db.prepare("SELECT COALESCE(MAX(at),0) FROM fin");
    defer st.finalize();
    _ = try st.step();
    return st.colInt(0);
}

pub fn count(db: *sq.Db, state: State) Err!i64 {
    var st = try db.prepare("SELECT COUNT(*) FROM send WHERE state=?1");
    defer st.finalize();
    try st.text(1, stateName(state));
    _ = try st.step();
    return st.colInt(0);
}

// ---- upload session (what a crash needs to continue the same video) ----
pub fn setSession(cx: *const Ctx, db: *sq.Db, id: i64, video: []const u8, upload_token: []const u8, instr: []const u8, expires_at: i64) Err!void {
    var st = try db.prepare("UPDATE send SET video_id=?2, upload_token=?3, instr=?4, expires_at=?5, parts='', phase='init', updated=?6 WHERE id=?1");
    defer st.finalize();
    try st.int(1, id);
    try st.text(2, video);
    try st.text(3, upload_token);
    try st.text(4, instr);
    try st.int(5, expires_at);
    try st.int(6, cx.nowMs());
    _ = try st.step();
}
pub fn setParts(cx: *const Ctx, db: *sq.Db, id: i64, parts: []const u8) Err!void {
    var st = try db.prepare("UPDATE send SET parts=?2, updated=?3 WHERE id=?1");
    defer st.finalize();
    try st.int(1, id);
    try st.text(2, parts);
    try st.int(3, cx.nowMs());
    _ = try st.step();
}
pub fn setPhase(cx: *const Ctx, db: *sq.Db, id: i64, phase: []const u8) Err!void {
    var st = try db.prepare("UPDATE send SET phase=?2, updated=?3 WHERE id=?1");
    defer st.finalize();
    try st.int(1, id);
    try st.text(2, phase);
    try st.int(3, cx.nowMs());
    _ = try st.step();
}
// a staged or interrupted row goes back to work (same video if it is still good)
pub fn resume(cx: *const Ctx, db: *sq.Db, id: i64) Err!void {
    try kill.writeOk(cx);
    var st = try db.prepare("UPDATE send SET state='sending', note='continued', updated=?2 WHERE id=?1");
    defer st.finalize();
    try st.int(1, id);
    try st.int(2, cx.nowMs());
    _ = try st.step();
}
// a new upload for the same pair (the old video is gone or expired)
pub fn newAttempt(cx: *const Ctx, db: *sq.Db, id: i64) Err!void {
    try kill.writeOk(cx);
    var st = try db.prepare("UPDATE send SET state='sending', video_id='', upload_token='', instr='', parts='', phase='init', expires_at=0, attempts=attempts+1, note='new upload', updated=?2 WHERE id=?1");
    defer st.finalize();
    try st.int(1, id);
    try st.int(2, cx.nowMs());
    _ = try st.step();
}
pub fn dbCreated(db: *sq.Db) Err!i64 {
    return metaInt(db, "db_created");
}

// ---- meta ----
pub fn metaGet(db: *sq.Db, a: std.mem.Allocator, k: []const u8) Err!?[]u8 {
    var st = try db.prepare("SELECT v FROM meta WHERE k=?1");
    defer st.finalize();
    try st.text(1, k);
    if (!try st.step()) return null;
    return try st.col(a, 0);
}
pub fn metaInt(db: *sq.Db, k: []const u8) Err!i64 {
    var buf: [64]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const v = (try metaGet(db, fba.allocator(), k)) orelse return 0; // a read error stops the run (fail closed)
    return std.fmt.parseInt(i64, v, 10) catch 0;
}
pub fn metaSet(db: *sq.Db, k: []const u8, v: []const u8) Err!void {
    var st = try db.prepare("INSERT INTO meta(k,v) VALUES(?1,?2) ON CONFLICT(k) DO UPDATE SET v=?2");
    defer st.finalize();
    try st.text(1, k);
    try st.text(2, v);
    _ = try st.step();
}
pub fn metaSetInt(db: *sq.Db, k: []const u8, v: i64) Err!void {
    var buf: [32]u8 = undefined;
    try metaSet(db, k, std.fmt.bufPrint(&buf, "{d}", .{v}) catch "0");
}

// ---- approvals (review:true pairs) ----
pub fn approval(db: *sq.Db, a: std.mem.Allocator, name: []const u8) Err![]u8 {
    var st = try db.prepare("SELECT state FROM appr WHERE name=?1");
    defer st.finalize();
    try st.text(1, name);
    if (!try st.step()) return a.dupe(u8, "") catch Err.OutOfMemory;
    return try st.col(a, 0);
}
pub fn setApproval(cx: *const Ctx, db: *sq.Db, name: []const u8, state: []const u8) Err!void {
    try kill.writeOk(cx);
    var st = try db.prepare("INSERT INTO appr(name,state,at) VALUES(?1,?2,?3) ON CONFLICT(name) DO UPDATE SET state=?2, at=?3");
    defer st.finalize();
    try st.text(1, name);
    try st.text(2, state);
    try st.int(3, cx.nowMs());
    _ = try st.step();
}

// ---- tests ----
const ctxm = @import("co-ctx.zig");

pub fn testDb(arena: std.mem.Allocator, env: *std.process.Environ.Map, tmp_sub: []const u8) !struct { cx: Ctx, db: sq.Db } {
    const home = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp_sub});
    var cx = ctxm.testCtx(arena, env, home);
    cx.cfg.data_dir = "~/d";
    cx.fake_now_ms = 1_000_000_000_000;
    const db = try open(&cx);
    return .{ .cx = cx, .db = db };
}

test "begin once, replay refused, failed needs --again, crash after the post request left -> unsure, earlier crash stays sending" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var t = try testDb(a, &env, &tmp.sub_path);
    defer t.db.close();
    const id = try begin(&t.cx, &t.db, a, "v1", "car:tpl:link-shor", "111", false);
    try std.testing.expectError(Err.Replay, begin(&t.cx, &t.db, a, "v1", "car:tpl:link-shor", "111", false));
    // died before the post request: nothing public, the row stays sending so the next run continues it
    try std.testing.expectEqual(@as(i64, 0), try recover(&t.cx, &t.db));
    var row = (try byPkey(&t.db, a, "car:tpl:link-shor")).?;
    try std.testing.expectEqual(State.sending, row.state);
    try setPhase(&t.cx, &t.db, id, "creating");
    try std.testing.expectEqual(@as(i64, 1), try recover(&t.cx, &t.db));
    row = (try byPkey(&t.db, a, "car:tpl:link-shor")).?;
    try std.testing.expectEqual(State.unsure, row.state);
    try setState(&t.cx, &t.db, id, .failed, "x", "", "");
    try std.testing.expectError(Err.Replay, begin(&t.cx, &t.db, a, "v1", "car:tpl:link-shor", "222", false));
    _ = try begin(&t.cx, &t.db, a, "v1", "car:tpl:link-shor", "222", true);
    row = (try byPkey(&t.db, a, "car:tpl:link-shor")).?;
    try std.testing.expectEqual(State.sending, row.state);
    try std.testing.expectEqual(@as(i64, 2), row.attempts);
    try std.testing.expectEqualStrings("222", row.video_id);
    try std.testing.expectEqualStrings("init", row.phase);
}

test "session, parts, phase are stored; resume and newAttempt reset the right things; db_created is set once" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var t = try testDb(a, &env, &tmp.sub_path);
    defer t.db.close();
    const created = try dbCreated(&t.db);
    try std.testing.expectEqual(t.cx.nowMs(), created);
    const id = try begin(&t.cx, &t.db, a, "v1", "k1", "", false);
    try setSession(&t.cx, &t.db, id, "urn:li:video:A", "TOK", "0,9,https://u/1", 42);
    try setParts(&t.cx, &t.db, id, "etag1\n");
    try setPhase(&t.cx, &t.db, id, "parts");
    var r = (try byPkey(&t.db, a, "k1")).?;
    try std.testing.expectEqualStrings("urn:li:video:A", r.video_id);
    try std.testing.expectEqualStrings("TOK", r.upload_token);
    try std.testing.expectEqualStrings("etag1\n", r.parts);
    try std.testing.expectEqualStrings("parts", r.phase);
    try std.testing.expectEqual(@as(i64, 42), r.expires_at);
    try setState(&t.cx, &t.db, id, .staged, "ready", "", "");
    try resume(&t.cx, &t.db, id);
    r = (try byPkey(&t.db, a, "k1")).?;
    try std.testing.expectEqual(State.sending, r.state);
    try std.testing.expectEqualStrings("urn:li:video:A", r.video_id);
    try newAttempt(&t.cx, &t.db, id);
    r = (try byPkey(&t.db, a, "k1")).?;
    try std.testing.expectEqualStrings("", r.video_id);
    try std.testing.expectEqualStrings("", r.parts);
    try std.testing.expectEqual(@as(i64, 2), r.attempts);
    // reopening keeps the first creation time
    t.cx.fake_now_ms += 5000;
    var again_db = try open(&t.cx);
    defer again_db.close();
    try std.testing.expectEqual(created, try dbCreated(&again_db));
}

test "rolling window count, meta, approval, kill blocks writes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var t = try testDb(a, &env, &tmp.sub_path);
    defer t.db.close();
    const id = try begin(&t.cx, &t.db, a, "v1", "k1", "1", false);
    try finishAt(&t.cx, &t.db, id);
    try std.testing.expectEqual(@as(i64, 1), try countSince(&t.db, t.cx.nowMs() - 1000));
    try std.testing.expectEqual(@as(i64, 0), try countSince(&t.db, t.cx.nowMs() + 1000));
    try metaSetInt(&t.db, "x", 42);
    try std.testing.expectEqual(@as(i64, 42), try metaInt(&t.db, "x"));
    try std.testing.expectEqual(@as(i64, 0), try metaInt(&t.db, "nope"));
    try setApproval(&t.cx, &t.db, "v1", "approved");
    try std.testing.expectEqualStrings("approved", try approval(&t.db, a, "v1"));
    try kill.setKill(&t.cx, true);
    try std.testing.expectError(kill.Err.Killed, begin(&t.cx, &t.db, a, "v2", "k2", "2", false));
    try std.testing.expectError(kill.Err.Killed, setApproval(&t.cx, &t.db, "v2", "approved"));
}
