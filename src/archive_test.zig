//! Behavioural tests for the archive round trip: what gets written must
//! compare equal to what gets read back, and a stream that stops accepting
//! bytes partway through must fail loudly rather than produce a truncated
//! file that later loads.
//!
//! Skeletons and animations are built directly in code with `RawSkeleton` /
//! `RawAnimation`, so nothing here depends on an asset file.

const std = @import("std");
const zozz = @import("zozz.zig");

fn restAt(translation: [3]f32) zozz.Transform {
    var t = zozz.transform_identity;
    t.translation = translation;
    return t;
}

/// A growable in-memory `zozz.Stream` sink — the same host-bridge shape a
/// real consumer's stream would be.
const MemorySink = struct {
    list: std.ArrayList(u8) = .empty,
    gpa: std.mem.Allocator,

    fn deinit(self: *MemorySink) void {
        self.list.deinit(self.gpa);
    }

    fn opened(user: ?*anyopaque) callconv(.c) c_int {
        _ = user;
        return 1;
    }

    fn write(user: ?*anyopaque, data: ?*const anyopaque, size: usize) callconv(.c) usize {
        const self: *MemorySink = @ptrCast(@alignCast(user orelse return 0));
        const bytes: [*]const u8 = @ptrCast(data orelse return 0);
        self.list.appendSlice(self.gpa, bytes[0..size]) catch return 0;
        return size;
    }

    fn stream(self: *MemorySink) zozz.Stream {
        return .{ .opened = &opened, .write = &write, .read = null, .seek = null, .tell = null, .user = self };
    }
};

/// A host-provided in-memory stream implementing every callback, standing in
/// for a host that backs both directions with one resource — a memory-mapped
/// file, say — rather than a separate sink per direction. `pos` is public so
/// a test can rewind it between writing and reading, the way a real host
/// would re-open or re-seek whatever it wraps.
const MemoryStream = struct {
    list: std.ArrayList(u8) = .empty,
    gpa: std.mem.Allocator,
    pos: usize = 0,

    fn deinit(self: *MemoryStream) void {
        self.list.deinit(self.gpa);
    }

    fn opened(user: ?*anyopaque) callconv(.c) c_int {
        _ = user;
        return 1;
    }

    fn write(user: ?*anyopaque, data: ?*const anyopaque, size: usize) callconv(.c) usize {
        const self: *MemoryStream = @ptrCast(@alignCast(user orelse return 0));
        const bytes: [*]const u8 = @ptrCast(data orelse return 0);
        self.list.appendSlice(self.gpa, bytes[0..size]) catch return 0;
        self.pos += size;
        return size;
    }

    fn read(user: ?*anyopaque, buffer: ?*anyopaque, size: usize) callconv(.c) usize {
        const self: *MemoryStream = @ptrCast(@alignCast(user orelse return 0));
        const out: [*]u8 = @ptrCast(buffer orelse return 0);
        const available = self.list.items.len - self.pos;
        const n = @min(available, size);
        @memcpy(out[0..n], self.list.items[self.pos..][0..n]);
        self.pos += n;
        return n;
    }

    fn seek(user: ?*anyopaque, offset: c_int, origin: zozz.SeekOrigin) callconv(.c) c_int {
        const self: *MemoryStream = @ptrCast(@alignCast(user orelse return -1));
        const base: i64 = switch (origin) {
            .current => @intCast(self.pos),
            .end => @intCast(self.list.items.len),
            .set => 0,
        };
        const target = base + offset;
        if (target < 0 or target > @as(i64, @intCast(self.list.items.len))) return -1;
        self.pos = @intCast(target);
        return 0;
    }

    fn tell(user: ?*anyopaque) callconv(.c) c_int {
        const self: *MemoryStream = @ptrCast(@alignCast(user orelse return -1));
        return @intCast(self.pos);
    }

    fn stream(self: *MemoryStream) zozz.Stream {
        return .{
            .opened = &opened,
            .write = &write,
            .read = &read,
            .seek = &seek,
            .tell = &tell,
            .user = self,
        };
    }
};

/// As `MemorySink`, but silently drops everything past `quota` bytes,
/// standing in for a disk that fills up partway through a write.
const FlakySink = struct {
    quota: usize,
    written: usize = 0,
    list: std.ArrayList(u8) = .empty,
    gpa: std.mem.Allocator,

    fn deinit(self: *FlakySink) void {
        self.list.deinit(self.gpa);
    }

    fn opened(user: ?*anyopaque) callconv(.c) c_int {
        _ = user;
        return 1;
    }

    fn write(user: ?*anyopaque, data: ?*const anyopaque, size: usize) callconv(.c) usize {
        const self: *FlakySink = @ptrCast(@alignCast(user orelse return 0));
        const bytes: [*]const u8 = @ptrCast(data orelse return 0);
        const remaining = if (self.written >= self.quota) 0 else self.quota - self.written;
        const actual = @min(remaining, size);
        self.list.appendSlice(self.gpa, bytes[0..actual]) catch return 0;
        self.written += actual;
        return actual; // short of `size` once the quota is used up.
    }

    fn stream(self: *FlakySink) zozz.Stream {
        return .{ .opened = &opened, .write = &write, .read = null, .seek = null, .tell = null, .user = self };
    }
};

