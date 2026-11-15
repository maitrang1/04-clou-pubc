// The ledger (SQLite): one row per pair, pkey UNIQUE = once-only. States: sending (before the publish request: reversible) -> staged | posted | failed | unsure.
// `pub` rows count publish requests that left (the cap counts these, even after a retry). Plus meta (breaker, gap, blocks, token) and approvals.
const std = @import("std");
const sq = @import("rw-sqlite.zig");
const Ctx = @import("co-ctx.zig").Ctx;
const kill = @import("co-kill.zig");
const util = @import("co-util.zig");
const text = @import("rw-text.zig");

pub const State = enum { sending, staged, posted, failed, unsure };
pub const Row = struct {
    id: i64,
    name: []const u8,
    pkey: []const u8,
    state: State,
    attempt: i64,
    tries: i64,
    host_file: []const u8,
    container_id: []const u8,
    media_id: []const u8,
    url: []const u8,
    text_hash: []const u8,
    created: i64,
    updated: i64,
    pub_at: i64,
    note: []const u8,
};
pub const Err = sq.Err || kill.Err || error{ Replay, BadState, NoDataDir };

const schema =
    \\CREATE TABLE IF NOT EXISTS send(
    \\ id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, pkey TEXT NOT NULL UNIQUE, state TEXT NOT NULL,
    \\ attempt INTEGER NOT NULL DEFAULT 1, tries INTEGER NOT NULL DEFAULT 0,
    \\ host_file TEXT NOT NULL DEFAULT '', container_id TEXT NOT NULL DEFAULT '', media_id TEXT NOT NULL DEFAULT '',
    \\ url TEXT NOT NULL DEFAULT '', text_hash TEXT NOT NULL DEFAULT '', created INTEGER NOT NULL, updated INTEGER NOT NULL,
    \\ pub_at INTEGER NOT NULL DEFAULT 0, note TEXT NOT NULL DEFAULT '');
    \\CREATE TABLE IF NOT EXISTS pub(id INTEGER PRIMARY KEY AUTOINCREMENT, send_id INTEGER NOT NULL, at INTEGER NOT NULL);
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
    var uv0 = try db.prepare("PRAGMA user_version");
    _ = try uv0.step();
    const had = uv0.colInt(0);
    uv0.finalize();
    if (had > 1) return Err.BadState; // a newer app wrote this ledger: do not guess
    try db.exec(schema);
    return db;
}

const cols = "id,name,pkey,state,attempt,tries,host_file,container_id,media_id,url,text_hash,created,updated,pub_at,note";

fn rowOf(st: *sq.Stmt, a: std.mem.Allocator) sq.Err!Row {
    const sname = try st.col(a, 3);
    return .{
        .id = st.colInt(0),
        .name = try st.col(a, 1),
        .pkey = try st.col(a, 2),
        .state = stateOf(sname),
        .attempt = st.colInt(4),
        .tries = st.colInt(5),
        .host_file = try st.col(a, 6),
        .container_id = try st.col(a, 7),
        .media_id = try st.col(a, 8),
        .url = try st.col(a, 9),
        .text_hash = try st.col(a, 10),
        .created = st.colInt(11),
        .updated = st.colInt(12),
        .pub_at = st.colInt(13),
        .note = try st.col(a, 14),
    };
}

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

// a new send. The same pkey in any state = Replay (answered from the ledger).
pub fn begin(cx: *const Ctx, db: *sq.Db, a: std.mem.Allocator, name: []const u8, pkey: []const u8, text_hash: []const u8) Err!i64 {
    try kill.writeOk(cx);
    if (try byPkey(db, a, pkey)) |_| return Err.Replay;
    const now = cx.nowMs();
    var st = try db.prepare("INSERT INTO send(name,pkey,state,text_hash,created,updated) VALUES(?1,?2,'sending',?3,?4,?4)");
    defer st.finalize();
    try st.text(1, name);
    try st.text(2, pkey);
    try st.text(3, text_hash);
    try st.int(4, now);
    _ = try st.step();
    return db.lastId();
}

