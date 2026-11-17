// =====================================================================
// Des: Tiny flag reader - finds "--name value" pairs and bare "--flag" switches in the argument list
// Flo: scan the list > match the name > return the next item or true/false
// Cre: 2026-11-15                          - | Mod: 2026-11-15
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: argument list, flag name
// Out: optional value or bool
// Run: not run directly - imported by the commands
// =====================================================================
const std = @import("std");

pub fn value(av: []const []const u8, name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i + 1 < av.len) : (i += 1) if (std.mem.eql(u8, av[i], name)) return av[i + 1];
    return null;
}
pub fn has(av: []const []const u8, name: []const u8) bool {
    for (av) |a| if (std.mem.eql(u8, a, name)) return true;
    return false;
}

test "flags" {
    const av = [_][]const u8{ "--video", "a", "--live", "--x" };
    try std.testing.expectEqualStrings("a", value(&av, "--video").?);
    try std.testing.expect(has(&av, "--live"));
    try std.testing.expect(value(&av, "--nope") == null);
    try std.testing.expect(value(&av, "--x") == null);
}
// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
