// Caption builder: hook + description + hashtags + AI notice, cut to the limit at a word boundary. The AI notice is never the part that gets cut. Nothing is invented: only the pair's own text.
const std = @import("std");

const guard = @import("co-guard.zig");

pub const Err = error{ NoNotice, NoticeTooLong, OutOfMemory };
pub const Caption = struct { description: []const u8, title: ?[]const u8 };
pub const In = struct { hooks: []const []const u8 = &.{}, description: []const u8 = "", hashtags: []const []const u8 = &.{}, ai_notice: []const u8 = "", brand: []const u8 = "", model: []const u8 = "", year: u32 = 0, title: []const u8 = "" };
pub const Lim = struct { desc_max: u32, title_max: u32, tags_max: u32, notice_required: bool, title_pattern: []const u8 = "{brand} {model} {year}. {hook}", title_case: bool = true };

// ---- Title Case (Vietnamese safe): a word that already has a capital (SUV, VF3, CR-V, VinFast) stays as written; any other word gets a capital first letter ----
fn isUpperCp(cp: u21) bool {
    return (cp >= 'A' and cp <= 'Z') or (cp >= 0xC0 and cp <= 0xDE and cp != 0xD7) or (cp >= 0x100 and cp <= 0x137 and cp % 2 == 0) or (cp >= 0x168 and cp <= 0x177 and cp % 2 == 0) or cp == 0x1A0 or cp == 0x1AF or (cp >= 0x1EA0 and cp <= 0x1EF8 and cp % 2 == 0);
}

fn upperCp(cp: u21) u21 {
    if (cp >= 'a' and cp <= 'z') return cp - 32;
    if (cp >= 0xE0 and cp <= 0xFE and cp != 0xF7) return cp - 32;
    if (((cp >= 0x100 and cp <= 0x137) or (cp >= 0x168 and cp <= 0x177) or (cp >= 0x1EA0 and cp <= 0x1EF9)) and cp % 2 == 1) return cp - 1;
    if (cp == 0x1A1) return 0x1A0;
    if (cp == 0x1B0) return 0x1AF;
    return cp;
}

const units = [_][]const u8{ "km", "kg", "cc", "kw", "hp", "mm", "cm", "l" };
const number_words = [_][]const u8{ "không", "một", "hai", "ba", "bốn", "sáu", "bảy", "tám", "chín", "mười", "mươi", "trăm", "nghìn", "ngàn", "triệu", "tỷ", "lăm" };

fn core(w: []const u8) []const u8 {
    return std.mem.trim(u8, w, ",.;:!?()\"");
}

fn hasDigit(w: []const u8) bool {
    for (w) |c| if (c >= '0' and c <= '9') return true;
    return false;
}

fn lowerEq(w: []const u8, list: []const []const u8) bool {
    var buf: [32]u8 = undefined;
    if (w.len == 0 or w.len > buf.len) return false;
    const lw = std.ascii.lowerString(&buf, w);
    for (list) |x| if (std.mem.eql(u8, lw, x)) return true;
    return false;
}

// how many spelled-out number words a hook has ("Ba mươi hai nghìn km" = 4); 2 or more = voice-over text, not a title
pub fn spelledNumbers(s: []const u8) usize {
    var n: usize = 0;
    var it = std.mem.tokenizeScalar(u8, s, ' ');
    while (it.next()) |w| if (lowerEq(core(w), &number_words)) {
        n += 1;
    };
    return n;
}

// the first hook that reads like a title (no spelled-out number); else the first hook
pub fn pickHook(hooks: []const []const u8) []const u8 {
    var first: []const u8 = "";
    for (hooks) |h| {
        const t = std.mem.trim(u8, h, " \r\n\t");
        if (t.len == 0) continue;
        if (first.len == 0) first = t;
        if (spelledNumbers(t) < 2) return t;
    }
    return first;
}

pub fn titleCase(a: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var words = std.mem.splitScalar(u8, s, ' ');
    var first = true;
    var prev_digit = false;
    while (words.next()) |w| {
        if (!first) try out.append(a, ' ');
        first = false;
        defer prev_digit = hasDigit(w);
        if (w.len == 0) continue;
        if (prev_digit and lowerEq(core(w), &units)) { // 30.000 km stays "km"
            for (w) |c| try out.append(a, std.ascii.toLower(c));
            continue;
        }
        var keep = !std.unicode.utf8ValidateSlice(w);
        if (!keep) {
            var v = std.unicode.Utf8View.initUnchecked(w).iterator();
            while (v.nextCodepoint()) |cp| if (isUpperCp(cp)) {
                keep = true;
                break;
            };
        }
        if (keep) {
            try out.appendSlice(a, w);
            continue;
        }
        const n = std.unicode.utf8ByteSequenceLength(w[0]) catch 1;
        const cp = std.unicode.utf8Decode(w[0..@min(n, w.len)]) catch {
            try out.appendSlice(a, w);
            continue;
        };
        var buf: [4]u8 = undefined;
        const k = std.unicode.utf8Encode(upperCp(cp), &buf) catch 0;
        try out.appendSlice(a, buf[0..k]);
        try out.appendSlice(a, w[@min(n, w.len)..]);
    }
    return out.items;
}

