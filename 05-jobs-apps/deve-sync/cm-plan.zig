// =====================================================================
// Des: Compares the repo's shared copy with this device, item by item and file by file, and says for each one: same, differs, only in the repo, or only on this device
// Flo: resolve the paths per OS > read both sides (file, folder, JSON keys or extension list) > one Entry per thing > state from the two values > one sha256 of what the repo wants
// Cre: 2026-11-15                          - | Mod: 2026-11-15
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: Ctx (config, repo, home, OS) ; optional item id filter
// Out: Plan list (never writes anything) ; hex sha256 of the device side
// Run: not run directly - imported by cm-apply.zig and main.zig
// Exe: n/a
// =====================================================================
const std = @import("std");
const conf = @import("co-config.zig");
const os = @import("co-os.zig");
const fio = @import("co-fsio.zig");
const js = @import("cm-json.zig");
const cx = @import("cm-exts.zig");
const tri = @import("cm-tri.zig");
const cb = @import("cm-base.zig");

pub var why: []const u8 = "";
var why_buf: [768]u8 = undefined;

pub fn note(comptime fmt: []const u8, args: anytype) void {
    why = std.fmt.bufPrint(&why_buf, fmt, args) catch "problem";
}

pub const State = enum { same, differs, only_repo, only_dev };
pub const Entry = struct { rel: []const u8, state: State, repo: ?[]const u8, dev: ?[]const u8, set: bool = false, base: ?[]const u8 = null, act: tri.Act = .same, repo_mt: i64 = 0, dev_mt: i64 = 0 };
pub const Plan = struct { item: conf.Item, entries: []Entry, skipped: u32 = 0, unavailable: []const u8 = "" };

pub const Ctx = struct {
    io: std.Io,
    a: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    cf: conf.Conf,
    os_tag: os.Os,
    repo: []const u8,
    home: []const u8,
    appdata: ?[]const u8,
    claude_dir: ?[]const u8,
    now_secs: i64,
    base: ?*cb.Base = null,

    fn fillOf(self: *const Ctx) conf.Fill {
        return .{ .home = self.home, .appdata = self.appdata, .repo = self.repo };
    }

    pub fn fillPath(self: *const Ctx, tmpl: []const u8) ![]u8 {
        return conf.fill(self.a, tmpl, self.fillOf()) catch |e| {
            note("cannot resolve '{s}': {s}", .{ tmpl, @errorName(e) });
            return error.BadPath;
        };
    }

    pub fn devRoot(self: *const Ctx, id: conf.RootId) ![]const u8 {
        return switch (id) {
            .repo => self.repo,
            .claude => self.claude_dir orelse try self.fillPath(conf.osPath(self.cf.roots.claude, self.os_tag)),
            .vscode => try self.fillPath(conf.osPath(self.cf.roots.vscode, self.os_tag)),
        };
    }

    pub fn devPath(self: *const Ctx, it: conf.Item) ![]const u8 {
        return std.fs.path.join(self.a, &.{ try self.devRoot(it.root), it.to });
    }

    pub fn repoPath(self: *const Ctx, it: conf.Item) ![]const u8 {
        return std.fs.path.join(self.a, &.{ self.repo, self.cf.src, it.from });
    }

    pub fn backupDir(self: *const Ctx) ![]const u8 {
        return self.fillPath(self.cf.backup_dir);
    }

    // what both sides last agreed on for item `id`, file `rel` (null: nothing agreed yet) ----
    pub fn baseOf(self: *const Ctx, id: []const u8, rel: []const u8) ?[]const u8 {
        const b = self.base orelse return null;
        const key = std.fs.path.join(self.a, &.{ id, rel }) catch return null;
        return cb.content(b, self.io, self.a, key);
    }

    pub fn cap(self: *const Ctx) usize {
        return @as(usize, self.cf.file_maxz_kbyt) * 1024;
    }

    pub fn extRun(self: *const Ctx) cx.Run {
        return .{ .io = self.io, .a = self.a, .env = self.env, .bin = self.cf.vscode.bin, .tmos_secs = self.cf.vscode.tmos_secs };
    }
};

pub fn rd(ctx: *const Ctx, path: []const u8) !?[]const u8 {
    return fio.readOpt(ctx.io, ctx.a, path, ctx.cap()) catch |e| {
        note("{s}: {s}", .{ path, @errorName(e) });
        return e;
    };
}

