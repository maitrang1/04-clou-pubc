// =====================================================================
// Des: Asks YouTube about one video by id - upload status, processing status, privacy and the failure or rejection reason
// Flo: GET videos?part=status,processingDetails&id=X > parse the first item > Status (found or not)
// Cre: 2026-11-15                          - | Mod: 2026-11-15
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: Tok, video id
// Out: Res {ok VStatus | api Verdict | net error | bad reply}
// Run: not run directly - imported by cm-publish, cm-resolve
// =====================================================================
const std = @import("std");
const call = @import("ap-call.zig");
const http = @import("co-http.zig");
const ap_err = @import("ap-err.zig");

pub const VStatus = struct {
    found: bool = false,
    upload_status: []const u8 = "",
    failure_reason: []const u8 = "",
    rejection_reason: []const u8 = "",
    privacy: []const u8 = "",
    processing: []const u8 = "",

    pub fn isDone(self: VStatus) bool {
        return std.mem.eql(u8, self.upload_status, "processed");
    }
    pub fn isBad(self: VStatus) bool {
        return std.mem.eql(u8, self.upload_status, "failed") or std.mem.eql(u8, self.upload_status, "rejected") or std.mem.eql(u8, self.upload_status, "deleted");
    }
};

pub const Res = union(enum) { ok: VStatus, api: ap_err.Verdict, net: anyerror, bad_reply };

// wire shape: Google's real field names; every field optional (values are partly from page summaries)
const St = struct { uploadStatus: []const u8 = "", failureReason: []const u8 = "", rejectionReason: []const u8 = "", privacyStatus: []const u8 = "" };
const Pd = struct { processingStatus: []const u8 = "" };
const Item = struct { id: []const u8 = "", status: St = .{}, processingDetails: Pd = .{} };
const List = struct { items: []const Item = &.{} };

pub fn parse(a: std.mem.Allocator, body: []const u8) ?VStatus {
    const l = std.json.parseFromSliceLeaky(List, a, body, .{ .ignore_unknown_fields = true }) catch return null;
    if (l.items.len == 0) return .{};
    const i = l.items[0];
    return .{ .found = true, .upload_status = i.status.uploadStatus, .failure_reason = i.status.failureReason, .rejection_reason = i.status.rejectionReason, .privacy = i.status.privacyStatus, .processing = i.processingDetails.processingStatus };
}

pub fn video(t: *call.Tok, id: []const u8) Res {
    const url = std.fmt.allocPrint(t.a, "{s}/videos?part=status%2CprocessingDetails&id={s}", .{ t.cx.cfg.google.api_base, id }) catch return .{ .net = error.OutOfMemory };
    return switch (t.call(http.Req{ .url = url })) {
        .ok => |r| if (parse(t.a, r.body)) |v| .{ .ok = v } else .bad_reply,
        .api => |v| .{ .api = v },
        .net => |e| .{ .net = e },
    };
}

test "parse: processed, failed with reason, rejected with reason, missing, bad json" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const ok = parse(a, "{\"items\":[{\"id\":\"v\",\"status\":{\"uploadStatus\":\"processed\",\"privacyStatus\":\"private\"},\"processingDetails\":{\"processingStatus\":\"succeeded\"},\"extra\":1}]}").?;
    try std.testing.expect(ok.found and ok.isDone() and !ok.isBad());
    try std.testing.expectEqualStrings("private", ok.privacy);
    const f = parse(a, "{\"items\":[{\"status\":{\"uploadStatus\":\"failed\",\"failureReason\":\"codec\"}}]}").?;
    try std.testing.expect(f.isBad() and std.mem.eql(u8, f.failure_reason, "codec"));
    const r = parse(a, "{\"items\":[{\"status\":{\"uploadStatus\":\"rejected\",\"rejectionReason\":\"duplicate\"}}]}").?;
    try std.testing.expect(r.isBad() and std.mem.eql(u8, r.rejection_reason, "duplicate"));
    try std.testing.expect(!parse(a, "{\"items\":[]}").?.found);
    try std.testing.expect(parse(a, "<html>") == null);
}
// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