// a new attempt on an existing row: nothing public exists (failed before publish, or a person retries). `person` resets the auto-try counter.
pub fn reuse(cx: *const Ctx, db: *sq.Db, id: i64, person: bool, note: []const u8) Err!void {
    try kill.writeOk(cx);
    var st = try db.prepare("UPDATE send SET state='sending', attempt=attempt+1, tries=CASE WHEN ?2=1 THEN 0 ELSE tries+1 END, host_file='', container_id='', updated=?3, note=?4 WHERE id=?1");
    defer st.finalize();
    try st.int(1, id);
    try st.int(2, if (person) 1 else 0);
    try st.int(3, cx.nowMs());
    var nb: [512]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&nb);
    try st.text(4, text.safeNote(fba.allocator(), note, 200));
    _ = try st.step();
}

fn setStr(db: *sq.Db, comptime col: []const u8, id: i64, v: []const u8, now: i64) Err!void {
    var st = try db.prepare("UPDATE send SET " ++ col ++ "=?2, updated=?3 WHERE id=?1");
    defer st.finalize();
    try st.int(1, id);
    try st.text(2, v);
    try st.int(3, now);
    _ = try st.step();
}
pub fn setHost(cx: *const Ctx, db: *sq.Db, id: i64, file: []const u8) Err!void {
    try setStr(db, "host_file", id, file, cx.nowMs());
}
pub fn setContainer(cx: *const Ctx, db: *sq.Db, id: i64, container: []const u8) Err!void {
    try setStr(db, "container_id", id, container, cx.nowMs());
}

// the publish request is about to leave: pub_at is written first so the cap counts it even if the process dies right here
pub fn markPub(cx: *const Ctx, db: *sq.Db, id: i64) Err!void {
    var st = try db.prepare("UPDATE send SET pub_at=?2, updated=?2 WHERE id=?1");
    defer st.finalize();
    try st.int(1, id);
    try st.int(2, cx.nowMs());
    _ = try st.step();
    var f = try db.prepare("INSERT INTO pub(send_id,at) VALUES(?1,?2)"); // one row per publish request ever sent
    defer f.finalize();
    try f.int(1, id);
    try f.int(2, cx.nowMs());
    _ = try f.step();
}

// the request provably never left (connect failed): the row is pre-publish again. The `pub` row stays (the cap stays conservative).
pub fn clearPub(db: *sq.Db, id: i64) Err!void {
    var st = try db.prepare("UPDATE send SET pub_at=0 WHERE id=?1");
    defer st.finalize();
    try st.int(1, id);
    _ = try st.step();
}

pub fn setState(cx: *const Ctx, db: *sq.Db, id: i64, state: State, note: []const u8, media_id: []const u8, url: []const u8) Err!void {
    var st = try db.prepare("UPDATE send SET state=?2, note=?3, media_id=CASE WHEN ?4<>'' THEN ?4 ELSE media_id END, url=CASE WHEN ?5<>'' THEN ?5 ELSE url END, updated=?6 WHERE id=?1");
    defer st.finalize();
    try st.int(1, id);
    try st.text(2, stateName(state));
    var nb: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&nb);
    try st.text(3, text.safeNote(fba.allocator(), note, 400));
    try st.text(4, media_id);
    try st.text(5, url);
    try st.int(6, cx.nowMs());
    _ = try st.step();
}

// a run that died AFTER the publish request left (pub_at > 0) left `sending` rows: they become unsure (never retried by themselves).
// Rows that died before it stay `sending`: nothing public exists, the next run continues them.
pub fn recover(cx: *const Ctx, db: *sq.Db) Err!i64 {
    var st = try db.prepare("UPDATE send SET state='unsure', note='run ended after the publish request left: run resolve', updated=?1 WHERE state='sending' AND pub_at>0");
    defer st.finalize();
    try st.int(1, cx.nowMs());
    _ = try st.step();
    return db.changes();
}