test "a skeleton written and read back compares equal to the original" {
    const gpa = std.testing.allocator;
    try zozz.setAllocator(gpa);
    defer zozz.resetAllocator() catch unreachable;

    var raw = try zozz.RawSkeleton.init();
    defer raw.deinit();
    const root = try raw.addJoint(null, "root", restAt(.{ 0, 0, 0 }));
    const spine = try raw.addJoint(root, "spine", restAt(.{ 0, 1, 0 }));
    _ = try raw.addJoint(spine, "arm_l", restAt(.{ -0.5, 0.5, 0 }));
    _ = try raw.addJoint(spine, "arm_r", restAt(.{ 0.5, 0.5, 0 }));
    var original = try raw.build();
    defer original.deinit();

    var sink: MemorySink = .{ .gpa = gpa };
    defer sink.deinit();
    const bridge = sink.stream();
    var archive = try zozz.OArchive.init(&bridge, zozz.nativeEndianness());
    try archive.saveSkeleton(original);
    archive.deinit();

    var roundtripped = try zozz.Skeleton.initFromMemory(sink.list.items);
    defer roundtripped.deinit();

    try std.testing.expectEqual(original.numJoints(), roundtripped.numJoints());

    var original_rest: [4]zozz.Transform = undefined;
    var roundtripped_rest: [4]zozz.Transform = undefined;
    try original.restPose(&original_rest);
    try roundtripped.restPose(&roundtripped_rest);

    for (0..original.numJoints()) |i| {
        const joint: u32 = @intCast(i);
        try std.testing.expectEqualStrings(original.jointName(joint).?, roundtripped.jointName(joint).?);
        try std.testing.expectEqual(original.jointParent(joint), roundtripped.jointParent(joint));

        for (original_rest[i].translation, roundtripped_rest[i].translation) |a, b| {
            try std.testing.expectApproxEqAbs(a, b, 1e-6);
        }
        for (original_rest[i].rotation, roundtripped_rest[i].rotation) |a, b| {
            try std.testing.expectApproxEqAbs(a, b, 1e-6);
        }
        for (original_rest[i].scale, roundtripped_rest[i].scale) |a, b| {
            try std.testing.expectApproxEqAbs(a, b, 1e-6);
        }
    }
}

test "an animation written and read back compares equal, in metadata and in sampling" {
    const gpa = std.testing.allocator;
    try zozz.setAllocator(gpa);
    defer zozz.resetAllocator() catch unreachable;

    var raw = try zozz.RawAnimation.init(2, 2.0, "roundtrip");
    defer raw.deinit();
    for (0..2) |track| {
        const x: f32 = if (track == 0) 4 else -3;
        try raw.pushTranslation(@intCast(track), 0.0, .{ 0, 0, 0 });
        try raw.pushTranslation(@intCast(track), 2.0, .{ x, 0, 0 });
        try raw.pushRotation(@intCast(track), 0.0, .{ 0, 0, 0, 1 });
        try raw.pushRotation(@intCast(track), 2.0, .{ 0, 0, 0.7071068, 0.7071068 });
        try raw.pushScale(@intCast(track), 0.0, .{ 1, 1, 1 });
    }
    var original = try raw.build();
    defer original.deinit();

    var sink: MemorySink = .{ .gpa = gpa };
    defer sink.deinit();
    const bridge = sink.stream();
    var archive = try zozz.OArchive.init(&bridge, zozz.nativeEndianness());
    try archive.saveAnimation(original);
    archive.deinit();

    var roundtripped = try zozz.Animation.initFromMemory(sink.list.items);
    defer roundtripped.deinit();

    try std.testing.expectEqual(original.duration(), roundtripped.duration());
    try std.testing.expectEqual(original.numTracks(), roundtripped.numTracks());
    try std.testing.expectEqualStrings(original.name(), roundtripped.name());

    // Two contexts, one per clip instance, sidestep the pointer-identity
    // cache invalidation a single shared context would need on every swap.
    var context_a = try zozz.SamplingContext.init(original.numTracks());
    defer context_a.deinit();
    var context_b = try zozz.SamplingContext.init(roundtripped.numTracks());
    defer context_b.deinit();
    // Two tracks fit in one SoA block.
    var pose_a: [1]zozz.SoaTransform = undefined;
    var pose_b: [1]zozz.SoaTransform = undefined;

    var locals_a: [2]zozz.Transform = undefined;
    var locals_b: [2]zozz.Transform = undefined;
    for ([_]f32{ 0.0, 0.3, 0.5, 0.75, 1.0 }) |ratio| {
        try (zozz.SamplingJob{ .animation = original, .context = context_a, .ratio = ratio, .out = &pose_a }).run();
        try zozz.pose.toLocalTransforms(&pose_a, &locals_a);
        try (zozz.SamplingJob{ .animation = roundtripped, .context = context_b, .ratio = ratio, .out = &pose_b }).run();
        try zozz.pose.toLocalTransforms(&pose_b, &locals_b);

        for (locals_a, locals_b) |a, b| {
            for (a.translation, b.translation) |x, y| try std.testing.expectApproxEqAbs(x, y, 1e-4);
            for (a.rotation, b.rotation) |x, y| try std.testing.expectApproxEqAbs(x, y, 1e-4);
            for (a.scale, b.scale) |x, y| try std.testing.expectApproxEqAbs(x, y, 1e-4);
        }
    }
}