fn stateOf(repo: ?[]const u8, dev: ?[]const u8) State {
    if (repo != null and dev != null) return if (std.mem.eql(u8, repo.?, dev.?)) .same else .differs;
    return if (repo != null) .only_repo else .only_dev;
}

// near = this device, far = the repo; a device-only key (set) always follows the repo template ----
fn entry(ctx: *const Ctx, id: []const u8, rel: []const u8, repo: ?[]const u8, dev: ?[]const u8, set: bool) Entry {
    const b = if (set) null else ctx.baseOf(id, rel);
    const act: tri.Act = if (set) (if (stateOf(repo, dev) == .same) .same else .to_near) else tri.decide(dev, repo, b);
    return .{ .rel = rel, .state = stateOf(repo, dev), .repo = repo, .dev = dev, .set = set, .base = b, .act = act };
}

// the edit times of both copies (0 = unknown); a key entry uses the time of its whole file ----
fn withMt(e: Entry, repo_mt: i64, dev_mt: i64) Entry {
    var x = e;
    x.repo_mt = repo_mt;
    x.dev_mt = dev_mt;
    return x;
}

fn planFile(ctx: *const Ctx, it: conf.Item) !Plan {
    const rp = try ctx.repoPath(it);
    const dp = try ctx.devPath(it);
    const r = try rd(ctx, rp);
    const d = try rd(ctx, dp);
    if (r == null and d == null) return .{ .item = it, .entries = &.{} };
    const list = try ctx.a.alloc(Entry, 1);
    list[0] = withMt(entry(ctx, it.id, std.fs.path.basename(it.to), r, d, false), fio.mtimeOf(ctx.io, rp), fio.mtimeOf(ctx.io, dp));
    return .{ .item = it, .entries = list };
}

fn has(list: []const []const u8, x: []const u8) bool {
    for (list) |y| if (std.mem.eql(u8, x, y)) return true;
    return false;
}

fn lessStr(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.lessThan(u8, x, y);
}

fn planDir(ctx: *const Ctx, it: conf.Item) !Plan {
    const a = ctx.a;
    const rp = try ctx.repoPath(it);
    const dp = try ctx.devPath(it);
    const lr = try fio.listFiles(ctx.io, a, rp, it.skip, ctx.cap());
    const ld = try fio.listFiles(ctx.io, a, dp, it.skip, ctx.cap());
    var skipped = lr.skipped + ld.skipped;
    var all: std.ArrayList([]const u8) = .empty;
    try all.appendSlice(a, lr.rels);
    for (ld.rels) |x| if (!has(lr.rels, x)) try all.append(a, x);
    std.mem.sort([]const u8, all.items, {}, lessStr);
    var list: std.ArrayList(Entry) = .empty;
    for (all.items) |rel| {
        if (!conf.relSafe(rel)) {
            skipped += 1;
            continue;
        }
        const rf = try std.fs.path.join(a, &.{ rp, rel });
        const df = try std.fs.path.join(a, &.{ dp, rel });
        const r = try rd(ctx, rf);
        const d = try rd(ctx, df);
        if (r == null and d == null) continue;
        try list.append(a, withMt(entry(ctx, it.id, rel, r, d, false), fio.mtimeOf(ctx.io, rf), fio.mtimeOf(ctx.io, df)));
    }
    return .{ .item = it, .entries = list.items, .skipped = skipped };
}

// the JSON object in a settings file; a missing file is an empty object, a broken one stops the item ----
pub fn loadObj(ctx: *const Ctx, path: []const u8, repo_side: bool) !std.json.Value {
    const text = (try rd(ctx, path)) orelse return js.emptyObj();
    return js.parseObj(ctx.a, text) catch |e| {
        note("{s}: not a JSON object ({s}); fix or move it, nothing was changed", .{ path, @errorName(e) });
        return if (repo_side) error.BadRepoJson else error.BadDevJson;
    };
}

fn valText(ctx: *const Ctx, obj: std.json.Value, key: []const u8) !?[]const u8 {
    const v = js.getKey(obj, key) orelse return null;
    return try js.canon(ctx.a, v);
}

