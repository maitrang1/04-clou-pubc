// =====================================================================
// Des: One authenticated Google call with its answer sorted - ok, an API verdict (class + reason), or a network error - and a single automatic token refresh when Google says 401
// Flo: add Bearer token > send > 2xx = ok | else classify > on 401 refresh the access token once and send again
// Cre: 2026-11-15                          - | Mod: 2026-11-15
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: Ctx, Req (method, url, body)
// Out: Out {ok Resp | api Verdict | net error}
// Run: not run directly - imported by every ap-* client and cm-publish
// =====================================================================
const std = @import("std");
const ctx_mod = @import("co-ctx.zig");
const http = @import("co-http.zig");
const net = @import("co-net.zig");
const auth = @import("ap-auth.zig");
const ap_err = @import("ap-err.zig");

pub const Out = union(enum) { ok: net.Resp, api: ap_err.Verdict, net: anyerror };

pub const Tok = struct {
    cx: *const ctx_mod.Ctx,
    a: std.mem.Allocator,
    token: []const u8,
    refreshed: bool = false,

    pub fn init(cx: *const ctx_mod.Ctx, a: std.mem.Allocator) auth.Err!Tok {
        return .{ .cx = cx, .a = a, .token = try auth.accessToken(cx, a) };
    }

    fn once(self: *Tok, req: http.Req) Out {
        var r = req;
        r.token = self.token;
        const resp = http.send(self.cx, self.a, r) catch |e| return .{ .net = e };
        // 308 Resume Incomplete is a normal answer of the resumable protocol
        if ((resp.status >= 200 and resp.status < 300) or resp.status == 308) {
            self.refreshed = false; // a later 401 may refresh again
            return .{ .ok = resp };
        }
        var v = ap_err.classify(self.a, resp.status, resp.body);
        v.retry_after_s = resp.retry_after_s;
        return .{ .api = v };
    }

    // get a new access token now (after a 401 that call() could not handle itself)
    pub fn forceRefresh(self: *Tok) bool {
        self.token = auth.accessToken(self.cx, self.a) catch return false;
        return true;
    }

    // with one refresh on 401
    pub fn call(self: *Tok, req: http.Req) Out {
        const out = self.once(req);
        if (out == .api and out.api.class == .unauth and !self.refreshed) {
            self.refreshed = true;
            self.token = auth.accessToken(self.cx, self.a) catch return out;
            return self.once(req);
        }
        return out;
    }

    // for byte uploads: a 401 after bytes went out must not silently resend
    pub fn callOnce(self: *Tok, req: http.Req) Out {
        return self.once(req);
    }
};
// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