test "a short write is reported as an error, not a truncated file that loads" {
    const gpa = std.testing.allocator;
    try zozz.setAllocator(gpa);
    defer zozz.resetAllocator() catch unreachable;

    var raw = try zozz.RawSkeleton.init();
    defer raw.deinit();
    const root = try raw.addJoint(null, "root", restAt(.{ 0, 0, 0 }));
    _ = try raw.addJoint(root, "child", restAt(.{ 0, 1, 0 }));
    var skeleton = try raw.build();
    defer skeleton.deinit();

    // Lets the archive's leading endianness byte through, then starves
    // everything after it — a short count partway into the object, not a
    // clean failure at the very first byte.
    var sink: FlakySink = .{ .quota = 4, .gpa = gpa };
    defer sink.deinit();
    const bridge = sink.stream();

    var archive = try zozz.OArchive.init(&bridge, zozz.nativeEndianness());
    const result = archive.saveSkeleton(skeleton);
    archive.deinit();

    try std.testing.expectError(zozz.Error.ReadFailed, result);

    // What did make it through must not be mistaken for a complete archive.
    if (zozz.Skeleton.initFromMemory(sink.list.items)) |loaded| {
        var accepted = loaded;
        accepted.deinit();
        return error.TestUnexpectedResult;
    } else |_| {}
}

test "a float track written and read back samples identically to the original" {
    const gpa = std.testing.allocator;
    try zozz.setAllocator(gpa);
    defer zozz.resetAllocator() catch unreachable;

    var raw = try zozz.RawFloatTrack.init();
    defer raw.deinit();
    try raw.pushKeyframe(.linear, 0.0, 0.0);
    try raw.pushKeyframe(.linear, 0.5, 10.0);
    try raw.pushKeyframe(.linear, 1.0, -4.0);
    var original = try raw.build();
    defer original.deinit();

    var sink: MemorySink = .{ .gpa = gpa };
    defer sink.deinit();
    const bridge = sink.stream();
    var archive = try zozz.OArchive.init(&bridge, zozz.nativeEndianness());
    try archive.saveFloatTrack(original);
    archive.deinit();

    var roundtripped = try zozz.FloatTrack.initFromMemory(sink.list.items);
    defer roundtripped.deinit();

    var ratio: f32 = 0.0;
    while (ratio <= 1.0) : (ratio += 0.1) {
        const a = try original.sample(ratio);
        const b = try roundtripped.sample(ratio);
        try std.testing.expectApproxEqAbs(a, b, 1e-4);
    }
}

test "a quaternion track written and read back samples identically to the original" {
    const gpa = std.testing.allocator;
    try zozz.setAllocator(gpa);
    defer zozz.resetAllocator() catch unreachable;

    var raw = try zozz.RawQuaternionTrack.init();
    defer raw.deinit();
    try raw.pushKeyframe(.linear, 0.0, .{ 0, 0, 0, 1 });
    try raw.pushKeyframe(.linear, 1.0, .{ 0, 0, 0.7071068, 0.7071068 });
    var original = try raw.build();
    defer original.deinit();

    var sink: MemorySink = .{ .gpa = gpa };
    defer sink.deinit();
    const bridge = sink.stream();
    var archive = try zozz.OArchive.init(&bridge, zozz.nativeEndianness());
    try archive.saveQuaternionTrack(original);
    archive.deinit();

    var roundtripped = try zozz.QuaternionTrack.initFromMemory(sink.list.items);
    defer roundtripped.deinit();

    var ratio: f32 = 0.0;
    while (ratio <= 1.0) : (ratio += 0.1) {
        const a = try original.sample(ratio);
        const b = try roundtripped.sample(ratio);
        for (a, b) |x, y| try std.testing.expectApproxEqAbs(x, y, 1e-4);
    }
}

