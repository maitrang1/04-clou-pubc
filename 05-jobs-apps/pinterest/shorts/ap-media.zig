// Media step 1 + 3: register an upload (POST /media) and ask its status (GET /media/{id}). Upload parameters are read as data, never hard-coded.
const std = @import("std");
const Ctx = @import("co-ctx.zig").Ctx;
const call = @import("ap-call.zig");
const js = @import("ap-json.zig");

pub const Param = struct { k: []const u8, v: []const u8 };
pub const Session = struct { media_id: []const u8, upload_url: []const u8, params: []const Param };
pub const Verdict = enum { registered, processing, succeeded, failed, unknown };
pub const Status = struct { verdict: Verdict, raw: []const u8 = "" };

fn oomS() call.Out(Session) {
    return .{ .fail = .{ .info = .{ .class = .failed, .msg = "out of memory" } } };
}

// id as text: the spec says digits in a string, but a bare number is accepted too
fn idText(a: std.mem.Allocator, v: ?std.json.Value, key: []const u8) []const u8 {
    const s = js.str(v, key);
    if (s.len > 0) return s;
    const n = js.int(v, key);
    return if (n > 0) std.fmt.allocPrint(a, "{d}", .{n}) catch "" else "";
}

pub fn register(cx: *const Ctx, a: std.mem.Allocator, tok: []const u8) call.Out(Session) {
    const url = call.apiUrl(cx, a, "media") catch return oomS();
    switch (call.call(cx, a, .{ .method = "POST", .url = url, .auth = .{ .bearer = tok }, .body = "{\"media_type\":\"video\"}" })) {
        .fail => |f| return .{ .fail = f },
        .ok => |ok| {
            const v = js.parse(a, ok.body);
            const mid = idText(a, v, "media_id");
            const up = js.str(v, "upload_url");
            if (!call.idOk(mid) or up.len == 0) return .{ .fail = .{ .info = .{ .class = .failed, .msg = "register reply has no media_id/upload_url" }, .body = ok.body } };
            var ps: std.ArrayList(Param) = .empty;
            if (js.obj(v, "upload_parameters")) |o| if (o == .object) {
                var it = o.object.iterator();
                while (it.next()) |kv| if (kv.value_ptr.* == .string) ps.append(a, .{ .k = kv.key_ptr.*, .v = kv.value_ptr.string }) catch return oomS();
            };
            if (ps.items.len == 0) return .{ .fail = .{ .info = .{ .class = .failed, .msg = "register reply has no upload_parameters" }, .body = ok.body } };
            return .{ .ok = .{ .media_id = mid, .upload_url = up, .params = ps.items } };
        },
    }
}

pub fn verdictOf(s: []const u8) Verdict {
    if (std.mem.eql(u8, s, "succeeded")) return .succeeded;
    if (std.mem.eql(u8, s, "failed")) return .failed;
    if (std.mem.eql(u8, s, "processing")) return .processing;
    if (std.mem.eql(u8, s, "registered")) return .registered;
    return .unknown;
}

pub fn get(cx: *const Ctx, a: std.mem.Allocator, tok: []const u8, media_id: []const u8) call.Out(Status) {
    const oomf: call.Out(Status) = .{ .fail = .{ .info = .{ .class = .failed, .msg = "out of memory" } } };
    if (!call.idOk(media_id)) return .{ .fail = .{ .info = .{ .class = .failed, .msg = "media id must be digits" } } };
    const path = std.fmt.allocPrint(a, "media/{s}", .{media_id}) catch return oomf;
    const url = call.apiUrl(cx, a, path) catch return oomf;
    switch (call.call(cx, a, .{ .url = url, .auth = .{ .bearer = tok } })) {
        .fail => |f| return .{ .fail = f },
        .ok => |ok| {
            const v = js.parse(a, ok.body) orelse return .{ .fail = .{ .info = .{ .class = .retry, .msg = "media status reply unreadable" }, .body = ok.body } };
            return .{ .ok = .{ .verdict = verdictOf(js.str(v, "status")), .raw = ok.body } };
        },
    }
}

test "status words map, unknown stays pending" {
    try std.testing.expectEqual(Verdict.succeeded, verdictOf("succeeded"));
    try std.testing.expectEqual(Verdict.failed, verdictOf("failed"));
    try std.testing.expectEqual(Verdict.processing, verdictOf("processing"));
    try std.testing.expectEqual(Verdict.registered, verdictOf("registered"));
    try std.testing.expectEqual(Verdict.unknown, verdictOf("brand_new_word"));
    try std.testing.expectEqual(Verdict.unknown, verdictOf(""));
}
