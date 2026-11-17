// =====================================================================
// Des: Starts a resumable upload session - sends the title, description, tags, category and the safety fields (privacy, kids, AI label, notify) and gets back the session address
// Flo: build video JSON > POST uploadType=resumable with the size and type headers > 200 + Location = session address
// Cre: 2026-11-15                          - | Mod: 2026-11-15
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: Tok, Meta, file size
// Out: Result {ok session uri | api Verdict | net error | bad reply}
// Run: not run directly - imported by cm-publish
// =====================================================================
const std = @import("std");
const call = @import("ap-call.zig");
const http = @import("co-http.zig");
const ap_err = @import("ap-err.zig");

pub const Meta = struct {
    title: []const u8,
    description: []const u8,
    tags: []const []const u8,
    category_id: []const u8,
    privacy: []const u8, // private | unlisted | public
    made_for_kids: bool,
    notify: bool,
};

pub const Result = union(enum) { ok: []const u8, api: ap_err.Verdict, net: anyerror, bad_reply };

// wire shape: Google's real field names
const Snip = struct { title: []const u8, description: []const u8, tags: []const []const u8, categoryId: []const u8 };
const Stat = struct { privacyStatus: []const u8, selfDeclaredMadeForKids: bool, containsSyntheticMedia: bool };
const Body = struct { snippet: Snip, status: Stat };

pub fn bodyJson(a: std.mem.Allocator, m: Meta) ![]u8 {
    // containsSyntheticMedia is always true: the AI label has no off switch
    const b = Body{
        .snippet = .{ .title = m.title, .description = m.description, .tags = m.tags, .categoryId = m.category_id },
        .status = .{ .privacyStatus = m.privacy, .selfDeclaredMadeForKids = m.made_for_kids, .containsSyntheticMedia = true },
    };
    return std.json.Stringify.valueAlloc(a, b, .{});
}

pub fn start(t: *call.Tok, m: Meta, size: u64) Result {
    const a = t.a;
    const body = bodyJson(a, m) catch return .{ .net = error.OutOfMemory };
    const url = std.fmt.allocPrint(a, "{s}/videos?uploadType=resumable&part=snippet%2Cstatus&notifySubscribers={s}", .{ t.cx.cfg.google.upload_base, if (m.notify) "true" else "false" }) catch return .{ .net = error.OutOfMemory };
    const len = std.fmt.allocPrint(a, "{d}", .{size}) catch return .{ .net = error.OutOfMemory };
    const hs = [_]std.http.Header{
        .{ .name = "Content-Type", .value = "application/json; charset=UTF-8" },
        .{ .name = "X-Upload-Content-Length", .value = len },
        .{ .name = "X-Upload-Content-Type", .value = "video/mp4" },
    };
    const out = t.call(http.Req{ .method = "POST", .url = url, .headers = &hs, .body = .{ .bytes = body } });
    switch (out) {
        .ok => |r| {
            if (r.status != 200 or r.location.len == 0) return .bad_reply;
            return .{ .ok = r.location };
        },
        .api => |v| return .{ .api = v },
        .net => |e| return .{ .net = e },
    }
}

test "the body carries the safety fields and is valid JSON with quotes escaped" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const j = try bodyJson(a, .{ .title = "Xe \"dep\"", .description = "d\nline", .tags = &.{ "a", "b" }, .category_id = "2", .privacy = "private", .made_for_kids = false, .notify = false });
    const P = struct { snippet: struct { title: []const u8, tags: []const []const u8, categoryId: []const u8 }, status: struct { privacyStatus: []const u8, selfDeclaredMadeForKids: bool, containsSyntheticMedia: bool } };
    const p = try std.json.parseFromSliceLeaky(P, a, j, .{ .ignore_unknown_fields = true });
    try std.testing.expectEqualStrings("Xe \"dep\"", p.snippet.title);
    try std.testing.expectEqualStrings("2", p.snippet.categoryId); // a string, never a number
    try std.testing.expectEqualStrings("private", p.status.privacyStatus);
    try std.testing.expect(p.status.containsSyntheticMedia and !p.status.selfDeclaredMadeForKids);
    try std.testing.expectEqual(@as(usize, 2), p.snippet.tags.len);
}
// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
