// Open the ledger only when it already exists (read-only commands must not create files).
const std = @import("std");
const Ctx = @import("co-ctx.zig").Ctx;
const send = @import("rw-send.zig");
const sq = @import("rw-sqlite.zig");
const util = @import("co-util.zig");

pub fn existing(cx: *const Ctx) ?sq.Db {
    const p = send.dbPath(cx, cx.gpa) catch return null;
    defer cx.gpa.free(p);
    if (!util.exists(cx.io, p)) return null;
    return send.open(cx) catch null;
}