// "{brand} {model} {year}. {hook}": the name part is never cut, only the hook is trimmed to title_max. Missing name data = the hook alone.
fn makeTitle(a: std.mem.Allocator, in: In, hook: []const u8, lim: Lim) !?[]const u8 {
    const brand = std.mem.trim(u8, in.brand, " \r\n\t");
    const model = std.mem.trim(u8, in.model, " \r\n\t");
    const named = brand.len > 0 and model.len > 0 and in.year > 0;
    if (hook.len == 0) return null;
    const cased = if (lim.title_case) try titleCase(a, hook) else hook;
    if (!named) return cut(cased, lim.title_max);
    const at = std.mem.indexOf(u8, lim.title_pattern, "{hook}") orelse return cut(cased, lim.title_max);
    var year_buf: [12]u8 = undefined;
    const year = std.fmt.bufPrint(&year_buf, "{d}", .{in.year}) catch "";
    const fill = struct {
        fn run(al: std.mem.Allocator, pat: []const u8, b: []const u8, m: []const u8, y: []const u8) ![]u8 {
            var o: std.ArrayList(u8) = .empty;
            var i: usize = 0;
            while (i < pat.len) {
                if (std.mem.startsWith(u8, pat[i..], "{brand}")) {
                    try o.appendSlice(al, b);
                    i += 7;
                } else if (std.mem.startsWith(u8, pat[i..], "{model}")) {
                    try o.appendSlice(al, m);
                    i += 7;
                } else if (std.mem.startsWith(u8, pat[i..], "{year}")) {
                    try o.appendSlice(al, y);
                    i += 6;
                } else {
                    try o.append(al, pat[i]);
                    i += 1;
                }
            }
            return o.items;
        }
    }.run;
    const before_raw = try fill(a, lim.title_pattern[0..at], brand, model, year);
    const after_raw = try fill(a, lim.title_pattern[at + 6 ..], brand, model, year);
    const before = if (lim.title_case) try titleCase(a, before_raw) else before_raw;
    const after = if (lim.title_case) try titleCase(a, after_raw) else after_raw;
    const fixed = before.len + after.len;
    if (fixed >= lim.title_max) return cut(before, lim.title_max);
    const room = lim.title_max - fixed;
    const h = cut(cased, room);
    if (h.len == 0) return std.mem.trimEnd(u8, before, " .,;:-");
    return try std.fmt.allocPrint(a, "{s}{s}{s}", .{ before, h, after });
}

// cut at the last space within max bytes (or at a UTF-8 boundary when there is none)
pub fn cut(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var e = max;
    while (e > 0 and (s[e] & 0xC0) == 0x80) e -= 1; // never inside a multi-byte char
    const head = s[0..e];
    if (e < s.len and s[e] == ' ') return std.mem.trimEnd(u8, head, " \n,.;:-"); // the cut falls exactly on a word end
    if (std.mem.lastIndexOfScalar(u8, head, ' ')) |sp| if (sp > 0) return std.mem.trimEnd(u8, head[0..sp], " \n,.;:-");
    return head;
}

// text from outside (Facebook messages) that may land in the ledger or output: secrets removed, cut on a character boundary
pub fn safeNote(a: std.mem.Allocator, s: []const u8, max: usize) []const u8 {
    const red = guard.redactText(a, s) catch return "(note dropped)";
    return cut(red, max);
}

fn tag(a: std.mem.Allocator, raw: []const u8) !?[]u8 {
    var o: std.ArrayList(u8) = .empty;
    try o.append(a, '#');
    for (raw) |c| if (c != '#' and c != ' ' and c != '\n' and c != '\r' and c != '\t') try o.append(a, c);
    if (o.items.len == 1) return null;
    return o.items;
}