test "a skeleton and an animation written into one archive round-trip back through the same host stream" {
    const gpa = std.testing.allocator;
    try zozz.setAllocator(gpa);
    defer zozz.resetAllocator() catch unreachable;

    var raw_skeleton = try zozz.RawSkeleton.init();
    defer raw_skeleton.deinit();
    const root = try raw_skeleton.addJoint(null, "root", restAt(.{ 0, 0, 0 }));
    _ = try raw_skeleton.addJoint(root, "child", restAt(.{ 0, 1, 0 }));
    var original_skeleton = try raw_skeleton.build();
    defer original_skeleton.deinit();

    var raw_animation = try zozz.RawAnimation.init(1, 1.0, "mixed");
    defer raw_animation.deinit();
    try raw_animation.pushTranslation(0, 0.0, .{ 0, 0, 0 });
    try raw_animation.pushTranslation(0, 1.0, .{ 1, 0, 0 });
    try raw_animation.pushRotation(0, 0.0, .{ 0, 0, 0, 1 });
    try raw_animation.pushScale(0, 0.0, .{ 1, 1, 1 });
    var original_animation = try raw_animation.build();
    defer original_animation.deinit();

    var mem: MemoryStream = .{ .gpa = gpa };
    defer mem.deinit();
    const bridge = mem.stream();

    var out_archive = try zozz.OArchive.init(&bridge, zozz.nativeEndianness());
    try out_archive.saveSkeleton(original_skeleton);
    try out_archive.saveAnimation(original_animation);
    out_archive.deinit();

    // The same host resource, rewound — a real host would re-open or re-seek
    // whatever `mem` stands in for.
    mem.pos = 0;
    var in_archive = try zozz.IArchive.init(&bridge);

    var roundtripped_skeleton = try in_archive.loadSkeleton();
    defer roundtripped_skeleton.deinit();
    var roundtripped_animation = try in_archive.loadAnimation();
    defer roundtripped_animation.deinit();
    in_archive.deinit();

    try std.testing.expectEqual(original_skeleton.numJoints(), roundtripped_skeleton.numJoints());
    for (0..original_skeleton.numJoints()) |i| {
        const joint: u32 = @intCast(i);
        try std.testing.expectEqualStrings(
            original_skeleton.jointName(joint).?,
            roundtripped_skeleton.jointName(joint).?,
        );
        try std.testing.expectEqual(original_skeleton.jointParent(joint), roundtripped_skeleton.jointParent(joint));
    }

    try std.testing.expectEqual(original_animation.duration(), roundtripped_animation.duration());
    try std.testing.expectEqual(original_animation.numTracks(), roundtripped_animation.numTracks());
    try std.testing.expectEqualStrings(original_animation.name(), roundtripped_animation.name());
}

test "TestTag answers without consuming, so the real type can still be loaded after a false test" {
    const gpa = std.testing.allocator;
    try zozz.setAllocator(gpa);
    defer zozz.resetAllocator() catch unreachable;

    var raw = try zozz.RawSkeleton.init();
    defer raw.deinit();
    _ = try raw.addJoint(null, "root", restAt(.{ 0, 0, 0 }));
    var original = try raw.build();
    defer original.deinit();

    var mem: MemoryStream = .{ .gpa = gpa };
    defer mem.deinit();
    const bridge = mem.stream();

    var out_archive = try zozz.OArchive.init(&bridge, zozz.nativeEndianness());
    try out_archive.saveSkeleton(original);
    out_archive.deinit();

    mem.pos = 0;
    var in_archive = try zozz.IArchive.init(&bridge);
    defer in_archive.deinit();

    // Wrong guesses first, each one a no-op on the read position.
    try std.testing.expect(!in_archive.testAnimation());
    try std.testing.expect(!in_archive.testFloatTrack());
    try std.testing.expect(!in_archive.testQuaternionTrack());
    // The right guess can be asked more than once, too.
    try std.testing.expect(in_archive.testSkeleton());
    try std.testing.expect(in_archive.testSkeleton());

    // None of the above consumed anything: the object still loads.
    var loaded = try in_archive.loadSkeleton();
    defer loaded.deinit();
    try std.testing.expectEqual(original.numJoints(), loaded.numJoints());
}

test "a stream missing a callback its direction needs is rejected, not crashed into" {
    const gpa = std.testing.allocator;
    try zozz.setAllocator(gpa);
    defer zozz.resetAllocator() catch unreachable;

    var mem: MemoryStream = .{ .gpa = gpa };
    defer mem.deinit();
    const bridge = mem.stream();

    var missing_write = bridge;
    missing_write.write = null;
    try std.testing.expectError(
        zozz.Error.InvalidArgument,
        zozz.OArchive.init(&missing_write, zozz.nativeEndianness()),
    );

    var missing_read = bridge;
    missing_read.read = null;
    try std.testing.expectError(zozz.Error.InvalidArgument, zozz.IArchive.init(&missing_read));

    var missing_seek = bridge;
    missing_seek.seek = null;
    try std.testing.expectError(zozz.Error.InvalidArgument, zozz.IArchive.init(&missing_seek));

    var missing_tell = bridge;
    missing_tell.tell = null;
    try std.testing.expectError(zozz.Error.InvalidArgument, zozz.IArchive.init(&missing_tell));

    // A stream with everything a write archive needs, and nothing more, is
    // still accepted for writing — read is genuinely optional there.
    var write_only = bridge;
    write_only.read = null;
    write_only.seek = null;
    write_only.tell = null;
    var archive = try zozz.OArchive.init(&write_only, zozz.nativeEndianness());
    archive.deinit();
}

