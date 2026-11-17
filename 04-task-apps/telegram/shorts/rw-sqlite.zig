// =====================================================================
// Des: Thin wrapper over the vendored SQLite C library - open, run SQL, prepared statements with bound values and typed column reads; the only C in the app
// Flo: cImport sqlite3.h > open file (busy timeout, full sync) > exec/prepare > bind > step > read columns > close
// Cre: 2026-11-15                          - | Mod: 2026-11-15
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: db file path, SQL text, bound text/int values
// Out: rows read as slices (valid until the next step) | error.Sql with the message in `lastMsg`
// Run: not run directly - imported by rw-send
// =====================================================================
const std = @import("std");
pub const c = @cImport(@cInclude("sqlite3.h"));

pub const Err = error{ Open, Sql, Busy, OutOfMemory };

pub const Db = struct {
    h: *c.sqlite3,

    pub fn open(path: []const u8) Err!Db {
        var buf: [1024]u8 = undefined;
        if (path.len >= buf.len) return Err.Open;
        @memcpy(buf[0..path.len], path);
        buf[path.len] = 0;
        var h: ?*c.sqlite3 = null;
        const rc = c.sqlite3_open_v2(@ptrCast(&buf), &h, c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE | c.SQLITE_OPEN_FULLMUTEX, null);
        if (rc != c.SQLITE_OK or h == null) {
            if (h) |x| _ = c.sqlite3_close(x);
            return Err.Open;
        }
        const self = Db{ .h = h.? };
        _ = c.sqlite3_busy_timeout(self.h, 5000);
        try self.exec("PRAGMA synchronous=FULL;");
        return self;
    }

    pub fn close(self: Db) void {
        _ = c.sqlite3_close(self.h);
    }

    pub fn exec(self: Db, sql: []const u8) Err!void {
        var st = try self.prepare(sql);
        defer st.finalize();
        _ = try st.step();
    }

    pub fn prepare(self: Db, sql: []const u8) Err!Stmt {
        var s: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.h, sql.ptr, @intCast(sql.len), &s, null);
        if (rc == c.SQLITE_BUSY) return Err.Busy;
        if (rc != c.SQLITE_OK or s == null) return Err.Sql;
        return .{ .s = s.?, .db = self.h };
    }

    pub fn changes(self: Db) i64 {
        return c.sqlite3_changes(self.h);
    }

    // sqlite's own message for the last failure
    pub fn lastMsg(self: Db) []const u8 {
        return std.mem.span(c.sqlite3_errmsg(self.h));
    }
};

pub const Stmt = struct {
    s: *c.sqlite3_stmt,
    db: *c.sqlite3,

    pub fn finalize(self: *Stmt) void {
        _ = c.sqlite3_finalize(self.s);
    }

    pub fn bindText(self: *Stmt, i: c_int, v: []const u8) Err!void {
        const transient: c.sqlite3_destructor_type = @ptrFromInt(std.math.maxInt(usize));
        if (c.sqlite3_bind_text(self.s, i, v.ptr, @intCast(v.len), transient) != c.SQLITE_OK) return Err.Sql;
    }

    pub fn bindInt(self: *Stmt, i: c_int, v: i64) Err!void {
        if (c.sqlite3_bind_int64(self.s, i, v) != c.SQLITE_OK) return Err.Sql;
    }

    // true = a row is ready, false = done
    pub fn step(self: *Stmt) Err!bool {
        const rc = c.sqlite3_step(self.s);
        if (rc == c.SQLITE_ROW) return true;
        if (rc == c.SQLITE_DONE) return false;
        if (rc == c.SQLITE_BUSY) return Err.Busy;
        return Err.Sql;
    }

    // slice valid until the next step/reset; empty for NULL
    pub fn colText(self: *Stmt, i: c_int) []const u8 {
        const p = c.sqlite3_column_text(self.s, i);
        if (p == null) return "";
        const n: usize = @intCast(c.sqlite3_column_bytes(self.s, i));
        return p[0..n];
    }

    pub fn colInt(self: *Stmt, i: c_int) i64 {
        return c.sqlite3_column_int64(self.s, i);
    }
};

test "open, create, insert with bound values (quotes are data), read back" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pb: [200]u8 = undefined;
    const p = try std.fmt.bufPrint(&pb, ".zig-cache/tmp/{s}/t.db", .{&tmp.sub_path});
    const db = try Db.open(p);
    defer db.close();
    try db.exec("CREATE TABLE t(k TEXT PRIMARY KEY, v INTEGER, n TEXT);");
    var ins = try db.prepare("INSERT INTO t(k,v,n) VALUES(?1,?2,?3);");
    try ins.bindText(1, "a'); DROP TABLE t;--");
    try ins.bindInt(2, 42);
    try ins.bindText(3, "");
    try std.testing.expect(!(try ins.step()));
    ins.finalize();
    var q = try db.prepare("SELECT k,v,n FROM t;");
    defer q.finalize();
    try std.testing.expect(try q.step());
    try std.testing.expectEqualStrings("a'); DROP TABLE t;--", q.colText(0));
    try std.testing.expectEqual(@as(i64, 42), q.colInt(1));
    try std.testing.expectEqualStrings("", q.colText(2));
    try std.testing.expect(!(try q.step()));
    // a UNIQUE violation is an error, not a crash
    var dup = try db.prepare("INSERT INTO t(k,v,n) VALUES('a''); DROP TABLE t;--',1,'');");
    defer dup.finalize();
    try std.testing.expectError(Err.Sql, dup.step());
    try std.testing.expectError(Err.Sql, db.exec("NOT SQL"));
}
// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
