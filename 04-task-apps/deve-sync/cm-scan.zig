// =====================================================================
// Des: The secret guard for push - refuses a file whose name or text looks like a key, token or password before it can enter the repo
// Flo: match the file name against the name patterns > look for each secret marker in the text > first hit wins (the text itself is never printed)
// Cre: 2026-11-15                          - | Mod: 2026-11-15
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: scan rules from config, relative name, file bytes
// Out: null (clean) or Hit (which rule, by number)
// Run: not run directly - imported by cm-apply.zig
// Exe: n/a
// =====================================================================
const std = @import("std");
const conf = @import("co-config.zig");
const gm = @import("co-glob.zig");

pub const Kind = enum { name, text };
pub const Hit = struct { kind: Kind, idx: usize };

pub fn find(sc: conf.ScanCf, rel: []const u8, data: []const u8) ?Hit {
    for (sc.names, 0..) |p, i| if (gm.glob(p, rel)) return .{ .kind = .name, .idx = i };
    for (sc.text, 0..) |m, i| if (std.mem.indexOf(u8, data, m) != null) return .{ .kind = .text, .idx = i };
    return null;
}

test "a secret-looking name or marker is a hit; clean text is not; the rule number is returned" {
    const sc: conf.ScanCf = .{ .names = &.{ "*.pass", "*token*" }, .text = &.{ "ghp_", "-----BEGIN" } };
    const h1 = find(sc, "claude/x.pass", "ok").?;
    try std.testing.expectEqual(Kind.name, h1.kind);
    try std.testing.expectEqual(@as(usize, 0), h1.idx);
    const h2 = find(sc, "a/my-token.txt", "ok").?;
    try std.testing.expectEqual(@as(usize, 1), h2.idx);
    const h3 = find(sc, "a/b.md", "use ghp_abc123 here").?;
    try std.testing.expectEqual(Kind.text, h3.kind);
    try std.testing.expectEqual(@as(usize, 0), h3.idx);
    try std.testing.expectEqual(@as(usize, 1), find(sc, "k.md", "x\n-----BEGIN RSA").?.idx);
    try std.testing.expect(find(sc, "agents/a-code.md", "plain words only") == null);
    try std.testing.expect(find(.{ .names = &.{}, .text = &.{} }, "x", "ghp_") == null);
}
// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