test "an archive written with the opposite endianness byte-swaps its fields, and ozz reads both back identically" {
    const gpa = std.testing.allocator;
    try zozz.setAllocator(gpa);
    defer zozz.resetAllocator() catch unreachable;

    var raw = try zozz.RawSkeleton.init();
    defer raw.deinit();
    const root = try raw.addJoint(null, "root", restAt(.{ 0, 0, 0 }));
    _ = try raw.addJoint(root, "child", restAt(.{ 0, 1, 0 }));
    var original = try raw.build();
    defer original.deinit();

    const native = zozz.nativeEndianness();
    const foreign: zozz.Endianness = if (native == .big) .little else .big;

    var native_sink: MemorySink = .{ .gpa = gpa };
    defer native_sink.deinit();
    {
        const bridge = native_sink.stream();
        var archive_native = try zozz.OArchive.init(&bridge, native);
        try archive_native.saveSkeleton(original);
        archive_native.deinit();
    }

    var foreign_sink: MemorySink = .{ .gpa = gpa };
    defer foreign_sink.deinit();
    {
        const bridge = foreign_sink.stream();
        var archive_foreign = try zozz.OArchive.init(&bridge, foreign);
        try archive_foreign.saveSkeleton(original);
        archive_foreign.deinit();
    }

    // Same shape, only byte order differs.
    try std.testing.expectEqual(native_sink.list.items.len, foreign_sink.list.items.len);

    // Byte 0 is the endianness marker OArchive's constructor writes
    // (ozz::io::archive.cc): 0 for big, 1 for little, unswapped because it is
    // a single byte -- so the two archives must literally disagree on it.
    try std.testing.expect(native_sink.list.items[0] != foreign_sink.list.items[0]);

    // Right after the 13-byte "ozz-skeleton\0" tag (raw, unswapped, like any
    // tag) and the 4-byte version, Skeleton::Save writes num_joints as a
    // plain int32 -- the first genuinely endianness-sensitive field. Between
    // the two archives it must be an exact byte-for-byte reversal, which is
    // what "byte-swapped" means, not merely "some other bytes".
    const tag = "ozz-skeleton\x00";
    const native_tag_pos = std.mem.indexOf(u8, native_sink.list.items, tag).?;
    const foreign_tag_pos = std.mem.indexOf(u8, foreign_sink.list.items, tag).?;
    const native_num_joints = native_sink.list.items[native_tag_pos + tag.len + 4 ..];
    const foreign_num_joints = foreign_sink.list.items[foreign_tag_pos + tag.len + 4 ..];
    for (0..4) |i| {
        try std.testing.expectEqual(native_num_joints[i], foreign_num_joints[3 - i]);
    }

    // ozz's IArchive adapts on read regardless of which platform wrote the
    // file, so both must load back to the exact same skeleton.
    var from_native = try zozz.Skeleton.initFromMemory(native_sink.list.items);
    defer from_native.deinit();
    var from_foreign = try zozz.Skeleton.initFromMemory(foreign_sink.list.items);
    defer from_foreign.deinit();

    try std.testing.expectEqual(from_native.numJoints(), from_foreign.numJoints());
    for (0..from_native.numJoints()) |i| {
        const joint: u32 = @intCast(i);
        try std.testing.expectEqualStrings(from_native.jointName(joint).?, from_foreign.jointName(joint).?);
        try std.testing.expectEqual(from_native.jointParent(joint), from_foreign.jointParent(joint));
    }

    var native_rest: [2]zozz.Transform = undefined;
    var foreign_rest: [2]zozz.Transform = undefined;
    try from_native.restPose(&native_rest);
    try from_foreign.restPose(&foreign_rest);
    for (native_rest, foreign_rest) |a, b| {
        for (a.translation, b.translation) |x, y| try std.testing.expectEqual(x, y);
    }
}

test "IArchive.endianSwap reports whether the stored byte order differs from this platform's" {
    const gpa = std.testing.allocator;
    try zozz.setAllocator(gpa);
    defer zozz.resetAllocator() catch unreachable;

    const native = zozz.nativeEndianness();
    const foreign: zozz.Endianness = if (native == .big) .little else .big;

    // IArchive's constructor reads the stored byte order off the stream and
    // hands it back no other way, so this is the only route to it.
    var foreign_mem: MemoryStream = .{ .gpa = gpa };
    defer foreign_mem.deinit();
    {
        const bridge = foreign_mem.stream();
        var out = try zozz.OArchive.init(&bridge, foreign);
        try out.saveInt32(42);
        out.deinit();
    }
    foreign_mem.pos = 0;
    {
        const bridge = foreign_mem.stream();
        var in = try zozz.IArchive.init(&bridge);
        defer in.deinit();
        try std.testing.expect(in.endianSwap());
        try std.testing.expectEqual(@as(i32, 42), try in.loadInt32());
    }

    var native_mem: MemoryStream = .{ .gpa = gpa };
    defer native_mem.deinit();
    {
        const bridge = native_mem.stream();
        var out = try zozz.OArchive.init(&bridge, native);
        try out.saveInt32(42);
        out.deinit();
    }
    native_mem.pos = 0;
    {
        const bridge = native_mem.stream();
        var in = try zozz.IArchive.init(&bridge);
        defer in.deinit();
        try std.testing.expect(!in.endianSwap());
    }
}

//=============================================================================
// The offline types
//
// A cook stage's output is a RAW skeleton, clip or track, and until it can be
// written and read back the stage cannot hand it to the next one. These pin
// the round trip: what comes back is what went in, key for key, and the one
// thing that does NOT survive — a raw skeleton's authoring order — is pinned
// as loudly as the things that do.
//=============================================================================

