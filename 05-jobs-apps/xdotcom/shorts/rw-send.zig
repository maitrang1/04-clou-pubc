// =====================================================================
// Des: The send ledger - one SQLite row per video (unique key = replay guard), the seven states, the media id and phase of the upload, the estimated cost, and a small key-value table for the breaker, the stop window and the rate headers
// Flo: open db > create tables > find/insert/update rows by key or name > count sends and spend in a rolling window > kv get/set > backup copy
// Cre: 2026-11-16                          - | Mod: 2026-11-16
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: Ctx, row fields, pkey, name
// Out: Row (arena-owned strings) | error; the file ledger.db in the data folder
// Run: not run directly - imported by rw-caps and every command
// =====================================================================
const std = @import("std");
const sql = @import("rw-sqlite.zig");
const ctx_mod = @import("co-ctx.zig");
const util = @import("co-util.zig");

pub const State = enum {
    ready,
    held,
    sending,
    staged,
    posted,
    failed,
    unsure,

    pub fn name(self: State) []const u8 {
        return switch (self) {
            .ready => "ready",
            .held => "held",
            .sending => "sending",
            .staged => "staged",
            .posted => "posted",
            .failed => "failed",
            .unsure => "unsure",
        };
    }
    pub fn parse(s: []const u8) ?State {
        inline for (@typeInfo(State).@"enum".fields) |f| if (std.mem.eql(u8, s, f.name)) return @field(State, f.name);
        return null;
    }
};

pub const Row = struct {
    id: i64,
    name: []const u8,
    pkey: []const u8,
    state: State,
    post_id: []const u8,
    media_id: []const u8,
    url: []const u8,
    bytes: i64,
    created: i64,
    updated: i64,
    started: i64,
    attempt: i64,
    phase: i64, // 0 nothing · 1 media id known · 2 chunks sent · 3 finalized · 4 create-post about to leave (a crash after this = unsure)
    cost_e6: i64, // estimated cost in millionths of a dollar
    text: []const u8,
    note: []const u8,
};

pub const Err = error{ Ledger, Exists, NoDir } || sql.Err;

const schema =
    \\CREATE TABLE IF NOT EXISTS send(
    \\ id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, pkey TEXT NOT NULL UNIQUE, state TEXT NOT NULL,
    \\ post_id TEXT NOT NULL DEFAULT '', media_id TEXT NOT NULL DEFAULT '', url TEXT NOT NULL DEFAULT '',
    \\ bytes INTEGER NOT NULL DEFAULT 0, created INTEGER NOT NULL, updated INTEGER NOT NULL, started INTEGER NOT NULL DEFAULT 0,
    \\ attempt INTEGER NOT NULL DEFAULT 0, phase INTEGER NOT NULL DEFAULT 0, cost_e6 INTEGER NOT NULL DEFAULT 0,
    \\ text TEXT NOT NULL DEFAULT '', note TEXT NOT NULL DEFAULT '');
    \\CREATE TABLE IF NOT EXISTS kv(k TEXT PRIMARY KEY, v TEXT NOT NULL);
;

const cols = "id,name,pkey,state,post_id,media_id,url,bytes,created,updated,started,attempt,phase,cost_e6,text,note";

