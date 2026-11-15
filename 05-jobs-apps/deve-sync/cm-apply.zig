// =====================================================================
// Des: Does sync, pull and push between this device (near) and the repo folder (far) - never deletes; a changed side goes to the other, a missing file comes back, a conflict is auto-merged (code, text) or the newest edit wins and the other copy goes to the trash folder
// Flo: decide per entry (3-way with the agreed base) > conflict: merge or newest wins > refuse a big change > secret guard > losing copies to the trash folder > far writes (old copy saved) > near writes (old copy saved) > update base
// Cre: 2026-11-15                          - | Mod: 2026-11-15
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: Ctx, Plan list from cm-plan, mode (sync, pull, push), go, big, no_merge flags
// Out: Counts + report text | ApplyErro (why holds the one-line reason)
// Run: not run directly - imported by main.zig
// Exe: n/a
// =====================================================================
const std = @import("std");
const conf = @import("co-config.zig");
const fio = @import("co-fsio.zig");
const js = @import("cm-json.zig");
const cx = @import("cm-exts.zig");
const scan = @import("cm-scan.zig");
const pl = @import("cm-plan.zig");
const tri = @import("cm-tri.zig");
const cb = @import("cm-base.zig");
const cm = @import("cm-merge.zig");

const CF = .{ .backup_mode = 0o600 };

pub const ApplyErro = error{ SecretFound, UnsafePath, WriteFail, BadJson, BadPath, BadDevJson, BadRepoJson, TooBig, ReadFail, LinkInTheWay, TooManyChanges, OutOfMemory } || cb.BaseErro;
pub const Counts = struct { near: u32 = 0, far: u32 = 0, merged: u32 = 0, newest: u32 = 0, behind: u32 = 0, ahead: u32 = 0, installed: u32 = 0, failed: u32 = 0, same: u32 = 0, raced: u32 = 0 };
pub const Res = struct { counts: Counts, report: []const u8 };

// loser: the copy a conflict overwrites (kept in the trash folder) ----
const Row = struct { p: usize, e: usize, td: tri.Todo, merged: ?[]const u8 = null, loser: ?[]const u8 = null, raced: bool = false };

fn wr(ctx: *const pl.Ctx, path: []const u8, data: []const u8, mode: ?u32) ApplyErro!void {
    fio.writeAtomic(ctx.io, ctx.a, path, data, mode) catch |e| {
        pl.note("{s}: {s}", .{ path, @errorName(e) });
        return e;
    };
}

// the device file is still what the plan saw (null = it did not exist): someone may have saved it while the sync ran ----
fn nearSame(ctx: *const pl.Ctx, path: []const u8, expect: ?[]const u8) ApplyErro!bool {
    const cur = try pl.rd(ctx, path);
    return if (cur) |x| (expect != null and std.mem.eql(u8, x, expect.?)) else expect == null;
}

// the newest edit wins; a tie (within sync.tie_secs) or an unknown time goes to the repo, the shared side ----
fn nearWins(cf: conf.SyncCf, e: pl.Entry) bool {
    if (e.dev_mt <= 0 or e.repo_mt <= 0) return false;
    return e.dev_mt - e.repo_mt > @as(i64, cf.tie_secs);
}

fn exists(io: std.Io, path: []const u8) bool {
    _ = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch return false;
    return true;
}

// the losing copy: <repo>/<trash_dir>/<same relative path>; a name already there keeps both (_yyMMdd_HHmmss, then -2, -3 ...) ----
fn trashCopy(ctx: *const pl.Ctx, rel: []const u8, data: []const u8, stamp: []const u8) ApplyErro!void {
    const a = ctx.a;
    const want = try std.fs.path.join(a, &.{ ctx.repo, ctx.cf.sync.trash_dir, rel });
    const ext = std.fs.path.extension(want);
    const stem = want[0 .. want.len - ext.len];
    var path = want;
    var k: u32 = 0;
    while (exists(ctx.io, path)) {
        k += 1;
        if (k > 999) return error.WriteFail;
        path = if (k == 1) try std.fmt.allocPrint(a, "{s}_{s}{s}", .{ stem, stamp, ext }) else try std.fmt.allocPrint(a, "{s}_{s}-{d}{s}", .{ stem, stamp, k, ext });
    }
    try wr(ctx, path, data, CF.backup_mode);
}

