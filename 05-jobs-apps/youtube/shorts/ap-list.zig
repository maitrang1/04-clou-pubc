// =====================================================================
// Des: Looks at the channel - who it is and its newest uploads (title, time, id) through the uploads playlist, so an unclear send can be matched without ever re-uploading
// Flo: channels.list mine=true > uploads playlist id > playlistItems.list newest first > Upload rows
// Cre: 2026-11-15                          - | Mod: 2026-11-15
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: Tok
// Out: Channel {id, uploads playlist} | []Upload {video id, title, published_at}
// Run: not run directly - imported by cm-resolve, cm-doctor
// =====================================================================
const std = @import("std");
const call = @import("ap-call.zig");
const http = @import("co-http.zig");
const ap_err = @import("ap-err.zig");

pub const Channel = struct { id: []const u8, uploads: []const u8 };
pub const Upload = struct { video_id: []const u8, title: []const u8, published_at: []const u8 };

pub const ChanRes = union(enum) { ok: Channel, none, api: ap_err.Verdict, net: anyerror, bad_reply };
pub const UpRes = union(enum) { ok: []const Upload, api: ap_err.Verdict, net: anyerror, bad_reply };

const Rel = struct { uploads: []const u8 = "" };
const Rels = struct { relatedPlaylists: Rel = .{} };
const ChItem = struct { id: []const u8 = "", contentDetails: Rels = .{} };
const ChList = struct { items: []const ChItem = &.{} };

const ResId = struct { videoId: []const u8 = "" };
const Snip = struct { title: []const u8 = "", publishedAt: []const u8 = "", resourceId: ResId = .{} };
const PlItem = struct { snippet: Snip = .{} };
const PlList = struct { items: []const PlItem = &.{} };

pub fn channel(t: *call.Tok) ChanRes {
    const url = std.fmt.allocPrint(t.a, "{s}/channels?part=contentDetails&mine=true", .{t.cx.cfg.google.api_base}) catch return .{ .net = error.OutOfMemory };
    switch (t.call(http.Req{ .url = url })) {
        .ok => |r| {
            const l = std.json.parseFromSliceLeaky(ChList, t.a, r.body, .{ .ignore_unknown_fields = true }) catch return .bad_reply;
            if (l.items.len == 0) return .none;
            return .{ .ok = .{ .id = l.items[0].id, .uploads = l.items[0].contentDetails.relatedPlaylists.uploads } };
        },
        .api => |v| return .{ .api = v },
        .net => |e| return .{ .net = e },
    }
}

pub fn uploads(t: *call.Tok, playlist: []const u8) UpRes {
    const url = std.fmt.allocPrint(t.a, "{s}/playlistItems?part=snippet&maxResults=50&playlistId={s}", .{ t.cx.cfg.google.api_base, playlist }) catch return .{ .net = error.OutOfMemory };
    switch (t.call(http.Req{ .url = url })) {
        .ok => |r| {
            const l = std.json.parseFromSliceLeaky(PlList, t.a, r.body, .{ .ignore_unknown_fields = true }) catch return .bad_reply;
            var out: std.ArrayList(Upload) = .empty;
            for (l.items) |i| out.append(t.a, .{ .video_id = i.snippet.resourceId.videoId, .title = i.snippet.title, .published_at = i.snippet.publishedAt }) catch return .{ .net = error.OutOfMemory };
            return .{ .ok = out.items };
        },
        .api => |v| return .{ .api = v },
        .net => |e| return .{ .net = e },
    }
}

test "wire shapes parse" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const c = try std.json.parseFromSliceLeaky(ChList, a, "{\"items\":[{\"id\":\"UC1\",\"contentDetails\":{\"relatedPlaylists\":{\"uploads\":\"UU1\"}}}]}", .{ .ignore_unknown_fields = true });
    try std.testing.expectEqualStrings("UU1", c.items[0].contentDetails.relatedPlaylists.uploads);
    const p = try std.json.parseFromSliceLeaky(PlList, a, "{\"items\":[{\"snippet\":{\"title\":\"T\",\"publishedAt\":\"2026-11-15T01:00:00Z\",\"resourceId\":{\"videoId\":\"v9\"}}}]}", .{ .ignore_unknown_fields = true });
    try std.testing.expectEqualStrings("v9", p.items[0].snippet.resourceId.videoId);
}
// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