/// Authors a two-root, uneven-depth raw skeleton whose insertion order is
/// deliberately NOT depth-first, so a round trip has something to reindex.
fn authorRawSkeleton() !zozz.RawSkeleton {
    var raw = try zozz.RawSkeleton.init();
    errdefer raw.deinit();
    const root = try raw.addJoint(null, "root", restAt(.{ 0, 0, 0 }));
    const a = try raw.addJoint(root, "a", restAt(.{ 1, 0, 0 }));
    _ = try raw.addJoint(root, "b", restAt(.{ 2, 0, 0 }));
    _ = try raw.addJoint(a, "c", restAt(.{ 3, 0, 0 }));
    return raw;
}

test "a raw skeleton round-trips its names, parents and rest transforms" {
    const gpa = std.testing.allocator;
    var stream = MemoryStream{ .gpa = gpa };
    defer stream.deinit();

    var raw = try authorRawSkeleton();
    defer raw.deinit();

    {
        const host = stream.stream();
        var out = try zozz.OArchive.init(&host, zozz.nativeEndianness());
        defer out.deinit();
        try out.saveRawSkeleton(raw);
    }

    stream.pos = 0;
    const host = stream.stream();
    var in = try zozz.IArchive.init(&host);
    defer in.deinit();
    try std.testing.expect(in.testRawSkeleton());
    var loaded = try in.loadRawSkeleton();
    defer loaded.deinit();

    try std.testing.expectEqual(raw.numJoints(), loaded.numJoints());

    // The AUTHORED order was root, a, b, c(child of a). ozz archives the
    // nested tree, so what comes back is the tree's depth-first order —
    // root, a, c, b — the same reindexing `build` performs. This is the one
    // property the round trip does not preserve, and it is documented in
    // ffi/zozz_archive.h rather than left for a consumer to discover.
    try std.testing.expectEqualStrings("root", loaded.jointName(0).?);
    try std.testing.expectEqualStrings("a", loaded.jointName(1).?);
    try std.testing.expectEqualStrings("c", loaded.jointName(2).?);
    try std.testing.expectEqualStrings("b", loaded.jointName(3).?);

    try std.testing.expectEqual(@as(?u32, null), loaded.jointParent(0));
    try std.testing.expectEqual(@as(?u32, 0), loaded.jointParent(1));
    try std.testing.expectEqual(@as(?u32, 1), loaded.jointParent(2));
    try std.testing.expectEqual(@as(?u32, 0), loaded.jointParent(3));

    try std.testing.expectEqual(@as(f32, 3), (try loaded.jointRest(2)).translation[0]);
    try std.testing.expectEqual(@as(f32, 2), (try loaded.jointRest(3)).translation[0]);

    // And the two build into the same runtime skeleton, which is the
    // property a cook actually depends on.
    var from_original = try raw.build();
    defer from_original.deinit();
    var from_loaded = try loaded.build();
    defer from_loaded.deinit();
    try std.testing.expectEqual(from_original.numJoints(), from_loaded.numJoints());
    for (0..from_original.numJoints()) |joint| {
        const i: u32 = @intCast(joint);
        try std.testing.expectEqualStrings(
            from_original.jointName(i).?,
            from_loaded.jointName(i).?,
        );
        try std.testing.expectEqual(from_original.jointParent(i), from_loaded.jointParent(i));
    }
}

test "a raw animation round-trips key for key, name and duration included" {
    const gpa = std.testing.allocator;
    var stream = MemoryStream{ .gpa = gpa };
    defer stream.deinit();

    var raw = try zozz.RawAnimation.init(2, 3.0, "cached");
    defer raw.deinit();
    try raw.pushTranslation(0, 0.0, .{ 1, 2, 3 });
    try raw.pushTranslation(0, 1.5, .{ 4, 5, 6 });
    try raw.pushRotation(1, 0.25, .{ 0, 0.7071068, 0, 0.7071068 });
    try raw.pushScale(1, 3.0, .{ 2, 2, 2 });

    {
        const host = stream.stream();
        var out = try zozz.OArchive.init(&host, zozz.nativeEndianness());
        defer out.deinit();
        try out.saveRawAnimation(raw);
    }

    stream.pos = 0;
    const host = stream.stream();
    var in = try zozz.IArchive.init(&host);
    defer in.deinit();
    try std.testing.expect(in.testRawAnimation());
    var loaded = try in.loadRawAnimation();
    defer loaded.deinit();

    try std.testing.expectEqual(@as(u32, 2), loaded.numTracks());
    try std.testing.expectEqual(@as(f32, 3.0), loaded.duration());
    try std.testing.expectEqualStrings("cached", loaded.name());

    var mine: [8]zozz.TranslationKey = undefined;
    var theirs: [8]zozz.TranslationKey = undefined;
    const a = try raw.translations(0, &mine);
    const b = try loaded.translations(0, &theirs);
    try std.testing.expectEqualSlices(zozz.TranslationKey, a, b);

    var r_mine: [8]zozz.RotationKey = undefined;
    var r_theirs: [8]zozz.RotationKey = undefined;
    try std.testing.expectEqualSlices(
        zozz.RotationKey,
        try raw.rotations(1, &r_mine),
        try loaded.rotations(1, &r_theirs),
    );

    var s_mine: [8]zozz.ScaleKey = undefined;
    var s_theirs: [8]zozz.ScaleKey = undefined;
    try std.testing.expectEqualSlices(
        zozz.ScaleKey,
        try raw.scales(1, &s_mine),
        try loaded.scales(1, &s_theirs),
    );
}