fn planMerge(ctx: *const Ctx, it: conf.Item) !Plan {
    const a = ctx.a;
    const rp = try ctx.repoPath(it);
    const dp = try ctx.devPath(it);
    const shared = if (it.from.len > 0) try loadObj(ctx, rp, true) else js.emptyObj();
    const dev = try loadObj(ctx, dp, false);
    const rmt = if (it.from.len > 0) fio.mtimeOf(ctx.io, rp) else 0;
    const dmt = fio.mtimeOf(ctx.io, dp);
    var list: std.ArrayList(Entry) = .empty;
    for (it.keys) |k| {
        const r = try valText(ctx, shared, k);
        const d = try valText(ctx, dev, k);
        if (r == null and d == null) continue;
        try list.append(a, withMt(entry(ctx, it.id, k, r, d, false), rmt, dmt));
    }
    for (it.set) |s| {
        const want = try ctx.fillPath(s.value);
        const r = try js.canon(a, .{ .string = want });
        const d = try valText(ctx, dev, s.key);
        try list.append(a, entry(ctx, it.id, s.key, r, d, true));
    }
    return .{ .item = it, .entries = list.items };
}

fn planExts(ctx: *const Ctx, it: conf.Item) !Plan {
    const a = ctx.a;
    const text = (try rd(ctx, try ctx.repoPath(it))) orelse "";
    const want = try cx.parseList(a, text);
    const have = cx.list(ctx.extRun()) catch |e| return .{ .item = it, .entries = &.{}, .unavailable = switch (e) {
        error.Missing => "editor command not found",
        error.Timeout => "editor command timed out",
        else => "editor command failed",
    } };
    var all: std.ArrayList([]const u8) = .empty;
    try all.appendSlice(a, want);
    for (have) |x| if (!has(want, x)) try all.append(a, x);
    std.mem.sort([]const u8, all.items, {}, lessStr);
    var list: std.ArrayList(Entry) = .empty;
    for (all.items) |id| try list.append(a, entry(ctx, it.id, id, if (has(want, id)) "1" else null, if (has(have, id)) "1" else null, false));
    return .{ .item = it, .entries = list.items };
}

pub fn planOne(ctx: *const Ctx, it: conf.Item) !Plan {
    return switch (it.kind) {
        .file => planFile(ctx, it),
        .dir => planDir(ctx, it),
        .merge => planMerge(ctx, it),
        .exts => planExts(ctx, it),
    };
}

// all items in config order; `only` keeps one item ----
pub fn planAll(ctx: *const Ctx, only: ?[]const u8) ![]Plan {
    var out: std.ArrayList(Plan) = .empty;
    for (ctx.cf.items) |it| {
        if (only) |id| if (!std.mem.eql(u8, id, it.id)) continue;
        try out.append(ctx.a, try planOne(ctx, it));
    }
    if (only != null and out.items.len == 0) {
        note("no item with id '{s}' in the config", .{only.?});
        return error.NoSuchItem;
    }
    return out.items;
}

pub const Tally = struct { same: u32 = 0, differs: u32 = 0, only_repo: u32 = 0, only_dev: u32 = 0 };

pub fn tally(p: Plan) Tally {
    var t: Tally = .{};
    for (p.entries) |e| switch (e.state) {
        .same => t.same += 1,
        .differs => t.differs += 1,
        .only_repo => t.only_repo += 1,
        .only_dev => t.only_dev += 1,
    };
    return t;
}

pub fn allSame(plans: []const Plan) bool {
    for (plans) |p| {
        const t = tally(p);
        if (t.differs + t.only_repo + t.only_dev > 0) return false;
    }
    return true;
}

