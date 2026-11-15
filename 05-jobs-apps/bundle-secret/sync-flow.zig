// =====================================================================
// Des: `sync`, `pull` and `push` between this device (near) and the vault bundle (far): never deletes, a missing file comes back, a change on one side goes to the other, a conflict is auto-merged (code, text) or both copies are kept
// Flo: vault clean + fetch > read far (bundle) and near (disk) and base > decide per file > refuse a big change > far first (seal, commit, push) > then near (old copy to trash first) > update base
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

pub const SyncErro = ship.SyncErro || sbase.BaseErro || error{TooManyChanges};

pub const Opts = struct { mode: plan.Mode, go: bool, big: bool, no_merge: bool, only: ?[]const u8, base_dir: []const u8 };

pub const Res = struct { same: u32 = 0, to_near: u32 = 0, to_far: u32 = 0, merged: u32 = 0, paired: u32 = 0, still: u32 = 0, behind: u32 = 0, ahead: u32 = 0, shipped: bool = false };

const Map = std.StringHashMapUnmanaged([]const u8);

const RowRec = struct { rel: []const u8, act: plan.Act, td: plan.Todo, merged: ?[]const u8 = null, still: bool = false, seed: bool = false };

fn line(e: flow.Env, comptime fmt: []const u8, args: anytype) void {
    e.say(e.io, std.fmt.allocPrint(e.a, fmt, args) catch return);
}

fn lessStr(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.lessThan(u8, x, y);
}

// name.ext -> name.conflict-<side>-<stamp>.ext ----
pub fn pairName(a: std.mem.Allocator, rel: []const u8, side: []const u8, stamp: []const u8) ![]u8 {
    const ext = std.fs.path.extension(rel);
    return std.fmt.allocPrint(a, "{s}.conflict-{s}-{s}{s}", .{ rel[0 .. rel.len - ext.len], side, stamp, ext });
}

// a differing near file goes to the trash batch first, then the new content is written atomically; a link or folder in the way stops it ----
fn putNear(e: flow.Env, rel: []const u8, data: []const u8, mode: u32, batch: []const u8) SyncErro!void {
    if (!arc.safePath(rel)) return error.UnsafePath;
    const cwd = std.Io.Dir.cwd();
    const path = std.fs.path.join(e.a, &.{ e.repo, rel }) catch return error.OutOfMemory;
    if (cwd.statFile(e.io, path, .{ .follow_symlinks = false })) |st| {
        if (st.kind != .file) return error.LinkInTheWay;
        const old = cwd.readFileAlloc(e.io, path, e.a, .limited(256 * 1024 * 1024)) catch return error.WriteFail;
        const kept = std.fs.path.join(e.a, &.{ batch, rel }) catch return error.OutOfMemory;
        try apply.writeOwner(e.io, kept, old, mode, e.a);
    } else |_| {}
    try apply.writeOwner(e.io, path, data, mode, e.a);
}

