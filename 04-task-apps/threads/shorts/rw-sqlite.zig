// The ONLY file that touches the SQLite C API (written exception to std-only, see .10-docs/10-RULE.md). Thin wrapper: open, exec, prepare, bind, step, read.
const std = @import("std");
pub const c = @cImport(@cInclude("sqlite3.h"));

pub const Err = error{ Open, Sql, Busy, OutOfMemory };
const TRANSIENT: c.sqlite3_destructor_type = null; // SQLITE_STATIC: every bound slice outlives its step (SQLITE_TRANSIENT does not compile on arm: alignment cast)

pub const Stmt = struct {
    s: *c.sqlite3_stmt,
    pub fn finalize(self: *Stmt) void {
        _ = c.sqlite3_finalize(self.s);
    }
    pub fn text(self: *Stmt, i: c_int, v: []const u8) Err!void {
        if (c.sqlite3_bind_text(self.s, i, v.ptr, @intCast(v.len), TRANSIENT) != c.SQLITE_OK) return Err.Sql;
    }
    pub fn int(self: *Stmt, i: c_int, v: i64) Err!void {
        if (c.sqlite3_bind_int64(self.s, i, v) != c.SQLITE_OK) return Err.Sql;
    }
    // true = a row is ready, false = done
    pub fn step(self: *Stmt) Err!bool {
        const rc = c.sqlite3_step(self.s);
        if (rc == c.SQLITE_ROW) return true;
        if (rc == c.SQLITE_DONE) return false;
        if (rc == c.SQLITE_BUSY or rc == c.SQLITE_LOCKED) return Err.Busy;
        return Err.Sql;
    }
    // column text, copied into `a` (NULL -> empty)
    pub fn col(self: *Stmt, a: std.mem.Allocator, i: c_int) Err![]u8 {
        const p = c.sqlite3_column_text(self.s, i);
        if (p == null) return a.dupe(u8, "") catch Err.OutOfMemory;
        const n: usize = @intCast(c.sqlite3_column_bytes(self.s, i));
        return a.dupe(u8, p[0..n]) catch Err.OutOfMemory;
    }
    pub fn colInt(self: *Stmt, i: c_int) i64 {
        return c.sqlite3_column_int64(self.s, i);
    }
};

pub const Db = struct {
    h: *c.sqlite3,
    pub fn open(path: []const u8, a: std.mem.Allocator) Err!Db {
        const z = a.dupeZ(u8, path) catch return Err.OutOfMemory;
        defer a.free(z);
        var h: ?*c.sqlite3 = null;
        const rc = c.sqlite3_open_v2(z.ptr, &h, c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE | c.SQLITE_OPEN_FULLMUTEX, null);
        if (rc != c.SQLITE_OK or h == null) {
            if (h) |x| _ = c.sqlite3_close(x);
            return Err.Open;
        }
        var db = Db{ .h = h.? };
        errdefer db.close();
        _ = c.sqlite3_busy_timeout(db.h, 5000);
        try db.exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA foreign_keys=ON;");
        return db;
    }
    pub fn close(self: *Db) void {
        _ = c.sqlite3_close(self.h);
    }
    pub fn exec(self: *Db, sql: [:0]const u8) Err!void {
        var msg: [*c]u8 = null;
        const rc = c.sqlite3_exec(self.h, sql.ptr, null, null, &msg);
        if (msg != null) c.sqlite3_free(msg);
        if (rc == c.SQLITE_BUSY or rc == c.SQLITE_LOCKED) return Err.Busy;
        if (rc != c.SQLITE_OK) return Err.Sql;
    }
    pub fn prepare(self: *Db, sql: [:0]const u8) Err!Stmt {
        var s: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.h, sql.ptr, -1, &s, null) != c.SQLITE_OK or s == null) return Err.Sql;
        return .{ .s = s.? };
    }
    pub fn changes(self: *Db) i64 {
        return c.sqlite3_changes(self.h);
    }
    pub fn lastId(self: *Db) i64 {
        return c.sqlite3_last_insert_rowid(self.h);
    }
};

test "open, insert, read, constraint, persists across reopen" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = std.testing.allocator;
    const p = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/t.db", .{&tmp.sub_path});
    defer a.free(p);
    {
        var db = try Db.open(p, a);
        defer db.close();
        try db.exec("CREATE TABLE t(k TEXT PRIMARY KEY, v INTEGER)");
        var st = try db.prepare("INSERT INTO t VALUES(?1,?2)");
        defer st.finalize();
        try st.text(1, "a");
        try st.int(2, 7);
        _ = try st.step();
        try std.testing.expectEqual(@as(i64, 1), db.changes());
    }
    var db = try Db.open(p, a);
    defer db.close();
    var q = try db.prepare("SELECT k, v FROM t");
    defer q.finalize();
    try std.testing.expect(try q.step());
    const k = try q.col(a, 0);
    defer a.free(k);
    try std.testing.expectEqualStrings("a", k);
    try std.testing.expectEqual(@as(i64, 7), q.colInt(1));
    var dup = try db.prepare("INSERT INTO t VALUES('a',1)");
    defer dup.finalize();
    try std.testing.expectError(Err.Sql, dup.step());
}