// one fingerprint of what this device holds for everything the repo wants: equal on two devices = same setup ----
pub fn devSha(plans: []const Plan) [64]u8 {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    for (plans) |p| for (p.entries) |e| {
        // a set key holds this device's own path: never part of the shared fingerprint ----
        if (e.repo == null or e.set) continue;
        h.update(p.item.id);
        h.update("\x00");
        h.update(e.rel);
        h.update("\x00");
        if (e.dev) |d| {
            h.update("\x02");
            h.update(d);
        } else h.update("\x01");
        h.update("\xff");
    };
    var digest: [32]u8 = undefined;
    h.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

// ---- tests ----
pub const TestEnv = struct {
    arena: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,
    env: std.process.Environ.Map,
    root: []const u8,

    pub fn init() !*TestEnv {
        const t = try std.testing.allocator.create(TestEnv);
        t.arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        t.tmp = std.testing.tmpDir(.{});
        t.env = std.process.Environ.Map.init(t.arena.allocator());
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        t.root = try t.arena.allocator().dupe(u8, buf[0..try t.tmp.dir.realPath(std.testing.io, &buf)]);
        return t;
    }

    pub fn deinit(t: *TestEnv) void {
        t.tmp.cleanup();
        t.arena.deinit();
        std.testing.allocator.destroy(t);
    }

    pub fn ctx(t: *TestEnv, items: []const conf.Item) !Ctx {
        const a = t.arena.allocator();
        var cf = try conf.confLoad(std.testing.io, a, "00-config.json");
        cf.items = items;
        cf.vscode.bin = "zz-no-such-editor-9f3k";
        return .{ .io = std.testing.io, .a = a, .env = &t.env, .cf = cf, .os_tag = .linux, .repo = try std.fs.path.join(a, &.{ t.root, "repo" }), .home = try std.fs.path.join(a, &.{ t.root, "home" }), .appdata = null, .claude_dir = null, .now_secs = 1_800_000_000 };
    }

    pub fn put(t: *TestEnv, rel: []const u8, data: []const u8) !void {
        if (std.fs.path.dirname(rel)) |d| try t.tmp.dir.createDirPath(std.testing.io, d);
        try t.tmp.dir.writeFile(std.testing.io, .{ .sub_path = rel, .data = data });
    }

    // set a file's edit time (seconds since 1970) so a test can say which edit is newer ----
    pub fn age(t: *TestEnv, rel: []const u8, secs: i64) !void {
        try t.tmp.dir.setTimestamps(std.testing.io, rel, .{ .modify_timestamp = .{ .new = std.Io.Timestamp.fromNanoseconds(@as(i96, secs) * std.time.ns_per_s) } });
    }

    pub fn get(t: *TestEnv, rel: []const u8) ?[]const u8 {
        return t.tmp.dir.readFileAlloc(std.testing.io, rel, t.arena.allocator(), .limited(1 << 20)) catch null;
    }
};

test "file item: missing both = none; only repo; same; differs; only device" {
    const t = try TestEnv.init();
    defer t.deinit();
    const items = [_]conf.Item{.{ .id = "md", .kind = .file, .root = .claude, .from = "claude/CLAUDE.md", .to = "CLAUDE.md" }};
    const c = try t.ctx(&items);
    var p = try planAll(&c, null);
    try std.testing.expectEqual(@as(usize, 0), p[0].entries.len);
    try t.put("repo/.deve-user/claude/CLAUDE.md", "RULES");
    p = try planAll(&c, null);
    try std.testing.expectEqual(State.only_repo, p[0].entries[0].state);
    try std.testing.expectEqualStrings("CLAUDE.md", p[0].entries[0].rel);
    try t.put("home/.claude/CLAUDE.md", "RULES");
    p = try planAll(&c, null);
    try std.testing.expectEqual(State.same, p[0].entries[0].state);
    try t.put("home/.claude/CLAUDE.md", "MINE");
    p = try planAll(&c, null);
    try std.testing.expectEqual(State.differs, p[0].entries[0].state);
    try t.tmp.dir.deleteFile(std.testing.io, "repo/.deve-user/claude/CLAUDE.md");
    p = try planAll(&c, null);
    try std.testing.expectEqual(State.only_dev, p[0].entries[0].state);
}

test "dir item: union of both sides, sorted, skip patterns honoured" {
    const t = try TestEnv.init();
    defer t.deinit();
    const items = [_]conf.Item{.{ .id = "ag", .kind = .dir, .root = .claude, .from = "claude/agents", .to = "agents", .skip = &.{"synced/*"} }};
    const c = try t.ctx(&items);
    try t.put("repo/.deve-user/claude/agents/b.md", "B");
    try t.put("repo/.deve-user/claude/agents/a.md", "A");
    try t.put("home/.claude/agents/a.md", "A");
    try t.put("home/.claude/agents/b.md", "B-LOCAL");
    try t.put("home/.claude/agents/c.md", "C");
    try t.put("home/.claude/agents/synced/x.md", "X");
    const p = try planAll(&c, null);
    const e = p[0].entries;
    try std.testing.expectEqual(@as(usize, 3), e.len);
    try std.testing.expectEqual(State.same, e[0].state);
    try std.testing.expectEqual(State.differs, e[1].state);
    try std.testing.expectEqual(State.only_dev, e[2].state);
    const tl = tally(p[0]);
    try std.testing.expectEqual(@as(u32, 1), tl.same);
    try std.testing.expect(!allSame(p));
}

test "merge item: per key states; set keys come from the template; a broken device file stops it" {
    const t = try TestEnv.init();
    defer t.deinit();
    const items = [_]conf.Item{
        .{ .id = "st", .kind = .merge, .root = .claude, .from = "claude/s.json", .to = "settings.json", .keys = &.{ "effort", "tui", "extra" } },
        .{ .id = "mem", .kind = .merge, .root = .repo, .to = ".claude/settings.local.json", .set = &.{.{ .key = "autoMemoryDirectory", .value = "{repo}/.claude/memory" }} },
    };
    const c = try t.ctx(&items);
    try t.put("repo/.deve-user/claude/s.json", "{\"effort\":\"high\",\"tui\":\"full\"}");
    try t.put("home/.claude/settings.json", "{\"tui\":\"other\",\"permissions\":{\"x\":1},\"extra\":true}");
    const p = try planAll(&c, null);
    const e = p[0].entries;
    try std.testing.expectEqual(@as(usize, 3), e.len);
    try std.testing.expectEqual(State.only_repo, e[0].state);
    try std.testing.expectEqual(State.differs, e[1].state);
    try std.testing.expectEqual(State.only_dev, e[2].state);
    try std.testing.expectEqual(State.only_repo, p[1].entries[0].state);
    try std.testing.expect(p[1].entries[0].set);
    try std.testing.expect(std.mem.indexOf(u8, p[1].entries[0].repo.?, "/repo/.claude/memory") != null);
    try t.put("home/.claude/settings.json", "{ not json");
    try std.testing.expectError(error.BadDevJson, planAll(&c, null));
    try std.testing.expect(std.mem.indexOf(u8, why, "settings.json") != null);
}

test "exts item: no editor = unavailable, never an error" {
    const t = try TestEnv.init();
    defer t.deinit();
    const items = [_]conf.Item{.{ .id = "x", .kind = .exts, .root = .vscode, .from = "vscode/extensions.txt" }};
    const c = try t.ctx(&items);
    try t.put("repo/.deve-user/vscode/extensions.txt", "a.one\n");
    const p = try planAll(&c, null);
    try std.testing.expectEqual(@as(usize, 0), p[0].entries.len);
    try std.testing.expectEqualStrings("editor command not found", p[0].unavailable);
}

test "an unknown item id is refused; the sha changes when a device file changes and ignores device-only files" {
    const t = try TestEnv.init();
    defer t.deinit();
    const items = [_]conf.Item{.{ .id = "md", .kind = .file, .root = .claude, .from = "claude/CLAUDE.md", .to = "CLAUDE.md" }};
    const c = try t.ctx(&items);
    try std.testing.expectError(error.NoSuchItem, planAll(&c, "nope"));
    try t.put("repo/.deve-user/claude/CLAUDE.md", "RULES");
    try t.put("home/.claude/CLAUDE.md", "RULES");
    const s1 = devSha(try planAll(&c, null));
    try t.put("home/.claude/CLAUDE.md", "CHANGED");
    const s2 = devSha(try planAll(&c, null));
    try std.testing.expect(!std.mem.eql(u8, &s1, &s2));
    try t.put("home/.claude/CLAUDE.md", "RULES");
    const s3 = devSha(try planAll(&c, null));
    try std.testing.expectEqualSlices(u8, &s1, &s3);
}

test "the fingerprint ignores set keys, which hold a device-specific path" {
    const t = try TestEnv.init();
    defer t.deinit();
    const items = [_]conf.Item{.{ .id = "mem", .kind = .merge, .root = .repo, .to = ".claude/settings.local.json", .set = &.{.{ .key = "autoMemoryDirectory", .value = "{repo}/.claude/memory" }} }};
    const c = try t.ctx(&items);
    const s1 = devSha(try planAll(&c, null));
    try t.put("repo/.claude/settings.local.json", "{\"autoMemoryDirectory\":\"/some/other/place\"}");
    const s2 = devSha(try planAll(&c, null));
    try std.testing.expectEqualSlices(u8, &s1, &s2);
    try std.testing.expect(!allSame(try planAll(&c, null)));
}
// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
