// =====================================================================
// Des: Sends the video bytes to the upload session as one streamed PUT, asks the session how much arrived, and resumes from the right byte - and says how many bytes left when an answer is lost, so a lost answer after the last byte is never a blind retry
// Flo: PUT file range (Content-Range when resuming) > 201 + id = done | 308 + Range = incomplete | 404/410 = expired | else verdict | lost = net with sent count; ask = empty PUT with bytes */size
// Cre: 2026-11-15                          - | Mod: 2026-11-15
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: Tok, session uri, file path, total size, start offset
// Out: Put {done id | incomplete next byte | expired | api Verdict | net {sent} | file_error | bad reply}
// Run: not run directly - imported by cm-send, cm-publish, cm-resolve
// =====================================================================
const std = @import("std");
const call = @import("ap-call.zig");
const http = @import("co-http.zig");
const net = @import("co-net.zig");
const ap_err = @import("ap-err.zig");

pub const Put = union(enum) {
    done: []const u8, // video id
    incomplete: Next, // the session wants more, starting at this byte
    expired,
    api: ap_err.Verdict,
    net: Lost,
    file_error, // the source file could not be read: nothing wrong at YouTube
    bad_reply, // an answer that does not make sense (e.g. a Range beyond the file)
};

pub const Next = struct { byte: u64, retry_after_s: u32 = 0 };

// sent = body bytes that left this machine before the answer was lost (> 0 means the video may be on YouTube)
pub const Lost = struct { sent: u64 };

const VideoId = struct { id: []const u8 = "" };

// "bytes=0-999" -> 1000 ; none -> 0 ; an absurd number saturates (the caller checks it against the file size)
pub fn nextFromRange(range: []const u8) u64 {
    const dash = std.mem.lastIndexOfScalar(u8, range, '-') orelse return 0;
    const n = std.fmt.parseInt(u64, std.mem.trim(u8, range[dash + 1 ..], " "), 10) catch return 0;
    return std.math.add(u64, n, 1) catch std.math.maxInt(u64);
}

fn parseOut(t: *call.Tok, out: call.Out, sent: ?*std.atomic.Value(u64), size: u64) Put {
    switch (out) {
        .ok => |r| {
            if (r.status == 308) {
                const next = nextFromRange(r.range);
                // a Range past the end (or exactly the end, yet not finished) cannot be resumed from
                if (next >= size) return .bad_reply;
                return .{ .incomplete = .{ .byte = next, .retry_after_s = r.retry_after_s } };
            }
            const v = std.json.parseFromSliceLeaky(VideoId, t.a, r.body, .{ .ignore_unknown_fields = true }) catch return .bad_reply;
            if (v.id.len == 0) return .bad_reply;
            return .{ .done = v.id };
        },
        .api => |v| {
            if (v.status == 404 or v.status == 410) return .expired;
            if (v.class == .unauth) {
                // the token ran out mid-upload: get a new one, then let the caller ask the session
                _ = t.forceRefresh();
                return .{ .net = .{ .sent = if (sent) |p| p.load(.acquire) else 0 } };
            }
            return .{ .api = v };
        },
        .net => |e| {
            if (e == error.BodyFile) return .file_error;
            return .{ .net = .{ .sent = if (sent) |p| p.load(.acquire) else 0 } };
        },
    }
}

// stream bytes [offset, size) of the file
pub fn put(t: *call.Tok, uri: []const u8, path: []const u8, size: u64, offset: u64) Put {
    const a = t.a;
    const cx = t.cx;
    if (offset >= size) return .bad_reply;
    var sent = std.atomic.Value(u64).init(0);
    const len = size - offset;
    var cr: []const u8 = "";
    if (offset > 0) cr = std.fmt.allocPrint(a, "bytes {d}-{d}/{d}", .{ offset, size - 1, size }) catch return .{ .net = .{ .sent = 0 } };
    var hs: [2]std.http.Header = undefined;
    var n: usize = 0;
    hs[n] = .{ .name = "Content-Type", .value = "video/mp4" };
    n += 1;
    if (cr.len > 0) {
        hs[n] = .{ .name = "Content-Range", .value = cr };
        n += 1;
    }
    const out = t.callOnce(.{
        .method = "PUT",
        .url = uri,
        .headers = hs[0..n],
        .body = .{ .file = .{ .path = path, .offset = offset, .len = len, .chunk = @as(usize, cx.cfg.net.chunk_kb) * 1024 } },
        .timeout_s = cx.cfg.net.upload_timeout_s,
        .sent = &sent,
    });
    return parseOut(t, out, &sent, size);
}

// ask the session: empty PUT with Content-Range bytes */size
pub fn ask(t: *call.Tok, uri: []const u8, size: u64) Put {
    const a = t.a;
    const cr = std.fmt.allocPrint(a, "bytes */{d}", .{size}) catch return .{ .net = .{ .sent = 0 } };
    const hs = [_]std.http.Header{.{ .name = "Content-Range", .value = cr }};
    const out = t.call(.{ .method = "PUT", .url = uri, .headers = &hs, .body = .none });
    return parseOut(t, out, null, size);
}

test "range header to next byte, absurd values saturate" {
    try std.testing.expectEqual(@as(u64, 1000), nextFromRange("bytes=0-999"));
    try std.testing.expectEqual(@as(u64, 1), nextFromRange("bytes=0-0"));
    try std.testing.expectEqual(@as(u64, 0), nextFromRange(""));
    try std.testing.expectEqual(@as(u64, 0), nextFromRange("garbage"));
    try std.testing.expectEqual(std.math.maxInt(u64), nextFromRange("bytes=0-18446744073709551615"));
}
// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