test "a raw float track round-trips its keyframes, interpolation modes and name" {
    const gpa = std.testing.allocator;
    var stream = MemoryStream{ .gpa = gpa };
    defer stream.deinit();

    var raw = try zozz.RawFloatTrack.init();
    defer raw.deinit();
    try raw.setName("intensity");
    try raw.pushKeyframe(.step, 0.0, 1.0);
    try raw.pushKeyframe(.linear, 0.5, 2.0);
    try raw.pushKeyframe(.step, 1.0, 3.0);

    {
        const host = stream.stream();
        var out = try zozz.OArchive.init(&host, zozz.nativeEndianness());
        defer out.deinit();
        try out.saveRawFloatTrack(raw);
    }

    stream.pos = 0;
    const host = stream.stream();
    var in = try zozz.IArchive.init(&host);
    defer in.deinit();
    try std.testing.expect(in.testRawFloatTrack());
    var loaded = try in.loadRawFloatTrack();
    defer loaded.deinit();

    try std.testing.expectEqualStrings("intensity", loaded.name());
    var mine: [8]zozz.FloatKeyframe = undefined;
    var theirs: [8]zozz.FloatKeyframe = undefined;
    try std.testing.expectEqualSlices(
        zozz.FloatKeyframe,
        try raw.keyframes(&mine),
        try loaded.keyframes(&theirs),
    );

    // Clearing is what an edit starts with, and it keeps the name.
    try loaded.clear();
    try std.testing.expectEqual(@as(u32, 0), loaded.numKeyframes());
    try std.testing.expectEqualStrings("intensity", loaded.name());
}

test "a raw quaternion track round-trips (x, y, z, w) order" {
    const gpa = std.testing.allocator;
    var stream = MemoryStream{ .gpa = gpa };
    defer stream.deinit();

    var raw = try zozz.RawQuaternionTrack.init();
    defer raw.deinit();
    try raw.pushKeyframe(.linear, 0.0, .{ 0, 0, 0, 1 });
    try raw.pushKeyframe(.linear, 1.0, .{ 0, 0.7071068, 0, 0.7071068 });

    {
        const host = stream.stream();
        var out = try zozz.OArchive.init(&host, zozz.nativeEndianness());
        defer out.deinit();
        try out.saveRawQuaternionTrack(raw);
    }

    stream.pos = 0;
    const host = stream.stream();
    var in = try zozz.IArchive.init(&host);
    defer in.deinit();
    var loaded = try in.loadRawQuaternionTrack();
    defer loaded.deinit();

    var keys: [4]zozz.QuaternionKeyframe = undefined;
    const back = try loaded.keyframes(&keys);
    try std.testing.expectEqual(@as(usize, 2), back.len);
    try std.testing.expectEqual(@as(f32, 0.7071068), back[1].value[1]);
    try std.testing.expectEqual(@as(f32, 0.7071068), back[1].value[3]);
    try std.testing.expectEqual(zozz.TrackInterpolation.linear, back[1].interpolation);
}

test "a raw archive and a runtime archive are not interchangeable" {
    const gpa = std.testing.allocator;
    var stream = MemoryStream{ .gpa = gpa };
    defer stream.deinit();

    var raw = try authorRawSkeleton();
    defer raw.deinit();
    var built = try raw.build();
    defer built.deinit();

    // A RUNTIME skeleton on the stream.
    {
        const host = stream.stream();
        var out = try zozz.OArchive.init(&host, zozz.nativeEndianness());
        defer out.deinit();
        try out.saveSkeleton(built);
    }

    stream.pos = 0;
    const host = stream.stream();
    var in = try zozz.IArchive.init(&host);
    defer in.deinit();

    // ozz tags the two types differently, so the raw test says no, the
    // runtime test says yes, and the raw load refuses rather than parsing
    // the runtime skeleton's bytes as a tree.
    try std.testing.expect(!in.testRawSkeleton());
    try std.testing.expect(in.testSkeleton());
    try std.testing.expectError(error.BadFormat, in.loadRawSkeleton());
    // The failed test consumed nothing: the right load still works.
    var loaded = try in.loadSkeleton();
    defer loaded.deinit();
    try std.testing.expectEqual(built.numJoints(), loaded.numJoints());
}

test "an empty raw skeleton has no tree to write and is refused" {
    const gpa = std.testing.allocator;
    var sink = MemorySink{ .gpa = gpa };
    defer sink.deinit();

    var raw = try zozz.RawSkeleton.init();
    defer raw.deinit();

    const host = sink.stream();
    var out = try zozz.OArchive.init(&host, zozz.nativeEndianness());
    defer out.deinit();
    // The same answer build gives it, rather than an archive that loads back
    // as a skeleton nothing can build.
    try std.testing.expectError(error.InvalidData, out.saveRawSkeleton(raw));
    try std.testing.expectError(error.InvalidData, raw.build());
}

