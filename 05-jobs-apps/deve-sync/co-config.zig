// =====================================================================
// Des: Reads 00-config.json, refuses any unknown or wrong setting with the exact line and column, and turns {home} {appdata} {repo} paths into real paths per OS
// Flo: read file > strict JSON parse into Conf > value checks > Conf (every tunable of the app lives here, none in the other files)
// Cre: 2026-11-15                          - | Mod: 2026-11-15
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: path of 00-config.json
// Out: Conf | ConfErro (why holds the one-line reason) ; fill() path helper
// Run: not run directly - imported by main.zig
// Exe: n/a
// =====================================================================
const std = @import("std");
const os = @import("co-os.zig");

const CF = .{ .vers = 1, .file_maxz = 256 * 1024, .name_maxz = 128, .kbyt_maxz = 4096, .tmos_floor = 5, .tmos_ceil = 600 };

pub const ConfErro = error{ Missing, Unreadable, BadJson, BadValue, OutOfMemory };

pub const Os3 = struct { linux: []const u8, macos: []const u8, windows: []const u8 };
pub const Roots = struct { claude: Os3, vscode: Os3 };
pub const Kind = enum { file, dir, merge, exts };
pub const RootId = enum { claude, vscode, repo };
pub const Setter = struct { key: []const u8, value: []const u8 };
pub const Item = struct {
    id: []const u8,
    kind: Kind,
    root: RootId,
    to: []const u8 = "",
    from: []const u8 = "",
    keys: []const []const u8 = &.{},
    set: []const Setter = &.{},
    skip: []const []const u8 = &.{},
};
pub const ScanCf = struct { names: []const []const u8, text: []const []const u8 };
pub const VscodeCf = struct { bin: []const u8, tmos_secs: u32 };
// big_files: most files one sync may change on one side without --big; base_dir: what this device and the repo last agreed on; merge_globs: files that may be auto-merged when both sides changed them; git_bin: the git used for the three-way merge ----
pub const SyncCf = struct { big_files: u32, base_dir: []const u8, merge_globs: []const []const u8, git_bin: []const u8 };
pub const Conf = struct {
    vers: u32,
    src: []const u8,
    claude_envz: []const u8,
    file_maxz_kbyt: u32,
    backup_dir: []const u8,
    roots: Roots,
    scan: ScanCf,
    vscode: VscodeCf,
    sync: SyncCf,
    items: []const Item,
};

var why_buf: [512]u8 = undefined;
pub var why: []const u8 = "";

fn note(comptime fmt: []const u8, args: anytype) void {
    why = std.fmt.bufPrint(&why_buf, fmt, args) catch "config problem";
}

fn bad(comptime fmt: []const u8, args: anytype) ConfErro {
    note(fmt, args);
    return error.BadValue;
}

fn readAll(io: std.Io, a: std.mem.Allocator, path: []const u8) ConfErro![]const u8 {
    const raw = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(CF.file_maxz)) catch |e| {
        note("{s}: {s}", .{ path, @errorName(e) });
        return if (e == error.FileNotFound) error.Missing else error.Unreadable;
    };
    return if (std.mem.startsWith(u8, raw, "\xEF\xBB\xBF")) raw[3..] else raw;
}

// strict: unknown key, missing key or wrong type is refused with line and column ----
pub fn parse(a: std.mem.Allocator, text: []const u8, label: []const u8) ConfErro!Conf {
    var scan = std.json.Scanner.initCompleteInput(a, text);
    var diag: std.json.Diagnostics = .{};
    scan.enableDiagnostics(&diag);
    return std.json.parseFromTokenSourceLeaky(Conf, a, &scan, .{ .ignore_unknown_fields = false, .allocate = .alloc_always }) catch |e| {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        note("{s}: {s} at line {d}, column {d}", .{ label, @errorName(e), diag.getLine(), diag.getColumn() });
        return error.BadJson;
    };
}

// a relative path with `/` only: no drive, no `..`, no empty part, no NUL ----
pub fn relSafe(p: []const u8) bool {
    if (p.len == 0 or p.len > 1024) return false;
    if (p[0] == '/' or p[0] == '\\' or std.mem.indexOfAny(u8, p, ":\\\x00") != null) return false;
    var it = std.mem.splitScalar(u8, p, '/');
    while (it.next()) |part| if (part.len == 0 or std.mem.eql(u8, part, "..") or std.mem.eql(u8, part, ".")) return false;
    return true;
}

fn plainName(n: []const u8) bool {
    if (n.len == 0 or n.len > CF.name_maxz) return false;
    for (n) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_')) return false;
    return true;
}

fn envName(n: []const u8) bool {
    if (n.len == 0 or n.len > CF.name_maxz) return false;
    for (n) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    return true;
}