pub const Ledger = struct {
    db: sql.Db,

    pub fn open(cx: *const ctx_mod.Ctx, a: std.mem.Allocator) Err!Ledger {
        util.mkdirPrivate(cx.io, cx.data_dir) catch return Err.NoDir;
        const p = cx.dataPath(a, cx.cfg.db_file) catch return Err.OutOfMemory;
        const l = try openPath(p);
        util.restrict(cx.io, p, 0o600); // the ledger holds post texts and media ids
        return l;
    }

    pub fn openPath(p: []const u8) Err!Ledger {
        const db = try sql.Db.open(p);
        errdefer db.close();
        // two statements: run each on its own
        var it = std.mem.splitScalar(u8, schema, ';');
        while (it.next()) |part| {
            const t = std.mem.trim(u8, part, " \n");
            if (t.len == 0) continue;
            db.exec(t) catch return Err.Ledger;
        }
        return .{ .db = db };
    }

    pub fn close(self: Ledger) void {
        self.db.close();
    }

    fn readRow(a: std.mem.Allocator, st: *sql.Stmt) Err!Row {
        return .{
            .id = st.colInt(0),
            .name = try a.dupe(u8, st.colText(1)),
            .pkey = try a.dupe(u8, st.colText(2)),
            .state = State.parse(st.colText(3)) orelse return Err.Ledger,
            .post_id = try a.dupe(u8, st.colText(4)),
            .media_id = try a.dupe(u8, st.colText(5)),
            .url = try a.dupe(u8, st.colText(6)),
            .bytes = st.colInt(7),
            .created = st.colInt(8),
            .updated = st.colInt(9),
            .started = st.colInt(10),
            .attempt = st.colInt(11),
            .phase = st.colInt(12),
            .cost_e6 = st.colInt(13),
            .text = try a.dupe(u8, st.colText(14)),
            .note = try a.dupe(u8, st.colText(15)),
        };
    }

    pub fn find(self: Ledger, a: std.mem.Allocator, pkey: []const u8) Err!?Row {
        var st = try self.db.prepare("SELECT " ++ cols ++ " FROM send WHERE pkey=?1;");
        defer st.finalize();
        try st.bindText(1, pkey);
        if (!(try st.step())) return null;
        return try readRow(a, &st);
    }

    // newest row with this file name
    pub fn findName(self: Ledger, a: std.mem.Allocator, name: []const u8) Err!?Row {
        var st = try self.db.prepare("SELECT " ++ cols ++ " FROM send WHERE name=?1 ORDER BY id DESC LIMIT 1;");
        defer st.finalize();
        try st.bindText(1, name);
        if (!(try st.step())) return null;
        return try readRow(a, &st);
    }

    // false = the key already exists (replay)
    pub fn insertNew(self: Ledger, name: []const u8, pkey: []const u8, state: State, text: []const u8, now: i64) Err!bool {
        var st = try self.db.prepare("INSERT OR IGNORE INTO send(name,pkey,state,text,created,updated) VALUES(?1,?2,?3,?4,?5,?5);");
        defer st.finalize();
        try st.bindText(1, name);
        try st.bindText(2, pkey);
        try st.bindText(3, state.name());
        try st.bindText(4, text);
        try st.bindInt(5, now);
        _ = try st.step();
        return self.db.changes() == 1;
    }

    pub fn setState(self: Ledger, pkey: []const u8, state: State, note: []const u8, now: i64) Err!void {
        var st = try self.db.prepare("UPDATE send SET state=?2, note=?3, updated=?4 WHERE pkey=?1;");
        defer st.finalize();
        try st.bindText(1, pkey);
        try st.bindText(2, state.name());
        try st.bindText(3, note);
        try st.bindInt(4, now);
        _ = try st.step();
        if (self.db.changes() != 1) return Err.Ledger;
    }

    // the row goes to `sending`: counted against the cap and the budget window from this moment; the text is kept for resolve
    pub fn begin(self: Ledger, pkey: []const u8, now: i64, bytes: i64, text: []const u8) Err!void {
        var st = try self.db.prepare("UPDATE send SET state='sending', started=?2, bytes=?3, text=?4, phase=0, media_id='', updated=?2 WHERE pkey=?1;");
        defer st.finalize();
        try st.bindText(1, pkey);
        try st.bindInt(2, now);
        try st.bindInt(3, bytes);
        try st.bindText(4, text);
        _ = try st.step();
        if (self.db.changes() != 1) return Err.Ledger;
    }

    // nothing public happened: back to ready, no longer counts against the cap or the gap; bump = a failed try is counted (attempt+1)
    pub fn requeue(self: Ledger, pkey: []const u8, note: []const u8, now: i64, bump: bool) Err!void {
        var st = try self.db.prepare("UPDATE send SET state='ready', started=0, media_id='', phase=0, attempt=attempt+?4, note=?2, updated=?3 WHERE pkey=?1;");
        defer st.finalize();
        try st.bindText(1, pkey);
        try st.bindText(2, note);
        try st.bindInt(3, now);
        try st.bindInt(4, if (bump) 1 else 0);
        _ = try st.step();
        if (self.db.changes() != 1) return Err.Ledger;
    }

    // the media id came back from initialize: written at once so a crash can be recovered
    pub fn setMedia(self: Ledger, pkey: []const u8, media_id: []const u8, now: i64) Err!void {
        var st = try self.db.prepare("UPDATE send SET media_id=?2, phase=1, updated=?3 WHERE pkey=?1;");
        defer st.finalize();
        try st.bindText(1, pkey);
        try st.bindText(2, media_id);
        try st.bindInt(3, now);
        _ = try st.step();
        if (self.db.changes() != 1) return Err.Ledger;
    }

    pub fn setPhase(self: Ledger, pkey: []const u8, phase: i64, now: i64) Err!void {
        var st = try self.db.prepare("UPDATE send SET phase=?2, updated=?3 WHERE pkey=?1;");
        defer st.finalize();
        try st.bindText(1, pkey);
        try st.bindInt(2, phase);
        try st.bindInt(3, now);
        _ = try st.step();
        if (self.db.changes() != 1) return Err.Ledger;
    }

    pub fn setCost(self: Ledger, pkey: []const u8, cost_e6: i64) Err!void {
        var st = try self.db.prepare("UPDATE send SET cost_e6=?2 WHERE pkey=?1;");
        defer st.finalize();
        try st.bindText(1, pkey);
        try st.bindInt(2, cost_e6);
        _ = try st.step();
        if (self.db.changes() != 1) return Err.Ledger;
    }

    pub fn setPosted(self: Ledger, pkey: []const u8, post_id: []const u8, url: []const u8, note: []const u8, now: i64) Err!void {
        var st = try self.db.prepare("UPDATE send SET state='posted', post_id=?2, url=?3, note=?4, updated=?5 WHERE pkey=?1;");
        defer st.finalize();
        try st.bindText(1, pkey);
        try st.bindText(2, post_id);
        try st.bindText(3, url);
        try st.bindText(4, note);
        try st.bindInt(5, now);
        _ = try st.step();
        if (self.db.changes() != 1) return Err.Ledger;
    }

    pub fn listState(self: Ledger, a: std.mem.Allocator, state: State) Err![]Row {
        var st = try self.db.prepare("SELECT " ++ cols ++ " FROM send WHERE state=?1 ORDER BY id;");
        defer st.finalize();
        try st.bindText(1, state.name());
        var out: std.ArrayList(Row) = .empty;
        while (try st.step()) try out.append(a, try readRow(a, &st));
        return out.toOwnedSlice(a);
    }

    pub fn counts(self: Ledger) Err![7]u32 {
        var out: [7]u32 = @splat(0);
        var st = try self.db.prepare("SELECT state, COUNT(*) FROM send GROUP BY state;");
        defer st.finalize();
        while (try st.step()) {
            if (State.parse(st.colText(0))) |s| out[@intFromEnum(s)] = @intCast(st.colInt(1));
        }
        return out;
    }

    // sends that began at or after `since_ms` (rolling cap counter)
    pub fn countSince(self: Ledger, since_ms: i64) Err!u32 {
        var st = try self.db.prepare("SELECT COUNT(*) FROM send WHERE started>0 AND started>=?1;");
        defer st.finalize();
        try st.bindInt(1, since_ms);
        if (!(try st.step())) return 0;
        return @intCast(st.colInt(0));
    }

    // estimated spend (millionths of a dollar) of sends that began at or after `since_ms`
    pub fn spendSince(self: Ledger, since_ms: i64) Err!i64 {
        var st = try self.db.prepare("SELECT COALESCE(SUM(cost_e6),0) FROM send WHERE started>0 AND started>=?1;");
        defer st.finalize();
        try st.bindInt(1, since_ms);
        if (!(try st.step())) return 0;
        return st.colInt(0);
    }

    pub fn lastStarted(self: Ledger) Err!i64 {
        var st = try self.db.prepare("SELECT COALESCE(MAX(started),0) FROM send;");
        defer st.finalize();
        if (!(try st.step())) return 0;
        return st.colInt(0);
    }

    pub fn kvGet(self: Ledger, a: std.mem.Allocator, k: []const u8) Err!?[]const u8 {
        var st = try self.db.prepare("SELECT v FROM kv WHERE k=?1;");
        defer st.finalize();
        try st.bindText(1, k);
        if (!(try st.step())) return null;
        return try a.dupe(u8, st.colText(0));
    }

    pub fn kvInt(self: Ledger, k: []const u8) Err!i64 {
        var buf: [64]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&buf);
        const v = (try self.kvGet(fba.allocator(), k)) orelse return 0;
        return std.fmt.parseInt(i64, v, 10) catch 0;
    }

    pub fn kvSet(self: Ledger, k: []const u8, v: []const u8) Err!void {
        var st = try self.db.prepare("INSERT INTO kv(k,v) VALUES(?1,?2) ON CONFLICT(k) DO UPDATE SET v=?2;");
        defer st.finalize();
        try st.bindText(1, k);
        try st.bindText(2, v);
        _ = try st.step();
    }

    pub fn kvSetInt(self: Ledger, k: []const u8, v: i64) Err!void {
        var b: [24]u8 = undefined;
        try self.kvSet(k, std.fmt.bufPrint(&b, "{d}", .{v}) catch return Err.Ledger);
    }

    // consistent copy through SQLite itself; refuses to overwrite an existing file
    pub fn backup(self: Ledger, to: []const u8, io: std.Io) Err!void {
        if (util.exists(io, to)) return Err.Exists;
        var st = try self.db.prepare("VACUUM INTO ?1;");
        defer st.finalize();
        try st.bindText(1, to);
        _ = try st.step();
        util.restrict(io, to, 0o600);
    }
};