// where the overwritten copy lives, relative to the repo: the repo file itself, or <json file>.<key>.txt for a settings key ----
fn loserRel(ctx: *const pl.Ctx, it: conf.Item, rel: []const u8) ![]const u8 {
    const full = if (it.kind == .merge) try std.fmt.allocPrint(ctx.a, "{s}.{s}.txt", .{ try ctx.repoPath(it), rel }) else try repoFile(ctx, it, rel);
    if (std.mem.startsWith(u8, full, ctx.repo) and full.len > ctx.repo.len + 1) return full[ctx.repo.len + 1 ..];
    return std.fs.path.basename(full);
}

// base key: <item id>/<file>, the same on every device ----
fn keyOf(a: std.mem.Allocator, id: []const u8, rel: []const u8) ![]u8 {
    return std.fs.path.join(a, &.{ id, rel });
}

fn devFile(ctx: *const pl.Ctx, it: conf.Item, rel: []const u8) ![]const u8 {
    if (it.kind == .dir) {
        if (!conf.relSafe(rel)) return error.UnsafePath;
        return std.fs.path.join(ctx.a, &.{ try ctx.devPath(it), rel });
    }
    return ctx.devPath(it);
}

fn repoFile(ctx: *const pl.Ctx, it: conf.Item, rel: []const u8) ![]const u8 {
    if (it.kind == .dir) {
        if (!conf.relSafe(rel)) return error.UnsafePath;
        return std.fs.path.join(ctx.a, &.{ try ctx.repoPath(it), rel });
    }
    return ctx.repoPath(it);
}

fn sayRow(out: *std.ArrayList(u8), a: std.mem.Allocator, p: pl.Plan, e: pl.Entry, r: Row, trash: []const u8) void {
    const id = p.item.id;
    switch (r.td) {
        .none => {},
        .write_near => if (r.loser != null) out.print(a, "conflict: the repo is newer and wins, this device's copy goes to {s}/ {s}/{s}\n", .{ trash, id, e.rel }) catch {} else out.print(a, "write here {s}/{s}{s}\n", .{ id, e.rel, if (e.dev == null) " (restore: missing here)" else "" }) catch {},
        .write_far => if (r.loser != null) out.print(a, "conflict: this device is newer and wins, the repo's copy goes to {s}/ {s}/{s}\n", .{ trash, id, e.rel }) catch {} else out.print(a, "write repo {s}/{s}{s}\n", .{ id, e.rel, if (e.repo == null) " (restore: missing in the repo)" else "" }) catch {},
        .resolve => out.print(a, "merge (both changed, auto-merged into one version) {s}/{s}\n", .{ id, e.rel }) catch {},
        .skip_behind => out.print(a, "skip (the repo is newer, run sync or pull) {s}/{s}\n", .{ id, e.rel }) catch {},
        .skip_ahead => out.print(a, "skip (this device is newer, run sync or push) {s}/{s}\n", .{ id, e.rel }) catch {},
    }
}