fn say(e: flow.Env, r: RowRec, n_has: bool, f_has: bool) void {
    if (r.td == .none and !r.still) return;
    const rel = r.rel;
    if (r.still) return line(e, "conflict (still unresolved, both copies kept) {s}\n", .{rel});
    switch (r.td) {
        .none => {},
        .write_near => line(e, "write near {s}{s}\n", .{ rel, if (!n_has) " (restore: missing here)" else "" }),
        .write_far => line(e, "write far {s}{s}\n", .{ rel, if (!f_has) " (restore: missing in the vault)" else "" }),
        .merge_or_pair => if (r.merged != null) line(e, "merge (both changed, auto-merged into one version) {s}\n", .{rel}) else line(e, "conflict (both changed, nobody wins, both copies kept) {s}\n", .{rel}),
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
    var far_old: std.ArrayList([]const u8) = .empty;
    if (try ship.remoteBlob(s, pos)) |blob| {
        const plain = try box.unseal(a, e.io, pass, blob);
        for (try arc.decode(a, plain)) |it| {
            try far.put(a, it.rel, it.data);
            try far_old.append(a, it.rel);
        }
    }
    // near: the files on disk that the pick rules name ----
    const got = try pick.collect(e.io, a, e.repo, e.conf.pick, flow.ownRel(a, e.repo, try flow.bundlePath(e)));
    var near: Map = .empty;
    for (got.items) |it| try near.put(a, it.rel, it.data);

    var rels: std.ArrayList([]const u8) = .empty;
    for (got.items) |it| try rels.append(a, it.rel);
    var fit = far.keyIterator();
    while (fit.next()) |k| if (!near.contains(k.*)) try rels.append(a, k.*);
    std.mem.sort([]const u8, rels.items, {}, lessStr);

    var base = try sbase.load(e.io, a, o.base_dir);
    var gitm: ?@import("git-run.zig").Git = null;
    if (o.mode == .sync and !o.no_merge and e.conf.sync.merge_globs.len > 0) {
        const tmpd = std.fs.path.join(a, &.{ o.base_dir, "tmp" }) catch return error.OutOfMemory;
        gitm = s.git;
        gitm.?.root = tmpd;
    }

    var res: Res = .{};
    var recs: std.ArrayList(RowRec) = .empty;
    var near_w: u32 = 0;
    var far_w: u32 = 0;
    for (rels.items) |rel| {
        if (o.only) |pat| if (!(std.mem.eql(u8, pat, rel) or gm.glob(pat, rel))) continue;
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
        if (rec.td == .merge_or_pair) {
            const nh = sbase.hexOf(n.?);
            const fh = sbase.hexOf(f.?);
            if (sbase.knownConflict(&base, rel, &nh, &fh)) {
                rec.still = true;
                rec.td = .none;
                res.still += 1;
            } else if (gitm) |g| {
                if (smerge.mergeable(e.conf.sync.merge_globs, rel)) if (sbase.content(&base, e.io, a, rel)) |b| {
                    rec.merged = smerge.tryMerge(g, rel, n.?, b, f.?);
                };
            }
        }
        switch (rec.td) {
            .write_near => near_w += 1,
            .write_far => far_w += 1,
            .merge_or_pair => {
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
            .merge_or_pair => if (rec.merged != null) {
                res.merged += 1;
            } else {
                res.paired += 1;
            },
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

    // far first: if the vault push fails nothing on this device has changed ----
    const stamp = apply.stampOf(a, e.now_secs) catch return error.OutOfMemory;
    if (far_w > 0) {
        for (recs.items) |r| {
            const n = near.get(r.rel);
            switch (r.td) {
                .write_far => try far.put(a, r.rel, n.?),
                .merge_or_pair => if (r.merged) |m| try far.put(a, r.rel, m) else try far.put(a, try pairName(a, r.rel, "near", stamp), n.?),
                else => {},
            }
        }
        // the rail: the new bundle holds every file the old one held ----
        for (far_old.items) |k| if (!far.contains(k)) return error.GitFail;
        var out: std.ArrayList(arc.Item) = .empty;
        var kit = far.iterator();
        while (kit.next()) |kv| try out.append(a, .{ .rel = kv.key_ptr.*, .data = kv.value_ptr.* });
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
    const mode = conf.modeOf(e.conf.unpack.file_mode) orelse return error.WriteFail;
    const batch = std.fs.path.join(a, &.{ e.trash, stamp }) catch return error.OutOfMemory;
    for (recs.items) |r| {
        switch (r.td) {
            .write_near => try putNear(e, r.rel, far.get(r.rel).?, mode, batch),
            .merge_or_pair => if (r.merged) |m| try putNear(e, r.rel, m, mode, batch) else try putNear(e, try pairName(a, r.rel, "far", stamp), far.get(r.rel).?, mode, batch),
            else => {},
        }
    }

    // base: what both sides now agree on ----
    for (recs.items) |r| {
        if (r.seed or r.still) continue;
        const n = near.get(r.rel);
        switch (r.td) {
            .none => if (r.act == .same and n != null) try sbase.set(&base, e.io, a, r.rel, n.?),
            .write_near => {
                try sbase.set(&base, e.io, a, r.rel, far.get(r.rel).?);
                try sbase.clearConflict(&base, a, r.rel);
            },
            .write_far => {
                try sbase.set(&base, e.io, a, r.rel, n.?);
                try sbase.clearConflict(&base, a, r.rel);
            },
            .merge_or_pair => if (r.merged) |m| {
                try sbase.set(&base, e.io, a, r.rel, m);
                try sbase.clearConflict(&base, a, r.rel);
            } else {
                const nh = sbase.hexOf(n.?);
                const fh = sbase.hexOf(far.get(r.rel).?);
                try sbase.setConflict(&base, a, r.rel, &nh, &fh);
            },
            else => {},
        }
    }
    try sbase.save(&base, e.io, a);
    return res;
}
// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
