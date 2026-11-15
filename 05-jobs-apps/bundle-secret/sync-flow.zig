// =====================================================================
// Des: `sync`, `pull` and `push` between this device (near) and the vault bundle (far): never deletes, a missing file comes back, a change on one side goes to the other, a conflict is auto-merged (code, text) or the newest edit wins and the other copy goes to the trash folder
// Flo: vault clean + fetch > read far (bundle) and near (disk) and base > decide per file (a conflict: merge, else the newest edit wins) > refuse a big change > losing copies to the trash folder > far first (seal, commit, push) > then near (old copy to trash first) > update base
// Cre: 2026-11-15                          - | Mod: 2026-11-15
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: Sync (flow Env, git runner, state file), passphrase, Opts (mode, go, big, no_merge, only, base folder)
// Out: Res (counts) | SyncErro (`why` of ship-flow holds the reason)
// Run: not run directly - imported by root-main.zig
// Exe: n/a
// =====================================================================
const std = @import("std");
const conf = @import("config-load.zig");
const flow = @import("bundle-flow.zig");
const ship = @import("ship-flow.zig");
const arc = @import("bundle-archive.zig");
const pick = @import("bundle-pick.zig");
const apply = @import("bundle-apply.zig");
const box = @import("vault-box.zig");
const plan = @import("sync-plan.zig");
const sbase = @import("sync-base.zig");
const smerge = @import("sync-merge.zig");
const gm = @import("glob-match.zig");
const state = @import("sync-state.zig");
const git_run = @import("git-run.zig");

pub const SyncErro = ship.SyncErro || sbase.BaseErro || error{TooManyChanges};

pub const Opts = struct { mode: plan.Mode, go: bool, big: bool, no_merge: bool, only: ?[]const u8, base_dir: []const u8 };

pub const Res = struct { same: u32 = 0, to_near: u32 = 0, to_far: u32 = 0, merged: u32 = 0, newest: u32 = 0, behind: u32 = 0, ahead: u32 = 0, raced: u32 = 0, shipped: bool = false };

const Map = std.StringHashMapUnmanaged([]const u8);
const TimeMap = std.StringHashMapUnmanaged(i64);

// loser: the copy a conflict overwrites (kept in the trash folder) ----
const RowRec = struct { rel: []const u8, act: plan.Act, td: plan.Todo, merged: ?[]const u8 = null, loser: ?[]const u8 = null, seed: bool = false, raced: bool = false };

fn line(e: flow.Env, comptime fmt: []const u8, args: anytype) void {
    e.say(e.io, std.fmt.allocPrint(e.a, fmt, args) catch return);
}

fn lessStr(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.lessThan(u8, x, y);
}

// the newest edit wins; a tie (within sync.tie_secs) or an unknown time goes to the vault, the shared side ----
fn nearWins(cf: conf.SyncCf, near_mt: i64, far_mt: i64) bool {
    if (near_mt <= 0 or far_mt <= 0) return false;
    return near_mt - far_mt > @as(i64, cf.tie_secs);
}

fn exists(io: std.Io, path: []const u8) bool {
    _ = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch return false;
    return true;
}

// the losing copy: <repo>/<trash_dir>/<same relative path>; a name already there keeps both (_yyMMdd_HHmmss, then -2, -3 ...) ----
fn trashCopy(e: flow.Env, rel: []const u8, data: []const u8, mode: u32, stamp: []const u8) SyncErro!void {
    const a = e.a;
    const want = std.fs.path.join(a, &.{ e.repo, e.conf.sync.trash_dir, rel }) catch return error.OutOfMemory;
    const ext = std.fs.path.extension(want);
    const stem = want[0 .. want.len - ext.len];
    var path = want;
    var k: u32 = 0;
    while (exists(e.io, path)) {
        k += 1;
        if (k > 999) return error.WriteFail;
        path = (if (k == 1) std.fmt.allocPrint(a, "{s}_{s}{s}", .{ stem, stamp, ext }) else std.fmt.allocPrint(a, "{s}_{s}-{d}{s}", .{ stem, stamp, k, ext })) catch return error.OutOfMemory;
    }
    try apply.writeOwner(e.io, path, data, mode, a);
}

