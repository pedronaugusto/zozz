//! Behavioural tests for the log-verbosity seam (zozz_core.h): ozz's own
//! runtime writes diagnostics straight to std::cerr with no ZozzResult
//! attached, so the only way to prove zozzSetLogLevel actually reaches that
//! global is to watch for the difference it makes.
//!
//! Compiled only into the test binary: `zozzFixtureCapturedSkeletonLoadBytes`
//! below lives in the test-only `zozz-fixture` library (tests/fixture.cpp),
//! the same one `integration_test.zig` draws its synthetic assets from.

const std = @import("std");
const zozz = @import("zozz.zig");

//=============================================================================
// Fixture binding (tests/fixture.h)
//=============================================================================

extern fn zozzFixtureCapturedSkeletonLoadBytes(data: ?*const anyopaque, size: usize) usize;

/// A write-only in-memory `zozz.Stream` sink, just enough for `OArchive`. A
/// smaller copy of `archive_test.zig`'s `MemorySink`: this file only ever
/// writes, and pulling in the read side too would be dead weight here.
const Sink = struct {
    list: std.ArrayList(u8) = .empty,
    gpa: std.mem.Allocator,

    fn deinit(self: *Sink) void {
        self.list.deinit(self.gpa);
    }

    fn opened(user: ?*anyopaque) callconv(.c) c_int {
        _ = user;
        return 1;
    }

    fn write(user: ?*anyopaque, data: ?*const anyopaque, size: usize) callconv(.c) usize {
        const self: *Sink = @ptrCast(@alignCast(user orelse return 0));
        const bytes: [*]const u8 = @ptrCast(data orelse return 0);
        self.list.appendSlice(self.gpa, bytes[0..size]) catch return 0;
        return size;
    }

    fn stream(self: *Sink) zozz.Stream {
        return .{ .opened = &opened, .write = &write, .read = null, .seek = null, .tell = null, .user = self };
    }
};

test "zozzSetLogLevel round-trips through zozzGetLogLevel" {
    defer _ = zozz.setLogLevel(.standard) catch {};

    // ozz's own default, before anything here has touched it.
    try std.testing.expectEqual(zozz.LogLevel.standard, zozz.logLevel());

    try zozz.setLogLevel(.silent);
    try std.testing.expectEqual(zozz.LogLevel.silent, zozz.logLevel());

    try zozz.setLogLevel(.verbose);
    try std.testing.expectEqual(zozz.LogLevel.verbose, zozz.logLevel());

    try zozz.setLogLevel(.standard);
    try std.testing.expectEqual(zozz.LogLevel.standard, zozz.logLevel());
}

test "SILENT suppresses the diagnostic ozz logs for a version-mismatched skeleton archive; STANDARD does not" {
    const gpa = std.testing.allocator;
    try zozz.setAllocator(gpa);
    defer zozz.resetAllocator();
    defer _ = zozz.setLogLevel(.standard) catch {};

    // Just enough of an archive to pass Skeleton::Load's tag test and then
    // fail its version check: the tag ozz::animation::Skeleton registers with
    // OZZ_IO_TYPE_TAG (libs/ozz/include/ozz/animation/runtime/skeleton.h:149)
    // is "ozz-skeleton" plus its counted null terminator, 13 bytes, and
    // version 2 is the only one skeleton.cc's Load accepts. Any other value
    // makes it log "Unsupported Skeleton version" to ozz::log::Err() and
    // return without reading further -- exactly the diagnostic this test
    // wants to see silenced and not, with no need to build a real skeleton.
    var sink: Sink = .{ .gpa = gpa };
    defer sink.deinit();
    const bridge = sink.stream();
    const archive = try zozz.OArchive.init(&bridge, zozz.nativeEndianness());
    try archive.saveBinary("ozz-skeleton\x00");
    try archive.saveInt32(999);
    archive.deinit();

    try zozz.setLogLevel(.standard);
    const standard_bytes = zozzFixtureCapturedSkeletonLoadBytes(sink.list.items.ptr, sink.list.items.len);
    try std.testing.expect(standard_bytes > 0);

    try zozz.setLogLevel(.silent);
    const silent_bytes = zozzFixtureCapturedSkeletonLoadBytes(sink.list.items.ptr, sink.list.items.len);
    try std.testing.expectEqual(@as(usize, 0), silent_bytes);
}
