// =====================================================================
// Des: Checks that the configured category id exists and can be assigned to videos in the configured region
// Flo: GET videoCategories?part=snippet&regionCode=XX > find the id > assignable flag (filtered here, the API has no filter)
// Cre: 2026-11-15                          - | Mod: 2026-11-15
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: Tok, category id
// Out: Cat {missing | not assignable | ok with title} | api / net errors
// Run: not run directly - imported by cm-doctor
// =====================================================================
const std = @import("std");
const call = @import("ap-call.zig");
const http = @import("co-http.zig");
const ap_err = @import("ap-err.zig");

pub const Cat = union(enum) { missing, not_assignable, ok: []const u8, api: ap_err.Verdict, net: anyerror, bad_reply };

const Sn = struct { title: []const u8 = "", assignable: bool = false };
const It = struct { id: []const u8 = "", snippet: Sn = .{} };
const L = struct { items: []const It = &.{} };

pub fn parse(a: std.mem.Allocator, body: []const u8, id: []const u8) ?Cat {
    const l = std.json.parseFromSliceLeaky(L, a, body, .{ .ignore_unknown_fields = true }) catch return null;
    for (l.items) |i| if (std.mem.eql(u8, i.id, id)) return if (i.snippet.assignable) Cat{ .ok = i.snippet.title } else Cat.not_assignable;
    return .missing;
}

pub fn check(t: *call.Tok, id: []const u8) Cat {
    const url = std.fmt.allocPrint(t.a, "{s}/videoCategories?part=snippet&regionCode={s}", .{ t.cx.cfg.google.api_base, t.cx.cfg.google.region_code }) catch return .{ .net = error.OutOfMemory };
    return switch (t.call(http.Req{ .url = url })) {
        .ok => |r| parse(t.a, r.body, id) orelse .bad_reply,
        .api => |v| .{ .api = v },
        .net => |e| .{ .net = e },
    };
}

test "assignable, not assignable, missing" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const j = "{\"items\":[{\"id\":\"2\",\"snippet\":{\"title\":\"Autos\",\"assignable\":true}},{\"id\":\"29\",\"snippet\":{\"title\":\"Nonprofits\",\"assignable\":false}}]}";
    try std.testing.expectEqualStrings("Autos", parse(a, j, "2").?.ok);
    try std.testing.expect(parse(a, j, "29").? == .not_assignable);
    try std.testing.expect(parse(a, j, "99").? == .missing);
    try std.testing.expect(parse(a, "nope", "2") == null);
}
// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