// a folder setting: starts with a placeholder or is an absolute path ----
fn rootOk(p: []const u8) bool {
    return std.mem.startsWith(u8, p, "{home}") or std.mem.startsWith(u8, p, "{appdata}") or (p.len > 0 and p[0] == '/') or (p.len > 2 and p[1] == ':');
}

fn listOk(label: []const u8, list: []const []const u8, slash_ok: bool) ConfErro!void {
    for (list) |n| {
        if (n.len == 0 or n.len > CF.name_maxz) return bad("{s}: an entry is empty or longer than {d}", .{ label, CF.name_maxz });
        if (!slash_ok and std.mem.indexOfAny(u8, n, "/\\") != null) return bad("{s}: '{s}' must be a plain name, not a path", .{ label, n });
    }
}

pub fn check(c: *const Conf) ConfErro!void {
    if (c.vers != CF.vers) return bad("vers must be {d}", .{CF.vers});
    if (!relSafe(c.src) or std.mem.indexOfScalar(u8, c.src, '/') != null) return bad("src must be one plain folder name inside the repo", .{});
    if (!envName(c.claude_envz)) return bad("claude_envz must be an environment variable name (letters, digits, _)", .{});
    if (c.file_maxz_kbyt < 1 or c.file_maxz_kbyt > CF.kbyt_maxz) return bad("file_maxz_kbyt must be 1..{d}", .{CF.kbyt_maxz});
    if (!rootOk(c.backup_dir)) return bad("backup_dir must start with {{home}} or {{appdata}}, or be an absolute path", .{});
    inline for (.{ "claude", "vscode" }) |name| {
        const r = @field(c.roots, name);
        if (!rootOk(r.linux) or !rootOk(r.macos) or !rootOk(r.windows)) return bad("roots.{s}: every OS path must start with {{home}} or {{appdata}}, or be absolute", .{name});
    }
    try listOk("scan.names", c.scan.names, true);
    try listOk("scan.text", c.scan.text, true);
    if (c.vscode.bin.len == 0 or std.mem.indexOfAny(u8, c.vscode.bin, " \t\r\n") != null) return bad("vscode.bin must be one program name or path, without spaces", .{});
    if (c.vscode.tmos_secs < CF.tmos_floor or c.vscode.tmos_secs > CF.tmos_ceil) return bad("vscode.tmos_secs must be {d}..{d}", .{ CF.tmos_floor, CF.tmos_ceil });
    if (c.sync.big_files < 1 or c.sync.big_files > 1000000) return bad("sync.big_files must be 1..1000000", .{});
    if (!rootOk(c.sync.base_dir)) return bad("sync.base_dir must start with {{home}} or {{appdata}}, or be an absolute path", .{});
    try listOk("sync.merge_globs", c.sync.merge_globs, true);
    if (c.sync.git_bin.len == 0 or std.mem.indexOfAny(u8, c.sync.git_bin, " \t\r\n") != null) return bad("sync.git_bin must be one program name or path, without spaces", .{});
    if (c.items.len == 0) return bad("items is empty, nothing would sync", .{});
    for (c.items, 0..) |it, i| {
        if (!plainName(it.id)) return bad("items[{d}].id must be letters, digits, - or _", .{i});
        for (c.items[0..i]) |p| if (std.mem.eql(u8, p.id, it.id)) return bad("item id '{s}' is used twice", .{it.id});
        if (it.to.len > 0 and !relSafe(it.to)) return bad("{s}.to must be a relative path with '/' separators", .{it.id});
        if (it.from.len > 0 and !relSafe(it.from)) return bad("{s}.from must be a relative path with '/' separators", .{it.id});
        try listOk(it.id, it.keys, false);
        try listOk(it.id, it.skip, true);
        switch (it.kind) {
            .file, .dir => if (it.from.len == 0 or it.to.len == 0) return bad("{s}: file and dir items need from and to", .{it.id}),
            .merge => {
                if (it.to.len == 0 or !std.mem.endsWith(u8, it.to, ".json")) return bad("{s}: a merge item needs a .json target in to", .{it.id});
                if (it.keys.len == 0 and it.set.len == 0) return bad("{s}: a merge item needs keys or set", .{it.id});
                if (it.keys.len > 0 and it.from.len == 0) return bad("{s}: keys need a from file in the repo", .{it.id});
                for (it.set) |s| if (s.key.len == 0 or s.value.len == 0) return bad("{s}: a set entry needs key and value", .{it.id});
            },
            .exts => if (it.from.len == 0) return bad("{s}: an exts item needs from (the list file)", .{it.id}),
        }
    }
}

pub fn confLoad(io: std.Io, a: std.mem.Allocator, path: []const u8) ConfErro!Conf {
    const c = try parse(a, try readAll(io, a, path), path);
    try check(&c);
    return c;
}

pub const Fill = struct { home: []const u8, appdata: ?[]const u8, repo: []const u8 };
pub const FillErro = error{ NoAppdata, Unresolved, OutOfMemory };

