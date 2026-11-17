// =====================================================================
// Des: Lists and installs VS Code extensions by running the editor's own command line, with a time limit and no shell
// Flo: run `code --list-extensions` > clean, lowercase, sort > install one id at a time with `code --install-extension <id>`
// Cre: 2026-11-15                          - | Mod: 2026-11-15
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: Run{ io, allocator, env, program, time limit } ; extension id
// Out: sorted id list | install result | ExtErro (Missing = the program is not installed)
// Run: not run directly - imported by cm-plan.zig and cm-apply.zig
// Exe: n/a
// =====================================================================
const std = @import("std");
const builtin = @import("builtin");

const CF = .{ .out_maxz = 1024 * 1024, .id_maxz = 128 };

pub const ExtErro = error{ Missing, Timeout, Failed, BadId, OutOfMemory };

pub const Run = struct {
    io: std.Io,
    a: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    bin: []const u8,
    tmos_secs: u32,
};

// publisher.name: letters, digits, dot, dash, underscore only - the id goes into an argv slot ----
pub fn idOk(id: []const u8) bool {
    if (id.len < 3 or id.len > CF.id_maxz or std.mem.indexOfScalar(u8, id, '.') == null) return false;
    if (id[0] == '-') return false;
    for (id) |c| if (!(std.ascii.isAlphanumeric(c) or c == '.' or c == '-' or c == '_')) return false;
    return true;
}

fn call(r: Run, args: []const []const u8) ExtErro!struct { code: u8, out: []const u8 } {
    var argv: [4][]const u8 = undefined;
    if (args.len + 1 > argv.len) return error.Failed;
    argv[0] = r.bin;
    @memcpy(argv[1..][0..args.len], args);
    const got = std.process.run(r.a, r.io, .{
        .argv = argv[0 .. args.len + 1],
        .environ_map = r.env,
        .stdout_limit = .limited(CF.out_maxz),
        .stderr_limit = .limited(CF.out_maxz),
        .timeout = .{ .duration = .{ .raw = .fromNanoseconds(@as(i96, r.tmos_secs) * std.time.ns_per_s), .clock = .awake } },
    }) catch |e| return switch (e) {
        error.FileNotFound => error.Missing,
        error.Timeout => error.Timeout,
        error.OutOfMemory => error.OutOfMemory,
        else => error.Failed,
    };
    const code: u8 = switch (got.term) {
        .exited => |c| c,
        else => 255,
    };
    return .{ .code = code, .out = got.stdout };
}

fn lessStr(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.lessThan(u8, x, y);
}

// text with one id per line (a repo list file or the editor's answer): trimmed, lowercase, valid, unique, sorted ----
pub fn parseList(a: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var ids: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const t = std.mem.trim(u8, raw, " \r\t");
        if (t.len == 0 or t[0] == '#' or !idOk(t)) continue;
        const low = try std.ascii.allocLowerString(a, t);
        var dup = false;
        for (ids.items) |x| if (std.mem.eql(u8, x, low)) {
            dup = true;
        };
        if (!dup) try ids.append(a, low);
    }
    std.mem.sort([]const u8, ids.items, {}, lessStr);
    return ids.items;
}

pub fn list(r: Run) ExtErro![]const []const u8 {
    const res = try call(r, &.{"--list-extensions"});
    if (res.code != 0) return error.Failed;
    return parseList(r.a, res.out) catch return error.OutOfMemory;
}

pub fn install(r: Run, id: []const u8) ExtErro!void {
    if (!idOk(id)) return error.BadId;
    const res = try call(r, &.{ "--install-extension", id });
    if (res.code != 0) return error.Failed;
}

test "ids: only publisher.name with safe characters" {
    try std.testing.expect(idOk("ziglang.vscode-zig"));
    try std.testing.expect(idOk("anthropic.claude-code"));
    for ([_][]const u8{ "", "noDot", "a.b c", "-x.y", "a.b;rm", "a.b$(x)", "../x.y" }) |bad| try std.testing.expect(!idOk(bad));
}

test "parseList trims, lowercases, drops junk and comments, removes duplicates, sorts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const got = try parseList(a, "B.Two\r\n# note\n\nA.One\nb.two\nbad id\n--flag.x\n");
    try std.testing.expectEqual(@as(usize, 2), got.len);
    try std.testing.expectEqualStrings("a.one", got[0]);
    try std.testing.expectEqualStrings("b.two", got[1]);
}

test "list and install run the program; a missing program is Missing; a failing one is Failed" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try a.dupe(u8, buf[0..try tmp.dir.realPath(io, &buf)]);
    const script = try std.fs.path.join(a, &.{ root, "fake-code" });
    {
        const f = try std.Io.Dir.cwd().createFile(io, script, .{ .permissions = .fromMode(0o755) });
        defer f.close(io);
        try f.writePositionalAll(io, "#!/bin/sh\nif [ \"$1\" = \"--list-extensions\" ]; then printf 'B.Two\\nA.One\\n'; exit 0; fi\nif [ \"$1\" = \"--install-extension\" ]; then echo \"$2\" >> \"$(dirname \"$0\")/installed.txt\"; exit 0; fi\nexit 1\n", 0);
    }
    var env = std.process.Environ.Map.init(a);
    if (std.c.getenv("PATH")) |p| try env.put("PATH", std.mem.span(p));
    const r: Run = .{ .io = io, .a = a, .env = &env, .bin = script, .tmos_secs = 20 };
    const got = try list(r);
    try std.testing.expectEqual(@as(usize, 2), got.len);
    try std.testing.expectEqualStrings("a.one", got[0]);
    try install(r, "x.new-ext");
    const done = try std.Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(a, &.{ root, "installed.txt" }), a, .limited(100));
    try std.testing.expectEqualStrings("x.new-ext\n", done);
    try std.testing.expectError(error.BadId, install(r, "bad id"));
    var nope = r;
    nope.bin = "zz-no-such-editor-9f3k";
    try std.testing.expectError(error.Missing, list(nope));
    var fail = r;
    fail.bin = "false";
    try std.testing.expectError(error.Failed, list(fail));
}
// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
