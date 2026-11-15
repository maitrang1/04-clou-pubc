// URL guard: https:443 only, allowlist, no IP literals/userinfo, resolved IP must be public and is PINNED (connect to it, never re-resolve).
// Redaction helpers keep keys/tokens out of logs.
const std = @import("std");
const Io = std.Io;

pub const GuardErr = error{ TooLong, BadChars, Scheme, Userinfo, Port, IpLiteral, BadHost, NotAllowed, PrivateIp, DnsFail, OutOfMemory };

pub const Target = struct { host: []const u8, port: u16, tls: bool, path: []const u8, loopback: bool = false };

pub const Opts = struct {
    allow_hosts: []const []const u8,
    mock: bool = false, // build option: loopback http allowed
    any_host: bool = false, // cust webhook urls: skip the allowlist, keep every other check
};

fn isLoopbackName(h: []const u8) bool {
    return std.mem.eql(u8, h, "127.0.0.1") or std.mem.eql(u8, h, "localhost");
}

fn labelsOk(host: []const u8) bool {
    if (host.len == 0 or host.len > 253) return false;
    var it = std.mem.splitScalar(u8, host, '.');
    var n: usize = 0;
    while (it.next()) |l| : (n += 1) {
        if (l.len == 0 or l.len > 63) return false;
        if (l[0] == '-' or l[l.len - 1] == '-') return false;
        for (l) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-')) return false;
    }
    return n >= 2;
}

