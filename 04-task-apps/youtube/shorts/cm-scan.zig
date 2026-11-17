// =====================================================================
// Des: The scan command - lists every pair in the hand-off folder with one plain status (ready, held, approved, posted, failed, unsure, invalid, rejected, stale, old) and the reason; changes nothing
// Flo: scan folder > join with ledger rows > print one line per video + a count line
// Cre: 2026-11-15                          - | Mod: 2026-11-15
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: scan [--json] [--config FILE]
// Out: lines or a JSON array; exit 0 · 2 when source.dir is not usable
// Run: /home/mai_trang/04-clou-base/04-task-apps/youtube/shorts/zig-out/bin/shorts scan
// =====================================================================
const std = @import("std");
const ctx_mod = @import("co-ctx.zig");
const util = @import("co-util.zig");
const exit = @import("co-exit.zig");
const send = @import("rw-send.zig");
const pair = @import("rw-pair.zig");
const pick = @import("rw-pick.zig");

pub fn run(cx: *const ctx_mod.Ctx, _: []const []const u8, json: bool) u8 {
    var arena = std.heap.ArenaAllocator.init(cx.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const items = pair.scan(cx, a) catch |e| {
        util.eprint(cx.io, "error: {s}\nwhy: source.dir is empty or unreadable\nfix: set source.dir in the config to the producer's output folder\n", .{@errorName(e)});
        return exit.usage;
    };
    const l = send.Ledger.open(cx, a) catch {
        util.eprint(cx.io, "error: the ledger cannot be opened\nwhy: {s}/{s}\nfix: shorts doctor\n", .{ cx.data_dir, cx.cfg.db_file });
        return exit.blocked;
    };
    defer l.close();
    var counts = [_]u32{0} ** @typeInfo(pick.Kind).@"enum".fields.len;
    const J = struct { name: []const u8, status: []const u8, reason: []const u8, note: []const u8, width: u32, height: u32, seconds: u64, video_id: []const u8 };
    var jl: std.ArrayList(J) = .empty;
    for (items) |it| {
        const row = l.find(a, it.pkey) catch null;
        const k = pick.kindOf(it, row);
        counts[@intFromEnum(k)] += 1;
        const w: u32 = if (it.facts) |f| f.width else 0;
        const h: u32 = if (it.facts) |f| f.height else 0;
        const s: u64 = if (it.facts) |f| (f.ms + 999) / 1000 else 0;
        var why: []const u8 = it.reason;
        if (k == .held and row == null) why = "review video: needs shorts approve";
        if (row) |r| if (r.note.len > 0) {
            why = r.note;
        };
        if (json) {
            jl.append(a, .{ .name = it.name, .status = pick.label(k), .reason = why, .note = it.note, .width = w, .height = h, .seconds = s, .video_id = if (row) |r| r.video_id else "" }) catch {};
        } else {
            if (it.facts != null) util.print(cx.io, "{s: <9} {s}  {d}x{d} {d}s  {s}\n", .{ pick.label(k), it.name, w, h, s, why }) else util.print(cx.io, "{s: <9} {s}  {s}\n", .{ pick.label(k), it.name, why });
        }
    }
    if (json) {
        const s = util.jsonStr(a, jl.items) catch return exit.failed;
        util.printAll(cx.io, s);
        util.printAll(cx.io, "\n");
        return exit.ok;
    }
    util.print(cx.io, "---\n{d} videos:", .{items.len});
    inline for (@typeInfo(pick.Kind).@"enum".fields, 0..) |f, i| if (counts[i] > 0) util.print(cx.io, " {d} {s}", .{ counts[i], f.name });
    util.print(cx.io, "\n", .{});
    return exit.ok;
}
// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