pub fn run(ctx: *const pl.Ctx, plans: []const pl.Plan, mode: tri.Mode, go: bool, big: bool, no_merge: bool) ApplyErro!Res {
    const a = ctx.a;
    var c: Counts = .{};
    var report: std.ArrayList(u8) = .empty;
    var rows: std.ArrayList(Row) = .empty;
    var near_w: u32 = 0;
    var far_w: u32 = 0;
    const mrun: cm.Run = .{ .io = ctx.io, .a = a, .env = ctx.env, .bin = ctx.cf.sync.git_bin, .dir = try std.fs.path.join(a, &.{ try ctx.fillPath(ctx.cf.sync.base_dir), "tmp" }) };

    for (plans, 0..) |p, pi| {
        const kind = p.item.kind;
        for (p.entries, 0..) |e, ei| {
            var row: Row = .{ .p = pi, .e = ei, .td = tri.todo(mode, e.act) };
            if (e.act == .same) c.same += 1;
            if (row.td == .resolve) {
                if ((kind == .file or kind == .dir) and !no_merge and cm.mergeable(ctx.cf.sync.merge_globs, e.rel) and e.base != null) row.merged = cm.tryMerge(mrun, e.rel, e.dev.?, e.base.?, e.repo.?);
                if (row.merged == null) {
                    // no clean merge: the newest edit wins, the other copy is kept in the trash folder ----
                    const near_wins = nearWins(ctx.cf.sync, e);
                    row.td = if (near_wins) .write_far else .write_near;
                    row.loser = if (near_wins) e.repo else e.dev;
                    c.newest += 1;
                }
            }
            switch (row.td) {
                .write_near => near_w += 1,
                .write_far => far_w += 1,
                .resolve => {
                    near_w += 1;
                    far_w += 1;
                    c.merged += 1;
                },
                .skip_behind => c.behind += 1,
                .skip_ahead => c.ahead += 1,
                else => {},
            }
            sayRow(&report, a, p, e, row, ctx.cf.sync.trash_dir);
            try rows.append(a, row);
        }
    }
    if (!big and (near_w > ctx.cf.sync.big_files or far_w > ctx.cf.sync.big_files)) {
        pl.note("this would change {d} file(s) here and {d} in the repo; the limit is {d} (sync.big_files)", .{ near_w, far_w, ctx.cf.sync.big_files });
        return error.TooManyChanges;
    }
    // the secret guard: everything that would enter the repo is scanned first, all or nothing ----
    for (rows.items) |r| {
        const e = plans[r.p].entries[r.e];
        const it = plans[r.p].item;
        const data: ?[]const u8 = switch (r.td) {
            .write_far => e.dev,
            .resolve => r.merged,
            else => null,
        };
        if (data == null or e.set) continue;
        if (it.kind == .merge and it.from.len == 0) continue;
        if (scan.find(ctx.cf.scan, e.rel, data.?)) |h| {
            pl.note("{s}/{s} looks like a secret (scan.{s}[{d}]); not sent to the repo, nothing was written", .{ it.id, e.rel, @tagName(h.kind), h.idx });
            return error.SecretFound;
        }
    }
    c.near = near_w;
    c.far = far_w;
    if (!go) return .{ .counts = c, .report = report.items };

    const stamp = fio.stampOf(a, ctx.now_secs) catch return error.OutOfMemory;
    const batch = std.fs.path.join(a, &.{ try ctx.backupDir(), stamp }) catch return error.OutOfMemory;

    // the copies a conflict overwrites go to the trash folder first: if that fails nothing is overwritten ----
    for (rows.items) |r| {
        const lb = r.loser orelse continue;
        const p = plans[r.p];
        if (p.item.kind == .exts) continue;
        try trashCopy(ctx, try loserRel(ctx, p.item, p.entries[r.e].rel), lb, stamp);
    }

    // far (the repo folder) first, then near (this device) ----
    for (plans, 0..) |p, pi| {
        const it = p.item;
        switch (it.kind) {
            .file, .dir => for (rows.items) |r| {
                if (r.p != pi) continue;
                const e = p.entries[r.e];
                switch (r.td) {
                    .write_far => {
                        if (e.repo) |old| try wr(ctx, try std.fs.path.join(a, &.{ batch, "far", it.id, e.rel }), old, CF.backup_mode);
                        const rf = try repoFile(ctx, it, e.rel);
                        try wr(ctx, rf, e.dev.?, null);
                        fio.setMtime(ctx.io, rf, e.dev_mt);
                    },
                    .resolve => if (r.merged) |m| {
                        if (e.repo) |old| try wr(ctx, try std.fs.path.join(a, &.{ batch, "far", it.id, e.rel }), old, CF.backup_mode);
                        try wr(ctx, try repoFile(ctx, it, e.rel), m, null);
                    },
                    else => {},
                }
            },
            .merge => {
                var need = false;
                for (rows.items) |r| need = need or (r.p == pi and r.td == .write_far and !p.entries[r.e].set);
                if (!need or it.from.len == 0) continue;
                const path = try ctx.repoPath(it);
                var obj = try pl.loadObj(ctx, path, true);
                for (rows.items) |r| {
                    if (r.p != pi or r.td != .write_far) continue;
                    const e = p.entries[r.e];
                    if (e.set) continue;
                    const val = js.parseVal(a, e.dev.?) catch return error.BadJson;
                    js.putKey(a, &obj, e.rel, val) catch return error.OutOfMemory;
                }
                try wr(ctx, path, js.render(a, obj) catch return error.OutOfMemory, null);
            },
            .exts => {
                var need = false;
                for (rows.items) |r| need = need or (r.p == pi and r.td == .write_far);
                if (!need) continue;
                var ids: std.ArrayList(u8) = .empty;
                for (p.entries) |e| {
                    if (e.repo != null or e.dev != null) {
                        ids.appendSlice(a, e.rel) catch return error.OutOfMemory;
                        ids.append(a, '\n') catch return error.OutOfMemory;
                    }
                }
                try wr(ctx, try ctx.repoPath(it), ids.items, null);
            },
        }
    }
    for (plans, 0..) |p, pi| {
        const it = p.item;
        switch (it.kind) {
            .file, .dir => for (rows.items) |*r| {
                if (r.p != pi) continue;
                const e = p.entries[r.e];
                switch (r.td) {
                    .write_near => {
                        const dp = try devFile(ctx, it, e.rel);
                        if (!try nearSame(ctx, dp, e.dev)) {
                            r.raced = true;
                            c.raced += 1;
                            continue;
                        }
                        if (e.dev) |old| try wr(ctx, try std.fs.path.join(a, &.{ batch, it.id, e.rel }), old, CF.backup_mode);
                        try wr(ctx, dp, e.repo.?, null);
                        fio.setMtime(ctx.io, dp, e.repo_mt);
                    },
                    .resolve => if (r.merged) |m| {
                        const dp = try devFile(ctx, it, e.rel);
                        if (!try nearSame(ctx, dp, e.dev)) {
                            r.raced = true;
                            c.raced += 1;
                            continue;
                        }
                        if (e.dev) |old| try wr(ctx, try std.fs.path.join(a, &.{ batch, it.id, e.rel }), old, CF.backup_mode);
                        try wr(ctx, dp, m, null);
                    },
                    else => {},
                }
            },
            .merge => {
                var need = false;
                for (rows.items) |r| need = need or (r.p == pi and r.td == .write_near);
                if (!need) continue;
                const path = try ctx.devPath(it);
                var obj = try pl.loadObj(ctx, path, false);
                if (try pl.rd(ctx, path)) |text| try wr(ctx, try std.fs.path.join(a, &.{ batch, it.id, std.fs.path.basename(it.to) }), text, CF.backup_mode);
                for (rows.items) |r| {
                    if (r.p != pi or r.td != .write_near) continue;
                    const e = p.entries[r.e];
                    const val = js.parseVal(a, e.repo.?) catch return error.BadJson;
                    js.putKey(a, &obj, e.rel, val) catch return error.OutOfMemory;
                }
                try wr(ctx, path, js.render(a, obj) catch return error.OutOfMemory, null);
            },
            .exts => for (rows.items) |r| {
                if (r.p != pi or r.td != .write_near) continue;
                const e = p.entries[r.e];
                if (cx.install(ctx.extRun(), e.rel)) |_| c.installed += 1 else |_| c.failed += 1;
            },
        }
    }

    // base: what both sides now agree on (file, dir and key entries; never the device-only keys) ----
    if (ctx.base) |bs| {
        for (rows.items) |r| {
            const p = plans[r.p];
            const e = p.entries[r.e];
            if (p.item.kind == .exts or e.set or r.raced) continue;
            const key = try keyOf(a, p.item.id, e.rel);
            switch (r.td) {
                .none => if (e.act == .same and e.dev != null) try cb.set(bs, ctx.io, a, key, e.dev.?),
                .write_near => try cb.set(bs, ctx.io, a, key, e.repo.?),
                .write_far => try cb.set(bs, ctx.io, a, key, e.dev.?),
                .resolve => if (r.merged) |m| try cb.set(bs, ctx.io, a, key, m),
                else => {},
            }
        }
        try cb.save(bs, ctx.io, a);
    }
    return .{ .counts = c, .report = report.items };
}