// 1.2.3.4, 0x7f.1, 2130706433, 017700000001: last label numeric or 0x-ish = an IP in disguise
fn looksNumeric(host: []const u8) bool {
    const dot = std.mem.lastIndexOfScalar(u8, host, '.');
    const last = if (dot) |d| host[d + 1 ..] else host;
    if (last.len == 0) return false;
    if (std.mem.startsWith(u8, last, "0x") or std.mem.startsWith(u8, last, "0X")) return true;
    for (last) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

fn allowed(host: []const u8, list: []const []const u8) bool {
    for (list) |a| {
        if (std.mem.startsWith(u8, a, "*.")) {
            const suf = a[1..];
            if (host.len > suf.len and std.ascii.eqlIgnoreCase(host[host.len - suf.len ..], suf)) return true;
        } else if (std.ascii.eqlIgnoreCase(host, a)) return true;
    }
    return false;
}

// Parse + validate. Host is lowercased into `arena`. No network.
pub fn parseUrl(arena: std.mem.Allocator, url: []const u8, o: Opts) GuardErr!Target {
    if (url.len > 2048) return GuardErr.TooLong;
    for (url) |c| if (c < 0x21 or c > 0x7e or c == '\\') return GuardErr.BadChars;
    var rest: []const u8 = undefined;
    var tls = true;
    if (std.ascii.startsWithIgnoreCase(url, "https://")) {
        rest = url[8..];
    } else if (o.mock and std.ascii.startsWithIgnoreCase(url, "http://")) {
        rest = url[7..];
        tls = false;
    } else return GuardErr.Scheme;
    const end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    const auth = rest[0..end];
    var tail = rest[end..];
    if (std.mem.indexOfScalar(u8, auth, '@') != null) return GuardErr.Userinfo;
    if (std.mem.indexOfScalar(u8, auth, '[') != null) return GuardErr.IpLiteral;
    var host = auth;
    var port: u16 = 443;
    var has_port = false;
    if (std.mem.lastIndexOfScalar(u8, auth, ':')) |c| {
        host = auth[0..c];
        port = std.fmt.parseInt(u16, auth[c + 1 ..], 10) catch return GuardErr.Port;
        has_port = true;
    }
    const lower = try arena.dupe(u8, host);
    for (lower) |*ch| ch.* = std.ascii.toLower(ch.*);
    const loop = o.mock and isLoopbackName(lower);
    if (loop) {
        if (!tls and port == 0) return GuardErr.Port;
    } else {
        if (looksNumeric(lower)) return GuardErr.IpLiteral;
        if (has_port and port != 443) return GuardErr.Port;
        if (!tls) return GuardErr.Scheme;
        if (!labelsOk(lower)) return GuardErr.BadHost;
        if (!o.any_host and !allowed(lower, o.allow_hosts)) return GuardErr.NotAllowed;
    }
    if (std.mem.indexOfScalar(u8, tail, '#')) |h| tail = tail[0..h];
    if (tail.len == 0 or tail[0] == '?') {
        tail = try std.fmt.allocPrint(arena, "/{s}", .{tail});
    }
    if (std.ascii.indexOfIgnoreCase(tail, "%00") != null) return GuardErr.BadChars;
    return .{ .host = lower, .port = port, .tls = tls, .path = try arena.dupe(u8, tail), .loopback = loop };
}

pub fn ip4Public(b: [4]u8) bool {
    const a = b[0];
    const c = b[1];
    if (a == 0 or a == 10 or a == 127) return false;
    if (a == 100 and c >= 64 and c <= 127) return false;
    if (a == 169 and c == 254) return false;
    if (a == 172 and c >= 16 and c <= 31) return false;
    if (a == 192 and c == 0 and b[2] == 0) return false;
    if (a == 192 and c == 0 and b[2] == 2) return false;
    if (a == 192 and c == 88 and b[2] == 99) return false;
    if (a == 192 and c == 168) return false;
    if (a == 198 and (c == 18 or c == 19)) return false;
    if (a == 198 and c == 51 and b[2] == 100) return false;
    if (a == 203 and c == 0 and b[2] == 113) return false;
    if (a >= 224) return false;
    return true;
}

pub fn ip6Public(b: [16]u8) bool {
    var zero = true;
    for (b[0..15]) |x| {
        if (x != 0) zero = false;
    }
    if (zero and (b[15] == 0 or b[15] == 1)) return false; // :: and ::1
    if ((b[0] & 0xfe) == 0xfc) return false; // fc00::/7
    if (b[0] == 0xfe and (b[1] & 0xc0) == 0x80) return false; // fe80::/10
    if (b[0] == 0xff) return false; // multicast
    if (b[0] == 0x20 and b[1] == 0x01 and b[2] == 0x0d and b[3] == 0xb8) return false; // doc
    if (b[0] == 0x20 and b[1] == 0x02) return false; // 6to4
    if (b[0] == 0x01 and b[1] == 0 and b[2] == 0 and b[3] == 0 and b[4] == 0 and b[5] == 0 and b[6] == 0 and b[7] == 0) return false; // discard
    var mapped = true;
    for (b[0..10]) |x| {
        if (x != 0) mapped = false;
    }
    if (mapped and b[10] == 0xff and b[11] == 0xff) return ip4Public(.{ b[12], b[13], b[14], b[15] });
    if (b[0] == 0x00 and b[1] == 0x64 and b[2] == 0xff and b[3] == 0x9b) return false; // NAT64
    return true;
}

pub fn ipPublic(a: Io.net.IpAddress) bool {
    return switch (a) {
        .ip4 => |x| ip4Public(x.bytes),
        .ip6 => |x| ip6Public(x.bytes),
    };
}

pub const Resolver = struct {
    ctx: ?*anyopaque = null,
    func: *const fn (ctx: ?*anyopaque, io: Io, host: []const u8, port: u16, out: []Io.net.IpAddress) anyerror!usize = realResolve,
};

fn realResolve(_: ?*anyopaque, io: Io, host: []const u8, port: u16, out: []Io.net.IpAddress) anyerror!usize {
    const hn = try Io.net.HostName.init(host);
    var buf: [32]Io.net.HostName.LookupResult = undefined;
    var q: Io.Queue(Io.net.HostName.LookupResult) = .init(&buf);
    try hn.lookup(io, &q, .{ .port = port });
    var n: usize = 0;
    while (q.getOne(io)) |r| {
        switch (r) {
            .address => |a| if (n < out.len) {
                out[n] = a;
                n += 1;
            },
            .canonical_name => {},
        }
    } else |_| {}
    return n;
}

// Resolve and require EVERY answer to be public (a mixed answer = rebinding trick). Returns the first as the pin.
pub fn pin(io: Io, rs: Resolver, t: Target) GuardErr!Io.net.IpAddress {
    if (t.loopback) return Io.net.IpAddress.parse("127.0.0.1", t.port) catch GuardErr.DnsFail;
    var out: [16]Io.net.IpAddress = undefined;
    const n = rs.func(rs.ctx, io, t.host, t.port, &out) catch return GuardErr.DnsFail;
    if (n == 0) return GuardErr.DnsFail;
    for (out[0..n]) |a| if (!ipPublic(a)) return GuardErr.PrivateIp;
    return out[0];
}

// ---- redaction: logs never carry query strings or secrets ----
pub fn redactUrl(alloc: std.mem.Allocator, url: []const u8) ![]u8 {
    var s = url;
    var scheme: []const u8 = "";
    if (std.mem.indexOf(u8, s, "://")) |i| {
        const after = s[i + 3 ..];
        if (std.mem.indexOfScalar(u8, after, '@')) |at| {
            const slash = std.mem.indexOfScalar(u8, after, '/') orelse after.len;
            if (at < slash) {
                scheme = s[0 .. i + 3];
                s = after[at + 1 ..];
            }
        }
    }
    if (std.mem.indexOfScalar(u8, s, '?')) |q| return std.fmt.allocPrint(alloc, "{s}{s}?...", .{ scheme, s[0..q] });
    return std.fmt.allocPrint(alloc, "{s}{s}", .{ scheme, s });
}

const secret_keys = [_][]const u8{ "api_key=", "apikey=", "token=", "key=", "access_token=", "secret=", "authorization: bearer ", "authorization: oauth ", "\"access_token\":\"", "\"token\":\"", "\"input_token\":\"", "\"client_secret\":\"", "input_token=", "fb_exchange_token=", "client_secret=", "x-api-key: " };

// Replace the value after a secret-ish key with ***. Case-insensitive; value ends at & space quote newline.
pub fn redactText(alloc: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    outer: while (i < text.len) {
        for (secret_keys) |k| {
            if (i + k.len <= text.len and std.ascii.eqlIgnoreCase(text[i .. i + k.len], k)) {
                try out.appendSlice(alloc, text[i .. i + k.len]);
                i += k.len;
                try out.appendSlice(alloc, "***");
                while (i < text.len and text[i] != '&' and text[i] != ' ' and text[i] != '"' and text[i] != '\'' and text[i] != '\n' and text[i] != '\r') i += 1;
                continue :outer;
            }
        }
        try out.append(alloc, text[i]);
        i += 1;
    }
    return out.toOwnedSlice(alloc);
}

// ---- tests ----
const hosts = [_][]const u8{ "graph.facebook.com", "rupload.facebook.com", "*.facebook.com" };

test "only https on allowed Pinterest hosts passes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const o = Opts{ .allow_hosts = &hosts };
    try std.testing.expect((try parseUrl(a, "https://graph.facebook.com/v27.0/1/video_reels", o)).tls);
    _ = try parseUrl(a, "https://rupload.facebook.com/video-upload/123", o);
    _ = try parseUrl(a, "https://GRAPH.facebook.com/x", o);
    try std.testing.expectError(GuardErr.Scheme, parseUrl(a, "http://graph.facebook.com/x", o));
    try std.testing.expectError(GuardErr.NotAllowed, parseUrl(a, "https://evil.example.com/x", o));
    try std.testing.expectError(GuardErr.NotAllowed, parseUrl(a, "https://graph.facebook.com.evil.com/x", o));
    try std.testing.expectError(GuardErr.Userinfo, parseUrl(a, "https://graph.facebook.com@evil.com/x", o));
    try std.testing.expectError(GuardErr.IpLiteral, parseUrl(a, "https://127.0.0.1/x", o));
    try std.testing.expectError(GuardErr.IpLiteral, parseUrl(a, "https://2130706433/x", o));
    try std.testing.expectError(GuardErr.Port, parseUrl(a, "https://graph.facebook.com:8443/x", o));
    try std.testing.expectError(GuardErr.Scheme, parseUrl(a, "file:///etc/passwd", o));
    try std.testing.expectError(GuardErr.BadChars, parseUrl(a, "https://graph.facebook.com/a b", o));
}

