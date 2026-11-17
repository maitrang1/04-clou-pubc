// resolve only: GET /profiles/{id}/videos newest first, created_after a given time; follows the opaque `next` link (never builds it), at most `max_pages` pages.
const std = @import("std");
const Ctx = @import("co-ctx.zig").Ctx;
const call = @import("ap-call.zig");
const js = @import("ap-json.zig");
const st = @import("ap-status.zig");
const util = @import("co-util.zig");

const CF = .{ .max_pages = 5, .page_size = 20 };
const fields = "video_id,title,created_at,is_published,processing,video_url,source";

pub fn list(cx: *const Ctx, a: std.mem.Allocator, tok: []const u8, profile: []const u8, after_ms: i64) call.Out([]const st.Status) {
    const oomf: call.Out([]const st.Status) = .{ .fail = .{ .info = .{ .class = .failed, .msg = "out of memory" } } };
    if (!call.idOk(profile)) return .{ .fail = .{ .info = .{ .class = .failed, .msg = "profile id has odd characters" } } };
    const iso = util.isoUtc(a, @max(0, after_ms)) catch return oomf;
    const first = std.fmt.allocPrint(a, "profiles/{s}/videos?sort=-created_at&page_size={d}&created_after={s}&fields={s}", .{ profile, CF.page_size, iso, fields }) catch return oomf;
    var url: []const u8 = call.apiUrl(cx, a, first) catch return oomf;
    var out: std.ArrayList(st.Status) = .empty;
    var page: u32 = 0;
    while (page < CF.max_pages) : (page += 1) {
        switch (call.call(cx, a, .{ .url = url, .token = tok })) {
            .fail => |f| return .{ .fail = f },
            .ok => |ok| {
                const root = js.parse(a, ok.body) orelse return .{ .fail = .{ .info = .{ .class = .retry, .msg = "list reply unreadable" }, .body = ok.body } };
                if (js.obj(root, "list")) |items| if (items == .array) for (items.array.items) |it| out.append(a, st.parseOne(a, it)) catch return oomf;
                const nx = js.str(root, "next");
                if (nx.len == 0) break;
                url = if (std.mem.startsWith(u8, nx, "http")) nx else call.apiUrl(cx, a, std.mem.trimStart(u8, nx, "/")) catch return oomf;
            },
        }
    }
    return .{ .ok = out.items };
}