// the file is still what the plan saw (`expect`, null = it did not exist): someone may have saved it while the sync ran ----
fn replaceChecked(io: std.Io, a: std.mem.Allocator, path: []const u8, rel: []const u8, data: []const u8, mode: u32, batch: []const u8, expect: ?[]const u8) SyncErro!bool {
    const cwd = std.Io.Dir.cwd();
    var existing: ?[]const u8 = null;
    if (cwd.statFile(io, path, .{ .follow_symlinks = false })) |st| {
        if (st.kind != .file) return error.LinkInTheWay;
        existing = cwd.readFileAlloc(io, path, a, .limited(256 * 1024 * 1024)) catch return error.WriteFail;
    } else |_| {}
    const same = if (existing) |x| (expect != null and std.mem.eql(u8, x, expect.?)) else expect == null;
    if (!same) return false;
    if (existing) |old| {
        const kept = std.fs.path.join(a, &.{ batch, rel }) catch return error.OutOfMemory;
        try apply.writeOwner(io, kept, old, mode, a);
    }
    try apply.writeOwner(io, path, data, mode, a);
    return true;
}

// a differing near file goes to the trash batch first, then the new content is written atomically; false = it changed meanwhile and was left alone ----
fn putNear(e: flow.Env, rel: []const u8, data: []const u8, mode: u32, batch: []const u8, expect: ?[]const u8, mt: i64) SyncErro!bool {
    if (!arc.safePath(rel)) return error.UnsafePath;
    const path = std.fs.path.join(e.a, &.{ e.repo, rel }) catch return error.OutOfMemory;
    const done = try replaceChecked(e.io, e.a, path, rel, data, mode, batch, expect);
    if (done) apply.setMtime(e.io, path, mt);
    return done;
}

fn say(e: flow.Env, r: RowRec, n_has: bool, f_has: bool) void {
    const rel = r.rel;
    switch (r.td) {
        .none => {},
        .write_near => if (r.loser != null) line(e, "conflict: the vault is newer and wins, this device's copy goes to {s}/ {s}\n", .{ e.conf.sync.trash_dir, rel }) else line(e, "write near {s}{s}\n", .{ rel, if (!n_has) " (restore: missing here)" else "" }),
        .write_far => if (r.loser != null) line(e, "conflict: this device is newer and wins, the vault's copy goes to {s}/ {s}\n", .{ e.conf.sync.trash_dir, rel }) else line(e, "write far {s}{s}\n", .{ rel, if (!f_has) " (restore: missing in the vault)" else "" }),
        .resolve => line(e, "merge (both changed, auto-merged into one version) {s}\n", .{rel}),
        .skip_behind => line(e, "skip (the vault is newer, run sync or pull) {s}\n", .{rel}),
        .skip_ahead => line(e, "skip (this device is newer, run sync or push) {s}\n", .{rel}),
    }
}