test "loopback http only in mock builds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    _ = try parseUrl(a, "http://127.0.0.1:9/x", .{ .allow_hosts = &hosts, .mock = true });
    try std.testing.expectError(GuardErr.Scheme, parseUrl(a, "http://127.0.0.1:9/x", .{ .allow_hosts = &hosts }));
}

test "private addresses are refused at pin time" {
    try std.testing.expect(!ip4Public(.{ 10, 0, 0, 1 }));
    try std.testing.expect(!ip4Public(.{ 127, 0, 0, 1 }));
    try std.testing.expect(!ip4Public(.{ 169, 254, 169, 254 }));
    try std.testing.expect(!ip4Public(.{ 192, 168, 1, 1 }));
    try std.testing.expect(ip4Public(.{ 157, 240, 1, 35 }));
}

test "redaction strips secrets and queries" {
    const a = std.testing.allocator;
    const u = try redactUrl(a, "https://graph.facebook.com/debug_token?input_token=ABC");
    defer a.free(u);
    try std.testing.expectEqualStrings("https://graph.facebook.com/debug_token?...", u);
    const t = try redactText(a, "x Authorization: OAuth SECRETVAL y");
    defer a.free(t);
    try std.testing.expect(std.mem.indexOf(u8, t, "SECRETVAL") == null);
}