// publish requests sent in the rolling window: what the cap counts
pub fn countSince(db: *sq.Db, since_ms: i64) Err!i64 {
    var st = try db.prepare("SELECT COUNT(*) FROM pub WHERE at>=?1");
    defer st.finalize();
    try st.int(1, since_ms);
    _ = try st.step();
    return st.colInt(0);
}

pub fn lastPub(db: *sq.Db) Err!i64 {
    var st = try db.prepare("SELECT COALESCE(MAX(at),0) FROM pub");
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

test "begin once, replay refused, pre-publish rows survive a restart, post-publish rows become unsure" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var t = try testDb(a, &env, &tmp.sub_path);
    defer t.db.close();
    const id = try begin(&t.cx, &t.db, a, "v1", "car:tpl:thre-shor", "h");
    try std.testing.expectError(Err.Replay, begin(&t.cx, &t.db, a, "v1", "car:tpl:thre-shor", "h"));
    try setContainer(&t.cx, &t.db, id, "555");
    // died before the publish request: nothing public, stays sending
    try std.testing.expectEqual(@as(i64, 0), try recover(&t.cx, &t.db));
    var row = (try byPkey(&t.db, a, "car:tpl:thre-shor")).?;
    try std.testing.expectEqual(State.sending, row.state);
    try std.testing.expectEqualStrings("555", row.container_id);
    // died after it left: unsure
    try markPub(&t.cx, &t.db, id);
    try std.testing.expectEqual(@as(i64, 1), try recover(&t.cx, &t.db));
    row = (try byPkey(&t.db, a, "car:tpl:thre-shor")).?;
    try std.testing.expectEqual(State.unsure, row.state);
    // a failed row can be reused (person) and the auto counter resets
    try setState(&t.cx, &t.db, id, .failed, "x", "", "");
    try reuse(&t.cx, &t.db, id, true, "retry");
    row = (try byPkey(&t.db, a, "car:tpl:thre-shor")).?;
    try std.testing.expectEqual(State.sending, row.state);
    try std.testing.expectEqual(@as(i64, 2), row.attempt);
    try std.testing.expectEqual(@as(i64, 0), row.tries);
    try std.testing.expectEqualStrings("", row.container_id);
    try reuse(&t.cx, &t.db, id, false, "auto");
    row = (try byPkey(&t.db, a, "car:tpl:thre-shor")).?;
    try std.testing.expectEqual(@as(i64, 1), row.tries);
}

test "rolling window count, clearPub keeps the cap, meta, approval, kill blocks writes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var t = try testDb(a, &env, &tmp.sub_path);
    defer t.db.close();
    const id = try begin(&t.cx, &t.db, a, "v1", "k1", "h");
    try markPub(&t.cx, &t.db, id);
    try clearPub(&t.db, id);
    try std.testing.expectEqual(@as(i64, 1), try countSince(&t.db, t.cx.nowMs() - 1000));
    try std.testing.expectEqual(@as(i64, 0), try countSince(&t.db, t.cx.nowMs() + 1000));
    try metaSetInt(&t.db, "x", 42);
    try std.testing.expectEqual(@as(i64, 42), try metaInt(&t.db, "x"));
    try std.testing.expectEqual(@as(i64, 0), try metaInt(&t.db, "nope"));
    try setApproval(&t.cx, &t.db, "v1", "approved");
    try std.testing.expectEqualStrings("approved", try approval(&t.db, a, "v1"));
    try kill.setKill(&t.cx, true);
    try std.testing.expectError(kill.Err.Killed, begin(&t.cx, &t.db, a, "v2", "k2", "h"));
    try std.testing.expectError(kill.Err.Killed, setApproval(&t.cx, &t.db, "v2", "approved"));
}

test "a ledger newer than this app is refused" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var t = try testDb(a, &env, &tmp.sub_path);
    try t.db.exec("PRAGMA user_version=9");
    t.db.close();
    try std.testing.expectError(Err.BadState, open(&t.cx));
}