pub fn build(a: std.mem.Allocator, in: In, lim: Lim) Err!Caption {
    const notice = std.mem.trim(u8, in.ai_notice, " \r\n\t");
    if (notice.len == 0 and lim.notice_required) return Err.NoNotice;
    var body: std.ArrayList(u8) = .empty;
    const hook = if (in.hooks.len > 0) std.mem.trim(u8, in.hooks[0], " \r\n\t") else "";
    const title_hook = if (std.mem.trim(u8, in.title, " \r\n\t").len > 0) std.mem.trim(u8, in.title, " \r\n\t") else pickHook(in.hooks);
    const desc = std.mem.trim(u8, in.description, " \r\n\t");
    if (hook.len > 0) body.appendSlice(a, hook) catch return Err.OutOfMemory;
    if (desc.len > 0) {
        if (body.items.len > 0) body.appendSlice(a, "\n\n") catch return Err.OutOfMemory;
        body.appendSlice(a, desc) catch return Err.OutOfMemory;
    }
    var tags: std.ArrayList(u8) = .empty;
    var nt: u32 = 0;
    for (in.hashtags) |h| {
        if (nt >= lim.tags_max) break;
        const t = (tag(a, h) catch return Err.OutOfMemory) orelse continue;
        if (tags.items.len > 0) tags.append(a, ' ') catch return Err.OutOfMemory;
        tags.appendSlice(a, t) catch return Err.OutOfMemory;
        nt += 1;
    }
    if (tags.items.len > 0) {
        if (body.items.len > 0) body.appendSlice(a, "\n\n") catch return Err.OutOfMemory;
        body.appendSlice(a, tags.items) catch return Err.OutOfMemory;
    }
    var out: []const u8 = body.items;
    if (notice.len > 0) {
        const sep: usize = 2;
        if (notice.len + sep > lim.desc_max and out.len > 0) return Err.NoticeTooLong;
        if (notice.len > lim.desc_max) return Err.NoticeTooLong;
        const budget = if (lim.desc_max > notice.len + sep) lim.desc_max - notice.len - sep else 0;
        const head = std.mem.trimEnd(u8, cut(out, budget), "\n ");
        out = if (head.len > 0) std.fmt.allocPrint(a, "{s}\n\n{s}", .{ head, notice }) catch return Err.OutOfMemory else notice;
    } else out = cut(out, lim.desc_max);
    const title: ?[]const u8 = makeTitle(a, in, title_hook, lim) catch return Err.OutOfMemory;
    return .{ .description = out, .title = title };
}

const L = Lim{ .desc_max = 200, .title_max = 30, .tags_max = 3, .notice_required = true, .title_case = false };

test "joins hook, description, tags, notice in order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const c = try build(arena.allocator(), .{ .hooks = &.{"Big hook"}, .description = "Body text.", .hashtags = &.{ "cars", "#fun", "has space", "dropped" }, .ai_notice = "Made with AI." }, L);
    try std.testing.expectEqualStrings("Big hook\n\nBody text.\n\n#cars #fun #hasspace\n\nMade with AI.", c.description);
    try std.testing.expectEqualStrings("Big hook", c.title.?);
}

test "long text is cut at a word, the notice survives whole" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const long = "word " ** 100;
    const c = try build(arena.allocator(), .{ .description = long, .ai_notice = "AI NOTICE END" }, L);
    try std.testing.expect(c.description.len <= 200);
    try std.testing.expect(std.mem.endsWith(u8, c.description, "AI NOTICE END"));
    try std.testing.expect(std.mem.indexOf(u8, c.description, "wor\n") == null);
}

test "missing notice refused, huge notice refused, no notice allowed when not required" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectError(Err.NoNotice, build(a, .{ .description = "x" }, L));
    try std.testing.expectError(Err.NoNotice, build(a, .{ .description = "x", .ai_notice = "  " }, L));
    try std.testing.expectError(Err.NoticeTooLong, build(a, .{ .description = "x", .ai_notice = "n" ** 250 }, L));
    var l2 = L;
    l2.notice_required = false;
    const c = try build(a, .{ .description = "plain" }, l2);
    try std.testing.expectEqualStrings("plain", c.description);
}

test "never cuts inside a multi-byte character" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const c = try build(arena.allocator(), .{ .description = "é" ** 300, .ai_notice = "AI" }, L);
    try std.testing.expect(std.unicode.utf8ValidateSlice(c.description));
    try std.testing.expect(c.description.len <= 200);
}

test "only the pair's own words appear" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const c = try build(arena.allocator(), .{ .description = "just this", .ai_notice = "AI" }, L);
    try std.testing.expectEqualStrings("just this\n\nAI", c.description);
}

