// =====================================================================
// Des: Reads the bot token and the chat ids from the secrets - env var first, then a file in the secrets folder - checks their shape, and registers them so no log line can ever carry them; the post mode picks the TEST chat or the REAL channel
// Flo: env or secret file > trim > shape check > guard.addSecret > value (arena-owned)
// Cre: 2026-11-16                          - | Mod: 2026-11-16
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: Ctx (secrets folder, telegram.* names, post.public)
// Out: token text, chat value, Target {chat, alias} | Err
// Run: not run directly - imported by the commands and ap-call
// =====================================================================
const std = @import("std");
const ctx_mod = @import("co-ctx.zig");
const util = @import("co-util.zig");
const guard = @import("co-guard.zig");

pub const Err = error{ NoToken, BadToken, NoChat, BadChat, OutOfMemory };

pub const Target = struct {
    chat: []const u8, // the chat id or @name, from a secret file
    alias: []const u8, // "test" or "real": the only thing stored or printed
};

// env var first, then the file; "" and a missing file are null
pub fn secret(cx: *const ctx_mod.Ctx, a: std.mem.Allocator, env_name: []const u8, file_name: []const u8) ?[]const u8 {
    if (env_name.len > 0) if (cx.envGet(env_name)) |v| {
        const t = util.trimSecret(v);
        if (t.len > 0) return a.dupe(u8, t) catch return null;
    };
    const p = cx.secretPath(a, file_name) catch return null;
    const text = util.readAll(a, cx.io, p, 4096) catch return null;
    const t = util.trimSecret(text);
    return if (t.len == 0) null else t;
}

// 123456:ABC-def_1 : digits, a colon, then letters digits _ -
pub fn tokenShapeOk(t: []const u8) bool {
    const c = std.mem.indexOfScalar(u8, t, ':') orelse return false;
    if (c == 0 or c + 1 >= t.len or t.len > 200) return false;
    for (t[0..c]) |ch| if (!std.ascii.isDigit(ch)) return false;
    for (t[c + 1 ..]) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-')) return false;
    return true;
}

// -1001234567890 or 12345 (a number), or @name (letters digits _, 4 to 64)
pub fn chatShapeOk(c: []const u8) bool {
    if (c.len == 0 or c.len > 70) return false;
    if (c[0] == '@') {
        if (c.len < 5) return false;
        for (c[1..]) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '_')) return false;
        return true;
    }
    const digits = if (c[0] == '-') c[1..] else c;
    if (digits.len == 0) return false;
    for (digits) |ch| if (!std.ascii.isDigit(ch)) return false;
    return true;
}

pub fn token(cx: *const ctx_mod.Ctx, a: std.mem.Allocator) Err![]const u8 {
    const t = secret(cx, a, cx.cfg.telegram.token_env, cx.cfg.telegram.token_file) orelse return Err.NoToken;
    if (!tokenShapeOk(t)) return Err.BadToken;
    guard.addSecret(t);
    return t;
}

fn chatFrom(cx: *const ctx_mod.Ctx, a: std.mem.Allocator, file: []const u8, none: Err) Err![]const u8 {
    const t = secret(cx, a, "", file) orelse return none;
    if (!chatShapeOk(t)) return Err.BadChat;
    if (t[0] != '@') guard.addSecret(t); // a numeric id is private; a public @name is not a secret
    return t;
}

// the chat this run sends to: the REAL channel only when post.public is true, else the private TEST chat
pub fn target(cx: *const ctx_mod.Ctx, a: std.mem.Allocator) Err!Target {
    if (cx.cfg.post.public) return .{ .chat = try chatFrom(cx, a, cx.cfg.telegram.chat_file, Err.NoChat), .alias = "real" };
    return .{ .chat = try chatFrom(cx, a, cx.cfg.telegram.test_chat_file, Err.NoChat), .alias = "test" };
}

// a chat by the alias stored in the ledger row (resolve asks about where the video went, not where config points now)
pub fn targetOf(cx: *const ctx_mod.Ctx, a: std.mem.Allocator, alias: []const u8) Err!Target {
    if (std.mem.eql(u8, alias, "real")) return .{ .chat = try chatFrom(cx, a, cx.cfg.telegram.chat_file, Err.NoChat), .alias = "real" };
    return .{ .chat = try chatFrom(cx, a, cx.cfg.telegram.test_chat_file, Err.NoChat), .alias = "test" };
}

pub fn explain(e: Err) []const u8 {
    return switch (e) {
        error.NoToken => "no bot token: put it in the secrets folder (see 10-HOW-TO, step \"Create the bot\")",
        error.BadToken => "the bot token file is not a token (expected digits, a colon, then letters)",
        error.NoChat => "no chat id for this mode: put the channel id in the secrets folder (see 10-HOW-TO)",
        error.BadChat => "the chat file is not a chat id (expected a number like -100123... or @name)",
        error.OutOfMemory => "out of memory",
    };
}

test "token and chat shapes" {
    try std.testing.expect(tokenShapeOk("123456:AAH-xyz_9"));
    try std.testing.expect(!tokenShapeOk("123456"));
    try std.testing.expect(!tokenShapeOk(":abc"));
    try std.testing.expect(!tokenShapeOk("12a:abc"));
    try std.testing.expect(!tokenShapeOk("123:a/b"));
    try std.testing.expect(!tokenShapeOk("123:a b"));
    try std.testing.expect(chatShapeOk("-1001234567890"));
    try std.testing.expect(chatShapeOk("12345"));
    try std.testing.expect(chatShapeOk("@my_channel"));
    try std.testing.expect(!chatShapeOk("@ab"));
    try std.testing.expect(!chatShapeOk("-"));
    try std.testing.expect(!chatShapeOk("12 34"));
    try std.testing.expect(!chatShapeOk("1;drop"));
}

test "secrets come from the env first, then the file; the mode picks the chat" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    defer guard.clearSecrets();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    var env = std.process.Environ.Map.init(a);
    var cx = ctx_mod.testCtx(a, &env, dir);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/tele-bot-token.txt", .{dir}), .data = "111:FILE-tok\n" });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/tele-chat-test.txt", .{dir}), .data = "-100111\n" });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/tele-chat.txt", .{dir}), .data = "@real_chan\n" });
    try std.testing.expectEqualStrings("111:FILE-tok", try token(&cx, a));
    try env.put("TELE_BOT_TOKEN", "222:ENV-tok");
    try std.testing.expectEqualStrings("222:ENV-tok", try token(&cx, a));
    const t = try target(&cx, a);
    try std.testing.expectEqualStrings("test", t.alias);
    try std.testing.expectEqualStrings("-100111", t.chat);
    cx.cfg.post.public = true;
    const r = try target(&cx, a);
    try std.testing.expectEqualStrings("real", r.alias);
    try std.testing.expectEqualStrings("@real_chan", r.chat);
    try std.testing.expectEqualStrings("test", (try targetOf(&cx, a, "test")).alias);
    // a missing file is "no chat", a bad shape is refused
    cx.cfg.telegram.chat_file = "nope.txt";
    try std.testing.expectError(Err.NoChat, target(&cx, a));
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/tele-chat-test.txt", .{dir}), .data = "bad chat!\n" });
    try std.testing.expectError(Err.BadChat, targetOf(&cx, a, "test"));
}
// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