// ---- tests ----
const T = pl.TestEnv;

fn withBase(t: *T, c: *pl.Ctx) !*cb.Base {
    const a = t.arena.allocator();
    const bs = try a.create(cb.Base);
    bs.* = try cb.load(std.testing.io, a, try std.fs.path.join(a, &.{ t.root, "home/.04-clou-secr/deve-base" }));
    c.base = bs;
    return bs;
}

const ITEMS = [_]conf.Item{
    .{ .id = "md", .kind = .file, .root = .claude, .from = "claude/CLAUDE.md", .to = "CLAUDE.md" },
    .{ .id = "ag", .kind = .dir, .root = .claude, .from = "claude/agents", .to = "agents" },
    .{ .id = "st", .kind = .merge, .root = .claude, .from = "claude/s.json", .to = "settings.json", .keys = &.{ "effort", "tui" } },
    .{ .id = "mem", .kind = .merge, .root = .repo, .to = ".claude/settings.local.json", .set = &.{.{ .key = "autoMemoryDirectory", .value = "{repo}/.claude/memory" }} },
};

fn plansOf(c: *const pl.Ctx) ![]pl.Plan {
    return pl.planAll(c, null);
}

test "pull: writes new files, saves the old copy first, merges only the listed keys, keeps device-only files; then everything is same and a rerun does nothing" {
    const t = try T.init();
    defer t.deinit();
    var c = try t.ctx(&ITEMS);
    _ = try withBase(t, &c);
    try t.put("repo/.deve-user/claude/CLAUDE.md", "RULES");
    try t.put("repo/.deve-user/claude/agents/a.md", "A");
    try t.put("repo/.deve-user/claude/agents/sub/b.md", "B");
    try t.put("repo/.deve-user/claude/s.json", "{\"effort\":\"high\",\"tui\":\"full\"}");
    try t.put("home/.claude/CLAUDE.md", "MY-OLD");
    try t.put("home/.claude/agents/a.md", "A-LOCAL");
    try t.put("home/.claude/agents/mine.md", "MINE");
    try t.put("home/.claude/settings.json", "{\"permissions\":{\"allow\":[\"x\"]},\"tui\":\"old\"}");
    var plans = try plansOf(&c);
    const dry = try run(&c, plans, .pull, false, false, false);
    try std.testing.expectEqualStrings("MY-OLD", t.get("home/.claude/CLAUDE.md").?);
    try std.testing.expect(dry.counts.near >= 4);
    _ = try run(&c, plans, .pull, true, false, false);
    try std.testing.expectEqualStrings("RULES", t.get("home/.claude/CLAUDE.md").?);
    try std.testing.expectEqualStrings("A", t.get("home/.claude/agents/a.md").?);
    try std.testing.expectEqualStrings("B", t.get("home/.claude/agents/sub/b.md").?);
    try std.testing.expectEqualStrings("MINE", t.get("home/.claude/agents/mine.md").?);
    const stamp = try fio.stampOf(t.arena.allocator(), 1_800_000_000);
    const bk = try std.fs.path.join(t.arena.allocator(), &.{ "home/.04-clou-secr/deve-backup", stamp });
    try std.testing.expectEqualStrings("MY-OLD", t.get(try std.fs.path.join(t.arena.allocator(), &.{ bk, "md/CLAUDE.md" })).?);
    try std.testing.expectEqualStrings("A-LOCAL", t.get(try std.fs.path.join(t.arena.allocator(), &.{ bk, "ag/a.md" })).?);
    const merged = t.get("home/.claude/settings.json").?;
    try std.testing.expect(std.mem.indexOf(u8, merged, "\"permissions\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, merged, "\"effort\": \"high\"") != null);
    plans = try plansOf(&c);
    const again = try run(&c, plans, .pull, true, false, false);
    try std.testing.expectEqual(@as(u32, 0), again.counts.near);
}