test "title: name, then the hook, Title Case, acronyms and brand spellings kept" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var l = L;
    l.title_max = 100;
    l.title_case = true;
    const c1 = try build(a, .{ .hooks = &.{"SUV bảy chỗ máy dầu nhập khẩu"}, .brand = "Ford", .model = "Everest", .year = 2022, .ai_notice = "AI" }, l);
    try std.testing.expectEqualStrings("Ford Everest 2022. SUV Bảy Chỗ Máy Dầu Nhập Khẩu", c1.title.?);
    const c2 = try build(a, .{ .hooks = &.{"VF3 chạy điện, odo 30.000 km"}, .brand = "VinFast", .model = "VF3", .year = 2024, .ai_notice = "AI" }, l);
    try std.testing.expectEqualStrings("VinFast VF3 2024. VF3 Chạy Điện, Odo 30.000 km", c2.title.?);
    const c3 = try build(a, .{ .hooks = &.{"ba mươi hai nghìn km, đời 2021"}, .brand = "Honda", .model = "CR-V", .year = 2021, .ai_notice = "AI" }, l);
    try std.testing.expectEqualStrings("Honda CR-V 2021. Ba Mươi Hai Nghìn Km, Đời 2021", c3.title.?);
    const c4 = try build(a, .{ .hooks = &.{"ưu đãi ơn ăn ếch"}, .ai_notice = "AI" }, l);
    try std.testing.expectEqualStrings("Ưu Đãi Ơn Ăn Ếch", c4.title.?);
}

test "title: the name is never cut, the hook is trimmed; missing name = hook alone; case can be off" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var l = L;
    l.title_case = true;
    l.title_max = 30;
    const c = try build(a, .{ .hooks = &.{"một hai ba bốn năm sáu bảy tám chín mười"}, .brand = "Ford", .model = "Everest", .year = 2022, .ai_notice = "AI" }, l);
    try std.testing.expect(std.mem.startsWith(u8, c.title.?, "Ford Everest 2022. "));
    try std.testing.expect(c.title.?.len <= 30);
    try std.testing.expect(std.unicode.utf8ValidateSlice(c.title.?));
    const tiny = try build(a, .{ .hooks = &.{"hook"}, .brand = "Ford", .model = "Everest", .year = 2022, .ai_notice = "AI" }, .{ .desc_max = 200, .title_max = 12, .tags_max = 3, .notice_required = true });
    try std.testing.expectEqualStrings("Ford Everest", tiny.title.?);
    const none = try build(a, .{ .hooks = &.{"chỉ hook"}, .brand = "Ford", .ai_notice = "AI" }, l);
    try std.testing.expectEqualStrings("Chỉ Hook", none.title.?);
    l.title_case = false;
    const raw = try build(a, .{ .hooks = &.{"chỉ hook"}, .brand = "Ford", .model = "X", .year = 2020, .ai_notice = "AI" }, l);
    try std.testing.expectEqualStrings("Ford X 2020. chỉ hook", raw.title.?);
}

test "title source: own title first, else the first hook without spelled-out numbers; units stay lowercase" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var l = L;
    l.title_max = 100;
    l.title_case = true;
    const honda = try build(a, .{ .hooks = &.{ "Ba mươi hai nghìn km, đời 2021", "CR-V L 1.5Turbo nhập khẩu", "SUV năm chỗ, máy tăng áp" }, .brand = "Honda", .model = "CR-V", .year = 2021, .ai_notice = "AI" }, l);
    try std.testing.expectEqualStrings("Honda CR-V 2021. CR-V L 1.5Turbo Nhập Khẩu", honda.title.?);
    const own = try build(a, .{ .title = "32.000 km, đời 2021", .hooks = &.{"Ba mươi hai nghìn km"}, .brand = "Honda", .model = "CR-V", .year = 2021, .ai_notice = "AI" }, l);
    try std.testing.expectEqualStrings("Honda CR-V 2021. 32.000 km, Đời 2021", own.title.?);
    const odo = try build(a, .{ .hooks = &.{"Lux SA2.0 đỏ nóc vàng, odo 20000 km"}, .brand = "VinFast", .model = "Lux SA2.0", .year = 2025, .ai_notice = "AI" }, l);
    try std.testing.expectEqualStrings("VinFast Lux SA2.0 2025. Lux SA2.0 Đỏ Nóc Vàng, Odo 20000 km", odo.title.?);
    // every hook spelled out: the first one is used, nothing is invented
    const all = try build(a, .{ .hooks = &.{ "Hai trăm năm mươi triệu", "Ba trăm triệu" }, .ai_notice = "AI" }, l);
    try std.testing.expectEqualStrings("Hai Trăm Năm Mươi Triệu", all.title.?);
    try std.testing.expectEqual(@as(usize, 1), spelledNumbers("SUV bảy chỗ máy dầu"));
    try std.testing.expectEqual(@as(usize, 0), spelledNumbers("SUV năm chỗ, máy tăng áp"));
}