// {home} {appdata} {repo} become real folders; any other {..} is refused ----
pub fn fill(a: std.mem.Allocator, text: []const u8, f: Fill) FillErro![]u8 {
    var cur = try a.dupe(u8, text);
    cur = try std.mem.replaceOwned(u8, a, cur, "{home}", f.home);
    cur = try std.mem.replaceOwned(u8, a, cur, "{repo}", f.repo);
    if (std.mem.indexOf(u8, cur, "{appdata}") != null) {
        const ad = f.appdata orelse return error.NoAppdata;
        cur = try std.mem.replaceOwned(u8, a, cur, "{appdata}", ad);
    }
    if (std.mem.indexOfScalar(u8, cur, '{') != null) return error.Unresolved;
    return cur;
}

pub fn osPath(r: Os3, which: os.Os) []const u8 {
    return switch (which) {
        .linux => r.linux,
        .macos => r.macos,
        .windows => r.windows,
    };
}

test "shipped config loads and passes every check" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const c = try confLoad(std.testing.io, a, "00-config.json");
    try std.testing.expect(c.items.len >= 10);
    try std.testing.expectEqualStrings(".deve-user", c.src);
}

test "unknown key, missing key and bad values are refused with a reason" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectError(error.BadJson, parse(a, "{\n \"vers\": 1,\n \"nope\": 2\n}", "t.json"));
    try std.testing.expect(std.mem.indexOf(u8, why, "line 3") != null);
    const shipped = try readAll(std.testing.io, a, "00-config.json");
    const good = try parse(a, shipped, "t.json");
    try check(&good);
    var c = good;
    c.vers = 2;
    try std.testing.expectError(error.BadValue, check(&c));
    c = good;
    c.src = "a/b";
    try std.testing.expectError(error.BadValue, check(&c));
    c = good;
    c.src = "..";
    try std.testing.expectError(error.BadValue, check(&c));
    c = good;
    c.file_maxz_kbyt = 0;
    try std.testing.expectError(error.BadValue, check(&c));
    c = good;
    c.backup_dir = "relative/dir";
    try std.testing.expectError(error.BadValue, check(&c));
    c = good;
    c.vscode.bin = "code --x";
    try std.testing.expectError(error.BadValue, check(&c));
    c = good;
    c.items = &.{};
    try std.testing.expectError(error.BadValue, check(&c));
    const dup = [_]Item{ .{ .id = "x", .kind = .file, .root = .claude, .to = "a", .from = "a" }, .{ .id = "x", .kind = .file, .root = .claude, .to = "b", .from = "b" } };
    c = good;
    c.items = &dup;
    try std.testing.expectError(error.BadValue, check(&c));
    const climb = [_]Item{.{ .id = "x", .kind = .file, .root = .claude, .to = "../evil", .from = "a" }};
    c.items = &climb;
    try std.testing.expectError(error.BadValue, check(&c));
    const nokeys = [_]Item{.{ .id = "x", .kind = .merge, .root = .claude, .to = "s.json" }};
    c.items = &nokeys;
    try std.testing.expectError(error.BadValue, check(&c));
    const nofrom = [_]Item{.{ .id = "x", .kind = .merge, .root = .claude, .to = "s.json", .keys = &.{"k"} }};
    c.items = &nofrom;
    try std.testing.expectError(error.BadValue, check(&c));
    const nojson = [_]Item{.{ .id = "x", .kind = .merge, .root = .claude, .to = "s.txt", .keys = &.{"k"}, .from = "f.json" }};
    c.items = &nojson;
    try std.testing.expectError(error.BadValue, check(&c));
}

test "relSafe refuses climbs, drives, backslashes, empty parts" {
    try std.testing.expect(relSafe("a/b.json"));
    try std.testing.expect(relSafe(".claude/settings.local.json"));
    for ([_][]const u8{ "", "/abs", "a/../b", "a//b", "./a", "C:x", "a\\b", "a/" }) |p| try std.testing.expect(!relSafe(p));
}

test "fill resolves the three placeholders and refuses an unknown one or a missing appdata" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f: Fill = .{ .home = "/h/me", .appdata = null, .repo = "/r" };
    try std.testing.expectEqualStrings("/h/me/.claude", try fill(a, "{home}/.claude", f));
    try std.testing.expectEqualStrings("/r/.claude/memory", try fill(a, "{repo}/.claude/memory", f));
    try std.testing.expectError(error.NoAppdata, fill(a, "{appdata}/Code", f));
    try std.testing.expectError(error.Unresolved, fill(a, "{nope}/x", f));
    const g: Fill = .{ .home = "C:\\Users\\me", .appdata = "C:\\Users\\me\\AppData\\Roaming", .repo = "E:\\r" };
    try std.testing.expectEqualStrings("C:\\Users\\me\\AppData\\Roaming/Code/User", try fill(a, "{appdata}/Code/User", g));
}
// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
