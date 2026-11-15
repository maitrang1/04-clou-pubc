// =====================================================================
// Des: Does sync, pull and push between this device (near) and the repo folder (far) - never deletes; a changed side goes to the other, a missing file comes back, a conflict is auto-merged (code, text) or both copies are kept
// Flo: decide per entry (3-way with the agreed base) > refuse a big change > secret guard on everything going to the repo > far writes (old copy saved) > near writes (old copy saved) > update base
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
pub const Counts = struct { near: u32 = 0, far: u32 = 0, merged: u32 = 0, paired: u32 = 0, still: u32 = 0, behind: u32 = 0, ahead: u32 = 0, installed: u32 = 0, failed: u32 = 0, same: u32 = 0 };
pub const Res = struct { counts: Counts, report: []const u8 };

const Row = struct { p: usize, e: usize, td: tri.Todo, merged: ?[]const u8 = null, keep_both: bool = false, still: bool = false };

fn wr(ctx: *const pl.Ctx, path: []const u8, data: []const u8, mode: ?u32) ApplyErro!void {
    fio.writeAtomic(ctx.io, ctx.a, path, data, mode) catch |e| {
        pl.note("{s}: {s}", .{ path, @errorName(e) });
        return e;
    };
}

// name.ext -> name.conflict-<side>-<stamp>.ext ----
pub fn pairName(a: std.mem.Allocator, rel: []const u8, side: []const u8, stamp: []const u8) ![]u8 {
    const ext = std.fs.path.extension(rel);
    return std.fmt.allocPrint(a, "{s}.conflict-{s}-{s}{s}", .{ rel[0 .. rel.len - ext.len], side, stamp, ext });
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

fn sayRow(out: *std.ArrayList(u8), a: std.mem.Allocator, p: pl.Plan, e: pl.Entry, r: Row) void {
    const id = p.item.id;
    if (r.still) return out.print(a, "conflict (still unresolved, both copies kept) {s}/{s}\n", .{ id, e.rel }) catch {};
    if (r.keep_both) return out.print(a, "conflict (both changed, nobody wins, nothing written) {s}/{s}\n", .{ id, e.rel }) catch {};
    switch (r.td) {
        .none => {},
        .write_near => out.print(a, "write here {s}/{s}{s}\n", .{ id, e.rel, if (e.dev == null) " (restore: missing here)" else "" }) catch {},
        .write_far => out.print(a, "write repo {s}/{s}{s}\n", .{ id, e.rel, if (e.repo == null) " (restore: missing in the repo)" else "" }) catch {},
        .merge_or_pair => if (r.merged != null) out.print(a, "merge (both changed, auto-merged into one version) {s}/{s}\n", .{ id, e.rel }) catch {} else out.print(a, "conflict (both changed, nobody wins, both copies kept) {s}/{s}\n", .{ id, e.rel }) catch {},
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
            if (row.td == .merge_or_pair) {
                const key = try keyOf(a, p.item.id, e.rel);
                const nh = cb.hexOf(e.dev.?);
                const fh = cb.hexOf(e.repo.?);
                if (ctx.base) |bs| if (cb.knownConflict(bs, key, &nh, &fh)) {
                    row.still = true;
                    row.td = .none;
                    c.still += 1;
                };
                if (!row.still) {
                    if (kind == .file or kind == .dir) {
                        if (!no_merge and cm.mergeable(ctx.cf.sync.merge_globs, e.rel) and e.base != null) row.merged = cm.tryMerge(mrun, e.rel, e.dev.?, e.base.?, e.repo.?);
                    } else {
                        // keys and extension lists have no second copy to keep: leave both as they are and report ----
                        row.td = .none;
                        row.keep_both = true;
                        c.paired += 1;
                    }
                }
            }
            switch (row.td) {
                .write_near => near_w += 1,
                .write_far => far_w += 1,
                .merge_or_pair => {
                    near_w += 1;
                    far_w += 1;
                    if (row.merged != null) c.merged += 1 else c.paired += 1;
                },
                .skip_behind => c.behind += 1,
                .skip_ahead => c.ahead += 1,
                else => {},
            }
            sayRow(&report, a, p, e, row);
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
            .merge_or_pair => r.merged orelse e.dev,
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
    const bdir = try ctx.backupDir();
    const batch = std.fs.path.join(a, &.{ bdir, stamp }) catch return error.OutOfMemory;

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
                        try wr(ctx, try repoFile(ctx, it, e.rel), e.dev.?, null);
                    },
                    .merge_or_pair => if (r.merged) |m| {
                        if (e.repo) |old| try wr(ctx, try std.fs.path.join(a, &.{ batch, "far", it.id, e.rel }), old, CF.backup_mode);
                        try wr(ctx, try repoFile(ctx, it, e.rel), m, null);
                    } else {
                        // nobody wins: this device's copy sits beside the repo file; the repo's copy is kept beside the device's backups ----
                        const rp = try repoFile(ctx, it, e.rel);
                        const pr = try std.fs.path.join(a, &.{ std.fs.path.dirname(rp) orelse ".", try pairName(a, std.fs.path.basename(rp), "near", stamp) });
                        try wr(ctx, pr, e.dev.?, null);
                        try wr(ctx, try std.fs.path.join(a, &.{ bdir, "conflicts", stamp, it.id, e.rel }), e.repo.?, CF.backup_mode);
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
            .file, .dir => for (rows.items) |r| {
                if (r.p != pi) continue;
                const e = p.entries[r.e];
                switch (r.td) {
                    .write_near => {
                        if (e.dev) |old| try wr(ctx, try std.fs.path.join(a, &.{ batch, it.id, e.rel }), old, CF.backup_mode);
                        try wr(ctx, try devFile(ctx, it, e.rel), e.repo.?, null);
                    },
                    .merge_or_pair => if (r.merged) |m| {
                        if (e.dev) |old| try wr(ctx, try std.fs.path.join(a, &.{ batch, it.id, e.rel }), old, CF.backup_mode);
                        try wr(ctx, try devFile(ctx, it, e.rel), m, null);
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
            if (p.item.kind == .exts or e.set) continue;
            const key = try keyOf(a, p.item.id, e.rel);
            switch (r.td) {
                .none => if (e.act == .same and e.dev != null and !r.still and !r.keep_both) try cb.set(bs, ctx.io, a, key, e.dev.?),
                .write_near => {
                    try cb.set(bs, ctx.io, a, key, e.repo.?);
                    try cb.clearConflict(bs, a, key);
                },
                .write_far => {
                    try cb.set(bs, ctx.io, a, key, e.dev.?);
                    try cb.clearConflict(bs, a, key);
                },
                .merge_or_pair => if (r.merged) |m| {
                    try cb.set(bs, ctx.io, a, key, m);
                    try cb.clearConflict(bs, a, key);
                } else {
                    const nh = cb.hexOf(e.dev.?);
                    const fh = cb.hexOf(e.repo.?);
                    try cb.setConflict(bs, a, key, &nh, &fh);
                },
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
    .{ .id = "ag", .kind = .dir, .root = .claude, .from = "claude/agents", .to = "agents", .skip = &.{"*.conflict-*"} },
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

test "sync: both ways; non-overlapping edits of one file merge into one version; overlapping edits keep both and nobody wins; a removed file comes back" {
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
    var plans = try plansOf(&c);
    _ = try run(&c, plans, .sync, true, false, false);
    try std.testing.expectEqualStrings("l1\nl2\nl3\nl4\nl5\n", t.get("home/.claude/agents/m.md").?);
    try t.put("home/.claude/agents/m.md", "L1-near\nl2\nl3\nl4\nl5\n");
    try t.put("repo/.deve-user/claude/agents/m.md", "l1\nl2\nl3\nl4\nL5-far\n");
    try t.put("home/.claude/agents/o.md", "n1\nn2\nN3-near\nn4\nn5\n");
    try t.put("repo/.deve-user/claude/agents/o.md", "n1\nn2\nN3-far\nn4\nn5\n");
    plans = try plansOf(&c);
    const r = try run(&c, plans, .sync, true, false, false);
    try std.testing.expectEqual(@as(u32, 1), r.counts.merged);
    try std.testing.expectEqual(@as(u32, 1), r.counts.paired);
    try std.testing.expectEqualStrings("L1-near\nl2\nl3\nl4\nL5-far\n", t.get("home/.claude/agents/m.md").?);
    try std.testing.expectEqualStrings("L1-near\nl2\nl3\nl4\nL5-far\n", t.get("repo/.deve-user/claude/agents/m.md").?);
    try std.testing.expectEqualStrings("n1\nn2\nN3-near\nn4\nn5\n", t.get("home/.claude/agents/o.md").?);
    try std.testing.expectEqualStrings("n1\nn2\nN3-far\nn4\nn5\n", t.get("repo/.deve-user/claude/agents/o.md").?);
    const stamp = try fio.stampOf(t.arena.allocator(), 1_800_000_000);
    const pr = try std.fmt.allocPrint(t.arena.allocator(), "repo/.deve-user/claude/agents/o.conflict-near-{s}.md", .{stamp});
    try std.testing.expectEqualStrings("n1\nn2\nN3-near\nn4\nn5\n", t.get(pr).?);
    const far_copy = try std.fmt.allocPrint(t.arena.allocator(), "home/.04-clou-secr/deve-backup/conflicts/{s}/ag/o.md", .{stamp});
    try std.testing.expectEqualStrings("n1\nn2\nN3-far\nn4\nn5\n", t.get(far_copy).?);
    plans = try plansOf(&c);
    const r2 = try run(&c, plans, .sync, true, false, false);
    try std.testing.expectEqual(@as(u32, 1), r2.counts.still);
    try std.testing.expectEqual(@as(u32, 0), r2.counts.merged + r2.counts.paired);
    plans = try plansOf(&c);
    _ = try run(&c, plans, .push, true, false, false);
    try std.testing.expectEqualStrings("n1\nn2\nN3-near\nn4\nn5\n", t.get("repo/.deve-user/claude/agents/o.md").?);
    try t.tmp.dir.rename("home/.claude/agents/m.md", t.tmp.dir, "home/moved-m.md", std.testing.io);
    plans = try plansOf(&c);
    _ = try run(&c, plans, .sync, true, false, false);
    try std.testing.expectEqualStrings("L1-near\nl2\nl3\nl4\nL5-far\n", t.get("home/.claude/agents/m.md").?);
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