pub fn run(s: ship.Sync, pass: []const u8, o: Opts) SyncErro!Res {
    const e = s.e;
    const a = e.a;
    try ship.vaultGit(s);
    _ = try ship.onlyBundle(s);
    _ = try ship.gok(s, &.{ "fetch", "-q" });
    var pos = try ship.position(s);
    if (pos.behind > 0 and pos.ahead > 0) return error.Diverged;
    if (o.go and pos.behind > 0) {
        _ = try ship.gok(s, &.{ "pull", "-q", "--ff-only" });
        pos.behind = 0;
    }

    // far: the bundle, opened with this passphrase (a wrong one stops here, nothing is written) ----
    var far: Map = .empty;
    var far_mt: TimeMap = .empty;
    var far_old: std.ArrayList([]const u8) = .empty;
    if (try ship.remoteBlob(s, pos)) |blob| {
        const plain = try box.unseal(a, e.io, pass, blob);
        for (try arc.decode(a, plain)) |it| {
            try far.put(a, it.rel, it.data);
            try far_mt.put(a, it.rel, it.mtime);
            try far_old.append(a, it.rel);
        }
    }
    // near: the files on disk that the pick rules name ----
    const got = try pick.collect(e.io, a, e.repo, e.conf.pick, flow.ownRel(a, e.repo, try flow.bundlePath(e)));
    var near: Map = .empty;
    var near_mt: TimeMap = .empty;
    for (got.items) |it| {
        try near.put(a, it.rel, it.data);
        try near_mt.put(a, it.rel, it.mtime);
    }

    var rels: std.ArrayList([]const u8) = .empty;
    for (got.items) |it| try rels.append(a, it.rel);
    var fit = far.keyIterator();
    while (fit.next()) |k| if (!near.contains(k.*)) try rels.append(a, k.*);
    std.mem.sort([]const u8, rels.items, {}, lessStr);

    var base = try sbase.load(e.io, a, o.base_dir);
    var gitm: ?git_run.Git = null;
    if (o.mode == .sync and !o.no_merge and e.conf.sync.merge_globs.len > 0) {
        const tmpd = std.fs.path.join(a, &.{ o.base_dir, "tmp" }) catch return error.OutOfMemory;
        gitm = s.git;
        gitm.?.root = tmpd;
    }

    var res: Res = .{};
    var recs: std.ArrayList(RowRec) = .empty;
    var near_w: u32 = 0;
    var far_w: u32 = 0;
    // a vault copy of unknown age (an older bundle) learns its age from the identical file here: one-time, not counted as a change ----
    var far_dirty = false;
    for (rels.items) |rel| {
        if (o.only) |pat| if (!(std.mem.eql(u8, pat, rel) or gm.glob(pat, rel))) continue;
        // a path you retired on purpose (moved or renamed): ignored on both sides, never restored, never deleted ----
        if (gm.hitAny(e.conf.sync.retired, rel)) continue;
        const n = near.get(rel);
        const f = far.get(rel);
        const seed = gm.hitAny(e.conf.pick.seed_only, rel);
        var act: plan.Act = undefined;
        if (seed) {
            act = if (n == null and f != null) .to_near else if (f == null and n != null) .to_far else .same;
        } else {
            act = plan.decide(n, f, sbase.content(&base, e.io, a, rel));
        }
        var rec: RowRec = .{ .rel = rel, .act = act, .td = plan.todo(o.mode, act), .seed = seed };
        if (rec.td == .resolve) {
            if (gitm) |g| {
                if (smerge.mergeable(e.conf.sync.merge_globs, rel)) if (sbase.content(&base, e.io, a, rel)) |b| {
                    rec.merged = smerge.tryMerge(g, rel, n.?, b, f.?);
                };
            }
            if (rec.merged == null) {
                // no clean merge: the newest edit wins, the other copy is kept in the trash folder ----
                const near_wins = nearWins(e.conf.sync, near_mt.get(rel) orelse 0, far_mt.get(rel) orelse 0);
                rec.td = if (near_wins) .write_far else .write_near;
                rec.loser = if (near_wins) f else n;
                res.newest += 1;
            }
        }
        if (o.mode != .pull and rec.td == .none and act == .same and n != null and (far_mt.get(rel) orelse 0) <= 0 and (near_mt.get(rel) orelse 0) > 0) {
            try far_mt.put(a, rel, near_mt.get(rel).?);
            far_dirty = true;
        }
        switch (rec.td) {
            .write_near => near_w += 1,
            .write_far => far_w += 1,
            .resolve => {
                near_w += 1;
                far_w += 1;
            },
            else => {},
        }
        switch (act) {
            .same => res.same += 1,
            else => {},
        }
        say(e, rec, n != null, f != null);
        switch (rec.td) {
            .write_near => res.to_near += 1,
            .write_far => res.to_far += 1,
            .resolve => res.merged += 1,
            .skip_behind => res.behind += 1,
            .skip_ahead => res.ahead += 1,
            .none => {},
        }
        try recs.append(a, rec);
    }
    if (!o.big and (near_w > e.conf.sync.big_files or far_w > e.conf.sync.big_files)) {
        const msg = std.fmt.allocPrint(a, "this would change {d} file(s) here and {d} in the vault; the limit is {d} (sync.big_files)", .{ near_w, far_w, e.conf.sync.big_files }) catch "too many changes";
        ship.why = msg;
        return error.TooManyChanges;
    }
    if (!o.go) return res;

    const stamp = apply.stampOf(a, e.now_secs) catch return error.OutOfMemory;
    const mode = conf.modeOf(e.conf.unpack.file_mode) orelse return error.WriteFail;
    // the copies a conflict overwrites go to the trash folder first: if that fails nothing is overwritten ----
    for (recs.items) |r| if (r.loser) |lb| try trashCopy(e, r.rel, lb, mode, stamp);

    // far first: if the vault push fails nothing on this device has changed ----
    if (far_w > 0 or far_dirty) {
        for (recs.items) |r| {
            const n = near.get(r.rel);
            switch (r.td) {
                .write_far => {
                    try far.put(a, r.rel, n.?);
                    try far_mt.put(a, r.rel, near_mt.get(r.rel) orelse 0);
                },
                .resolve => if (r.merged) |m| {
                    try far.put(a, r.rel, m);
                    try far_mt.put(a, r.rel, e.now_secs);
                },
                else => {},
            }
        }
        // the rail: the new bundle holds every file the old one held ----
        for (far_old.items) |k| if (!far.contains(k)) return error.GitFail;
        var out: std.ArrayList(arc.Item) = .empty;
        var kit = far.iterator();
        while (kit.next()) |kv| try out.append(a, .{ .rel = kv.key_ptr.*, .data = kv.value_ptr.*, .mtime = far_mt.get(kv.key_ptr.*) orelse 0 });
        std.mem.sort(arc.Item, out.items, {}, struct {
            fn lt(_: void, x: arc.Item, y: arc.Item) bool {
                return std.mem.lessThan(u8, x.rel, y.rel);
            }
        }.lt);
        _ = try flow.writeItems(e, pass, out.items);
        if (try ship.onlyBundle(s)) {
            _ = try ship.gok(s, &.{ "add", "--", e.conf.bundle.path });
            const made = try s.git.run(&.{ "commit", "-q", "-m", e.conf.ship.message });
            if (!made.okay()) {
                ship.why = made.why();
                ship.undo(s, false);
                return error.GitFail;
            }
            const pushed = try s.git.run(&.{ "push", "-q" });
            if (!pushed.okay()) {
                ship.why = pushed.why();
                ship.undo(s, true);
                return error.PushRejected;
            }
            res.shipped = true;
        }
        try state.write(e.io, a, s.state_file, &flow.shaHex(try flow.readBundle(e)));
    }

    // then near: the old copy of every replaced file goes to the trash first ----
    const batch = std.fs.path.join(a, &.{ e.trash, stamp }) catch return error.OutOfMemory;
    for (recs.items) |*r| {
        switch (r.td) {
            .write_near => r.raced = !(try putNear(e, r.rel, far.get(r.rel).?, mode, batch, near.get(r.rel), far_mt.get(r.rel) orelse 0)),
            .resolve => if (r.merged) |m| {
                r.raced = !(try putNear(e, r.rel, m, mode, batch, near.get(r.rel), 0));
            },
            else => {},
        }
        if (r.raced) {
            res.raced += 1;
            line(e, "left alone (changed while the sync ran) {s}\n", .{r.rel});
        }
    }

    // base: what both sides now agree on ----
    for (recs.items) |r| {
        if (r.seed or r.raced) continue;
        const n = near.get(r.rel);
        switch (r.td) {
            .none => if (r.act == .same and n != null) try sbase.set(&base, e.io, a, r.rel, n.?),
            .write_near => try sbase.set(&base, e.io, a, r.rel, far.get(r.rel).?),
            .write_far => try sbase.set(&base, e.io, a, r.rel, n.?),
            .resolve => if (r.merged) |m| try sbase.set(&base, e.io, a, r.rel, m),
            else => {},
        }
    }
    try sbase.save(&base, e.io, a);
    return res;
}
test "replaceChecked: writes when the file is what the plan saw, saves the old copy first; leaves a file someone changed meanwhile alone" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try a.dupe(u8, buf[0..try tmp.dir.realPath(io, &buf)]);
    const path = try std.fs.path.join(a, &.{ root, "d", "f.txt" });
    const batch = try std.fs.path.join(a, &.{ root, "trash" });
    try std.testing.expect(try replaceChecked(io, a, path, "d/f.txt", "NEW", 0o600, batch, null));
    try std.testing.expect(try replaceChecked(io, a, path, "d/f.txt", "NEWER", 0o600, batch, "NEW"));
    try std.testing.expectEqualStrings("NEW", try std.Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(a, &.{ batch, "d", "f.txt" }), a, .limited(100)));
    // the user saved it meanwhile: the plan saw "NEW" but the file now says "TYPED"
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "TYPED" });
    try std.testing.expect(!(try replaceChecked(io, a, path, "d/f.txt", "FAR", 0o600, batch, "NEWER")));
    try std.testing.expectEqualStrings("TYPED", try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(100)));
    // a file that appeared where the plan saw none is left alone too
    try std.testing.expect(!(try replaceChecked(io, a, path, "d/f.txt", "PAIR", 0o600, batch, null)));
}

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
