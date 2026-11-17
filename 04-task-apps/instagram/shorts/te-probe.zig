// ffprobe path: a fake tool script prints ffprobe-shaped JSON; POSIX only (needs a script the OS can run).
const std = @import("std");
const Io = std.Io;
const builtin = @import("builtin");
const probe = @import("rw-probe.zig");

test "ffprobe JSON is parsed (fake tool script)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const tool = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/fakeprobe.sh", .{&tmp.sub_path});
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = tool, .data = "#!/bin/sh\ncat <<'EOF'\n{\"streams\":[{\"codec_type\":\"video\",\"codec_name\":\"h264\",\"width\":1080,\"height\":1920,\"avg_frame_rate\":\"30000/1001\"},{\"codec_type\":\"audio\",\"codec_name\":\"aac\",\"channels\":2,\"sample_rate\":\"48000\"}],\"format\":{\"duration\":\"12.500000\",\"size\":\"1234\"}}\nEOF\n" });
    const ch = try std.process.run(a, io, .{ .argv = &.{ "chmod", "+x", tool } });
    _ = ch;
    const f = try probe.probe(a, io, tool, "ignored.mp4");
    try std.testing.expectEqualStrings("ffprobe", f.source);
    try std.testing.expectApproxEqAbs(@as(f64, 12.5), f.seconds.?, 0.001);
    try std.testing.expectEqual(@as(u32, 1080), f.width.?);
    try std.testing.expectApproxEqAbs(@as(f64, 29.97), f.fps.?, 0.01);
    try std.testing.expectEqualStrings("avc1", f.vcodec);
    try std.testing.expectEqualStrings("mp4a", f.acodec);
    try std.testing.expectEqual(@as(u32, 2), f.channels.?);
    try std.testing.expectEqual(@as(u32, 48000), f.rate.?);
    // a tool that fails = error, the caller then trusts the json
    try std.testing.expectError(error.ProbeFailed, probe.probe(a, io, "false", "x.mp4"));
}