test "the offline types round-trip through a file, and through its bytes" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // A path relative to the process cwd, which is what the C side's fopen
    // resolves against too: std.testing.tmpDir puts its directory under
    // .zig-cache/tmp of that same cwd, so both halves of the round trip name
    // one file without either needing an absolute path.
    const path = try std.fmt.allocPrintSentinel(
        gpa,
        ".zig-cache/tmp/{s}/clip.ozz",
        .{tmp.sub_path},
        0,
    );
    defer gpa.free(path);

    var raw = try zozz.RawAnimation.init(1, 2.0, "on_disk");
    defer raw.deinit();
    try raw.pushTranslation(0, 0.0, .{ 7, 8, 9 });
    try raw.pushTranslation(0, 2.0, .{ 1, 0, 0 });
    try zozz.saveRawAnimationToFile(raw, path);

    {
        var loaded = try zozz.RawAnimation.initFromFile(path);
        defer loaded.deinit();
        try std.testing.expectEqualStrings("on_disk", loaded.name());
        try std.testing.expectEqual(@as(f32, 2.0), loaded.duration());
        var mine: [4]zozz.TranslationKey = undefined;
        var theirs: [4]zozz.TranslationKey = undefined;
        try std.testing.expectEqualSlices(
            zozz.TranslationKey,
            try raw.translations(0, &mine),
            try loaded.translations(0, &theirs),
        );
    }

    // The memory loader must read the same bytes to the same clip: the file
    // path and the memory image are two doors onto one parser, and a
    // consumer that mmaps its assets uses the second.
    const bytes = try tmp.dir.readFileAlloc(std.testing.io, "clip.ozz", gpa, .limited(1 << 20));
    defer gpa.free(bytes);
    var from_memory = try zozz.RawAnimation.initFromMemory(bytes);
    defer from_memory.deinit();
    try std.testing.expectEqualStrings("on_disk", from_memory.name());
    try std.testing.expectEqual(@as(u32, 2), from_memory.numTranslations(0));

    // A file that is not an archive at all, and one that is the wrong type.
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "junk.ozz", .data = "not an ozz archive" });
    const junk = try std.fmt.allocPrintSentinel(
        gpa,
        ".zig-cache/tmp/{s}/junk.ozz",
        .{tmp.sub_path},
        0,
    );
    defer gpa.free(junk);
    try std.testing.expectError(error.BadFormat, zozz.RawAnimation.initFromFile(junk));
    try std.testing.expectError(error.BadFormat, zozz.RawSkeleton.initFromFile(path));
    try std.testing.expectError(error.FileNotFound, zozz.RawAnimation.initFromFile("no_such_file.ozz"));
}

test "every remaining raw track type round-trips through an archive" {
    const gpa = std.testing.allocator;

    // The float and quaternion tracks are covered above, value by value; the
    // three in between share one C++ template with them, so what is worth
    // pinning here is that each has its OWN pair of entry points wired to its
    // OWN type — a copy-paste that saved a float2 through the float3 door
    // would compile and would be caught here.
    inline for (.{
        .{ zozz.RawFloat2Track, zozz.Float2Keyframe, [2]f32{ 1, 2 }, "Float2Track" },
        .{ zozz.RawFloat3Track, zozz.Float3Keyframe, [3]f32{ 1, 2, 3 }, "Float3Track" },
        .{ zozz.RawFloat4Track, zozz.Float4Keyframe, [4]f32{ 1, 2, 3, 4 }, "Float4Track" },
    }) |case| {
        const Track = case[0];
        const Keyframe = case[1];
        const value = case[2];
        const suffix = case[3];

        var stream = MemoryStream{ .gpa = gpa };
        defer stream.deinit();

        var raw = try Track.init();
        defer raw.deinit();
        try raw.setName("channel");
        try raw.pushKeyframe(.step, 0.0, value);
        try raw.pushKeyframe(.linear, 1.0, value);

        {
            const host = stream.stream();
            var out = try zozz.OArchive.init(&host, zozz.nativeEndianness());
            defer out.deinit();
            try @field(zozz.OArchive, "saveRaw" ++ suffix)(out, raw);
        }

        stream.pos = 0;
        const host = stream.stream();
        var in = try zozz.IArchive.init(&host);
        defer in.deinit();
        try std.testing.expect(@field(zozz.IArchive, "testRaw" ++ suffix)(in));
        var loaded = try @field(zozz.IArchive, "loadRaw" ++ suffix)(in);
        defer loaded.deinit();

        try std.testing.expectEqualStrings("channel", loaded.name());
        var mine: [4]Keyframe = undefined;
        var theirs: [4]Keyframe = undefined;
        try std.testing.expectEqualSlices(
            Keyframe,
            try raw.keyframes(&mine),
            try loaded.keyframes(&theirs),
        );
        try std.testing.expect(loaded.validate());
    }
}
