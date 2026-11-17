// =====================================================================
// Des: The fixed exit codes of the app - one place so every command and every doc agrees
// Flo: commands return one of these numbers > main passes it to the shell
// Cre: 2026-11-15                          - | Mod: 2026-11-15
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: none
// Out: u8 constants
// Run: not run directly - imported by main and the commands
// =====================================================================
const std = @import("std");

pub const ok: u8 = 0;
pub const failed: u8 = 1;
pub const usage: u8 = 2;
pub const blocked: u8 = 3;
pub const nothing: u8 = 4;
pub const unsure: u8 = 5;

test "codes are distinct" {
    const all = [_]u8{ ok, failed, usage, blocked, nothing, unsure };
    for (all, 0..) |a, i| for (all[i + 1 ..]) |b| try std.testing.expect(a != b);
}
// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