fn tmpLedger(a: std.mem.Allocator, tmp: *std.testing.TmpDir) !Ledger {
    const p = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/l.db", .{&tmp.sub_path});
    return Ledger.openPath(p);
}

test "state names round trip" {
    inline for (@typeInfo(State).@"enum".fields) |f| try std.testing.expect(State.parse(f.name).? == @field(State, f.name));
    try std.testing.expect(State.parse("nope") == null);
}

test "same key twice is a replay; states move; rolling counters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const l = try tmpLedger(a, &tmp);
    defer l.close();
    try std.testing.expect(try l.insertNew("a", "car1:t1:xdot-shor", .sending, "T", 1000));
    try std.testing.expect(!(try l.insertNew("a", "car1:t1:xdot-shor", .sending, "T", 2000)));
    try l.begin("car1:t1:xdot-shor", 1000, 555, "hello");
    try l.setMedia("car1:t1:xdot-shor", "m1", 1001);
    const r = (try l.find(a, "car1:t1:xdot-shor")).?;
    try std.testing.expect(r.state == .sending and r.bytes == 555 and r.phase == 1);
    try std.testing.expectEqualStrings("m1", r.media_id);
    try std.testing.expectEqualStrings("hello", r.text);
    try std.testing.expectEqual(@as(u32, 1), try l.countSince(500));
    try std.testing.expectEqual(@as(u32, 0), try l.countSince(1001));
    try std.testing.expectEqual(@as(i64, 1000), try l.lastStarted());
    try l.setPhase("car1:t1:xdot-shor", 3, 1002);
    try l.setCost("car1:t1:xdot-shor", 15_000);
    try std.testing.expectEqual(@as(i64, 15_000), try l.spendSince(0));
    try std.testing.expectEqual(@as(i64, 0), try l.spendSince(2000));
    // a requeue forgets the send: it no longer counts, the failed try is counted
    try l.requeue("car1:t1:xdot-shor", "net down", 1200, true);
    try std.testing.expectEqual(@as(u32, 0), try l.countSince(0));
    try std.testing.expectEqual(@as(i64, 0), try l.lastStarted());
    const q = (try l.find(a, "car1:t1:xdot-shor")).?;
    try std.testing.expect(q.state == .ready and q.attempt == 1 and q.media_id.len == 0 and q.phase == 0);
    try l.begin("car1:t1:xdot-shor", 1300, 555, "hello");
    try l.setPosted("car1:t1:xdot-shor", "p1", "https://x.com/i/web/status/p1", "", 1500);
    try std.testing.expect((try l.findName(a, "a")).?.state == .posted);
    try std.testing.expect(try l.insertNew("b", "k2", .held, "", 1700));
    try std.testing.expect(try l.insertNew("c", "k3", .staged, "", 1800));
    const c = try l.counts();
    try std.testing.expectEqual(@as(u32, 1), c[@intFromEnum(State.posted)]);
    try std.testing.expectEqual(@as(u32, 1), c[@intFromEnum(State.held)]);
    try std.testing.expectEqual(@as(u32, 1), c[@intFromEnum(State.staged)]);
    try std.testing.expectEqual(@as(usize, 1), (try l.listState(a, .held)).len);
    try std.testing.expectError(Err.Ledger, l.setState("missing", .failed, "", 1));
}

test "kv, reopen keeps data, backup copies and never overwrites" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        const l = try tmpLedger(a, &tmp);
        defer l.close();
        try l.kvSetInt("fails", 2);
        try l.kvSet("note", "x");
        try l.kvSetInt("fails", 3);
        try std.testing.expect(try l.insertNew("a", "k", .ready, "", 1));
    }
    const l = try tmpLedger(a, &tmp);
    defer l.close();
    try std.testing.expectEqual(@as(i64, 3), try l.kvInt("fails"));
    try std.testing.expectEqual(@as(i64, 0), try l.kvInt("none"));
    try std.testing.expect((try l.find(a, "k")) != null);
    const bp = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/b.db", .{&tmp.sub_path});
    try l.backup(bp, std.testing.io);
    try std.testing.expectError(Err.Exists, l.backup(bp, std.testing.io));
    const l2 = try Ledger.openPath(bp);
    defer l2.close();
    try std.testing.expect((try l2.find(a, "k")) != null);
}
// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