test "push: sends near-changed and new files into the repo, keeps repo-only files, never the device-only keys; a repo-newer file is skipped, not reverted" {
    const t = try T.init();
    defer t.deinit();
    var c = try t.ctx(&ITEMS);
    _ = try withBase(t, &c);
    try t.put("repo/.deve-user/claude/agents/keep.md", "REPO-ONLY");
    try t.put("repo/.deve-user/claude/agents/a.md", "A0");
    try t.put("home/.claude/agents/a.md", "A0");
    var plans = try plansOf(&c);
    _ = try run(&c, plans, .sync, true, false, false);
    try t.put("home/.claude/agents/a.md", "A-near");
    try t.put("repo/.deve-user/claude/agents/keep.md", "REPO-NEWER");
    try t.put("home/.claude/agents/new.md", "NEW");
    try t.put("repo/.deve-user/claude/s.json", "{\"effort\":\"low\"}");
    try t.put("home/.claude/settings.json", "{\"effort\":\"high\",\"permissions\":{\"additionalDirectories\":[\"C:\\\\Users\\\\me\"]}}");
    plans = try plansOf(&c);
    const r = try run(&c, plans, .push, true, false, false);
    try std.testing.expect(r.counts.behind >= 1);
    try std.testing.expectEqualStrings("A-near", t.get("repo/.deve-user/claude/agents/a.md").?);
    try std.testing.expectEqualStrings("NEW", t.get("repo/.deve-user/claude/agents/new.md").?);
    try std.testing.expectEqualStrings("REPO-NEWER", t.get("repo/.deve-user/claude/agents/keep.md").?);
    const shared = t.get("repo/.deve-user/claude/s.json").?;
    try std.testing.expect(std.mem.indexOf(u8, shared, "\"effort\": \"high\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, shared, "permissions") == null);
}

test "sync: both ways; non-overlapping edits merge into one version; overlapping edits: the newest wins and the loser goes to the trash folder; a removed file comes back" {
    const t = try T.init();
    defer t.deinit();
    var c = try t.ctx(&ITEMS);
    _ = try withBase(t, &c);
    c.cf.sync.merge_globs = &.{ "*.md", "*.txt" };
    c.cf.sync.git_bin = "git";
    if (std.c.getenv("PATH")) |p| try t.env.put("PATH", std.mem.span(p));
    try t.env.put("HOME", t.root);
    const probe = std.process.run(t.arena.allocator(), std.testing.io, .{ .argv = &.{ "git", "--version" }, .environ_map = &t.env }) catch return error.SkipZigTest;
    _ = probe;
    try t.put("repo/.deve-user/claude/agents/m.md", "l1\nl2\nl3\nl4\nl5\n");
    try t.put("repo/.deve-user/claude/agents/o.md", "n1\nn2\nn3\nn4\nn5\n");
    try t.put("repo/.deve-user/claude/agents/q.md", "q1\nq2\nq3\n");
    var plans = try plansOf(&c);
    _ = try run(&c, plans, .sync, true, false, false);
    try std.testing.expectEqualStrings("l1\nl2\nl3\nl4\nl5\n", t.get("home/.claude/agents/m.md").?);
    try t.put("home/.claude/agents/m.md", "L1-near\nl2\nl3\nl4\nl5\n");
    try t.put("repo/.deve-user/claude/agents/m.md", "l1\nl2\nl3\nl4\nL5-far\n");
    try t.put("home/.claude/agents/o.md", "n1\nn2\nN3-near\nn4\nn5\n");
    try t.put("repo/.deve-user/claude/agents/o.md", "n1\nn2\nN3-far\nn4\nn5\n");
    try t.put("home/.claude/agents/q.md", "q1\nQ2-near\nq3\n");
    try t.put("repo/.deve-user/claude/agents/q.md", "q1\nQ2-far\nq3\n");
    // o: this device edited it later; q: the repo copy is later
    try t.age("repo/.deve-user/claude/agents/o.md", 1_700_000_000);
    try t.age("home/.claude/agents/o.md", 1_700_001_000);
    try t.age("home/.claude/agents/q.md", 1_700_000_000);
    try t.age("repo/.deve-user/claude/agents/q.md", 1_700_001_000);
    plans = try plansOf(&c);
    const r = try run(&c, plans, .sync, true, false, false);
    try std.testing.expectEqual(@as(u32, 1), r.counts.merged);
    try std.testing.expectEqual(@as(u32, 2), r.counts.newest);
    try std.testing.expectEqualStrings("L1-near\nl2\nl3\nl4\nL5-far\n", t.get("home/.claude/agents/m.md").?);
    try std.testing.expectEqualStrings("L1-near\nl2\nl3\nl4\nL5-far\n", t.get("repo/.deve-user/claude/agents/m.md").?);
    // one version everywhere; the losing copy is in the trash folder under the same path
    try std.testing.expectEqualStrings("n1\nn2\nN3-near\nn4\nn5\n", t.get("home/.claude/agents/o.md").?);
    try std.testing.expectEqualStrings("n1\nn2\nN3-near\nn4\nn5\n", t.get("repo/.deve-user/claude/agents/o.md").?);
    try std.testing.expectEqualStrings("n1\nn2\nN3-far\nn4\nn5\n", t.get("repo/zzzz-delete-force-items/.deve-user/claude/agents/o.md").?);
    try std.testing.expectEqualStrings("q1\nQ2-far\nq3\n", t.get("home/.claude/agents/q.md").?);
    try std.testing.expectEqualStrings("q1\nQ2-far\nq3\n", t.get("repo/.deve-user/claude/agents/q.md").?);
    try std.testing.expectEqualStrings("q1\nQ2-near\nq3\n", t.get("repo/zzzz-delete-force-items/.deve-user/claude/agents/q.md").?);
    // the winner keeps the time of its edit on the other side too
    try std.testing.expectEqual(@as(i64, 1_700_001_000), fio.mtimeOf(std.testing.io, try std.fs.path.join(t.arena.allocator(), &.{ t.root, "repo/.deve-user/claude/agents/o.md" })));
    // a rerun finds nothing left to decide
    plans = try plansOf(&c);
    const r2 = try run(&c, plans, .sync, true, false, false);
    try std.testing.expectEqual(@as(u32, 0), r2.counts.merged + r2.counts.newest);
    try t.tmp.dir.rename("home/.claude/agents/m.md", t.tmp.dir, "home/moved-m.md", std.testing.io);
    plans = try plansOf(&c);
    _ = try run(&c, plans, .sync, true, false, false);
    try std.testing.expectEqualStrings("L1-near\nl2\nl3\nl4\nL5-far\n", t.get("home/.claude/agents/m.md").?);
}

test "a device file saved while the sync ran is left alone, not overwritten" {
    const t = try T.init();
    defer t.deinit();
    var c = try t.ctx(&ITEMS);
    _ = try withBase(t, &c);
    try t.put("repo/.deve-user/claude/CLAUDE.md", "FAR");
    try t.put("home/.claude/CLAUDE.md", "PLAN-SAW");
    const plans = try plansOf(&c);
    // the user saves the file after the plan was made
    try t.put("home/.claude/CLAUDE.md", "TYPED-JUST-NOW");
    const r = try run(&c, plans, .pull, true, false, false);
    try std.testing.expectEqual(@as(u32, 1), r.counts.raced);
    try std.testing.expectEqualStrings("TYPED-JUST-NOW", t.get("home/.claude/CLAUDE.md").?);
    // next run sees a real conflict-free state: the device changed, the repo changed: no base, so it is a conflict and pull lets the repo win with a backup
    const again = try run(&c, try plansOf(&c), .pull, true, false, false);
    try std.testing.expectEqual(@as(u32, 0), again.counts.raced);
    try std.testing.expectEqualStrings("FAR", t.get("home/.claude/CLAUDE.md").?);
}

test "push refuses a secret by name or by text and writes nothing at all; a big change needs --big" {
    const t = try T.init();
    defer t.deinit();
    var c = try t.ctx(&ITEMS);
    _ = try withBase(t, &c);
    try t.put("home/.claude/agents/fine.md", "fine");
    try t.put("home/.claude/agents/my-token-notes.md", "x");
    var plans = try plansOf(&c);
    try std.testing.expectError(error.SecretFound, run(&c, plans, .push, true, false, false));
    try std.testing.expect(std.mem.indexOf(u8, pl.why, "my-token-notes.md") != null);
    try std.testing.expect(t.get("repo/.deve-user/claude/agents/fine.md") == null);
    try t.tmp.dir.rename("home/.claude/agents/my-token-notes.md", t.tmp.dir, "home/moved.md", std.testing.io);
    try t.put("home/.claude/CLAUDE.md", "key ghp_abcdef123456 leaked");
    plans = try plansOf(&c);
    try std.testing.expectError(error.SecretFound, run(&c, plans, .push, true, false, false));
    try std.testing.expect(std.mem.indexOf(u8, pl.why, "ghp_abcdef") == null);
    try t.tmp.dir.rename("home/.claude/CLAUDE.md", t.tmp.dir, "home/moved2.md", std.testing.io);
    var i: u32 = 0;
    while (i < 60) : (i += 1) {
        var nb: [32]u8 = undefined;
        try t.put(try std.fmt.bufPrint(&nb, "home/.claude/agents/f{d}.md", .{i}), "x");
    }
    plans = try plansOf(&c);
    try std.testing.expectError(error.TooManyChanges, run(&c, plans, .push, true, false, false));
    try std.testing.expect(t.get("repo/.deve-user/claude/agents/f1.md") == null);
    _ = try run(&c, plans, .push, true, true, false);
    try std.testing.expectEqualStrings("x", t.get("repo/.deve-user/claude/agents/f1.md").?);
}

test "a broken device settings file stops the item and is left exactly as it was" {
    const t = try T.init();
    defer t.deinit();
    const c = try t.ctx(&ITEMS);
    try t.put("repo/.deve-user/claude/s.json", "{\"effort\":\"high\"}");
    try t.put("home/.claude/settings.json", "{ broken");
    try std.testing.expectError(error.BadDevJson, plansOf(&c));
    try std.testing.expectEqualStrings("{ broken", t.get("home/.claude/settings.json").?);
}

test "the sync code has no call that deletes anything" {
    const srcs = [_][]const u8{ @embedFile("cm-apply.zig"), @embedFile("cm-base.zig"), @embedFile("cm-merge.zig"), @embedFile("cm-tri.zig") };
    const bad = [_][]const u8{ "delete" ++ "File", "delete" ++ "Tree", "delete" ++ "Dir", "unl" ++ "ink", "remove" ++ "File" };
    for (srcs) |s| for (bad) |b| try std.testing.expect(std.mem.indexOf(u8, s, b) == null);
}
// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
