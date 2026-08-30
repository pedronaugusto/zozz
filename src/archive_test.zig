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
    defer zozz.resetAllocator();

    const raw = try zozz.RawSkeleton.init();
    defer raw.deinit();
    const root = try raw.addJoint(null, "root", restAt(.{ 0, 0, 0 }));
    const spine = try raw.addJoint(root, "spine", restAt(.{ 0, 1, 0 }));
    _ = try raw.addJoint(spine, "arm_l", restAt(.{ -0.5, 0.5, 0 }));
    _ = try raw.addJoint(spine, "arm_r", restAt(.{ 0.5, 0.5, 0 }));
    const original = try raw.build();
    defer original.deinit();

    var sink: MemorySink = .{ .gpa = gpa };
    defer sink.deinit();
    const bridge = sink.stream();
    const archive = try zozz.OArchive.init(&bridge, zozz.nativeEndianness());
    try archive.saveSkeleton(original);
    archive.deinit();

    const roundtripped = try zozz.Skeleton.initFromMemory(sink.list.items);
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
    defer zozz.resetAllocator();

    const raw = try zozz.RawAnimation.init(2, 2.0, "roundtrip");
    defer raw.deinit();
    for (0..2) |track| {
        const x: f32 = if (track == 0) 4 else -3;
        try raw.pushTranslation(@intCast(track), 0.0, .{ 0, 0, 0 });
        try raw.pushTranslation(@intCast(track), 2.0, .{ x, 0, 0 });
        try raw.pushRotation(@intCast(track), 0.0, .{ 0, 0, 0, 1 });
        try raw.pushRotation(@intCast(track), 2.0, .{ 0, 0, 0.7071068, 0.7071068 });
        try raw.pushScale(@intCast(track), 0.0, .{ 1, 1, 1 });
    }
    const original = try raw.build();
    defer original.deinit();

    var sink: MemorySink = .{ .gpa = gpa };
    defer sink.deinit();
    const bridge = sink.stream();
    const archive = try zozz.OArchive.init(&bridge, zozz.nativeEndianness());
    try archive.saveAnimation(original);
    archive.deinit();

    const roundtripped = try zozz.Animation.initFromMemory(sink.list.items);
    defer roundtripped.deinit();

    try std.testing.expectEqual(original.duration(), roundtripped.duration());
    try std.testing.expectEqual(original.numTracks(), roundtripped.numTracks());
    try std.testing.expectEqualStrings(original.name(), roundtripped.name());

    // Two contexts, one per clip instance, sidestep the pointer-identity
    // cache invalidation a single shared context would need on every swap.
    const context_a = try zozz.SamplingContext.init(original.numTracks());
    defer context_a.deinit();
    const context_b = try zozz.SamplingContext.init(roundtripped.numTracks());
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
    defer zozz.resetAllocator();

    const raw = try zozz.RawSkeleton.init();
    defer raw.deinit();
    const root = try raw.addJoint(null, "root", restAt(.{ 0, 0, 0 }));
    _ = try raw.addJoint(root, "child", restAt(.{ 0, 1, 0 }));
    const skeleton = try raw.build();
    defer skeleton.deinit();

    // Lets the archive's leading endianness byte through, then starves
    // everything after it — a short count partway into the object, not a
    // clean failure at the very first byte.
    var sink: FlakySink = .{ .quota = 4, .gpa = gpa };
    defer sink.deinit();
    const bridge = sink.stream();

    const archive = try zozz.OArchive.init(&bridge, zozz.nativeEndianness());
    const result = archive.saveSkeleton(skeleton);
    archive.deinit();

    try std.testing.expectError(zozz.Error.ReadFailed, result);

    // What did make it through must not be mistaken for a complete archive.
    if (zozz.Skeleton.initFromMemory(sink.list.items)) |loaded| {
        loaded.deinit();
        return error.TestUnexpectedResult;
    } else |_| {}
}

test "a float track written and read back samples identically to the original" {
    const gpa = std.testing.allocator;
    try zozz.setAllocator(gpa);
    defer zozz.resetAllocator();

    const raw = try zozz.RawFloatTrack.init();
    defer raw.deinit();
    try raw.pushKeyframe(.linear, 0.0, 0.0);
    try raw.pushKeyframe(.linear, 0.5, 10.0);
    try raw.pushKeyframe(.linear, 1.0, -4.0);
    const original = try raw.build();
    defer original.deinit();

    var sink: MemorySink = .{ .gpa = gpa };
    defer sink.deinit();
    const bridge = sink.stream();
    const archive = try zozz.OArchive.init(&bridge, zozz.nativeEndianness());
    try archive.saveFloatTrack(original);
    archive.deinit();

    const roundtripped = try zozz.FloatTrack.initFromMemory(sink.list.items);
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
    defer zozz.resetAllocator();

    const raw = try zozz.RawQuaternionTrack.init();
    defer raw.deinit();
    try raw.pushKeyframe(.linear, 0.0, .{ 0, 0, 0, 1 });
    try raw.pushKeyframe(.linear, 1.0, .{ 0, 0, 0.7071068, 0.7071068 });
    const original = try raw.build();
    defer original.deinit();

    var sink: MemorySink = .{ .gpa = gpa };
    defer sink.deinit();
    const bridge = sink.stream();
    const archive = try zozz.OArchive.init(&bridge, zozz.nativeEndianness());
    try archive.saveQuaternionTrack(original);
    archive.deinit();

    const roundtripped = try zozz.QuaternionTrack.initFromMemory(sink.list.items);
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
    defer zozz.resetAllocator();

    const raw_skeleton = try zozz.RawSkeleton.init();
    defer raw_skeleton.deinit();
    const root = try raw_skeleton.addJoint(null, "root", restAt(.{ 0, 0, 0 }));
    _ = try raw_skeleton.addJoint(root, "child", restAt(.{ 0, 1, 0 }));
    const original_skeleton = try raw_skeleton.build();
    defer original_skeleton.deinit();

    const raw_animation = try zozz.RawAnimation.init(1, 1.0, "mixed");
    defer raw_animation.deinit();
    try raw_animation.pushTranslation(0, 0.0, .{ 0, 0, 0 });
    try raw_animation.pushTranslation(0, 1.0, .{ 1, 0, 0 });
    try raw_animation.pushRotation(0, 0.0, .{ 0, 0, 0, 1 });
    try raw_animation.pushScale(0, 0.0, .{ 1, 1, 1 });
    const original_animation = try raw_animation.build();
    defer original_animation.deinit();

    var mem: MemoryStream = .{ .gpa = gpa };
    defer mem.deinit();
    const bridge = mem.stream();

    const out_archive = try zozz.OArchive.init(&bridge, zozz.nativeEndianness());
    try out_archive.saveSkeleton(original_skeleton);
    try out_archive.saveAnimation(original_animation);
    out_archive.deinit();

    // The same host resource, rewound — a real host would re-open or re-seek
    // whatever `mem` stands in for.
    mem.pos = 0;
    const in_archive = try zozz.IArchive.init(&bridge);

    const roundtripped_skeleton = try in_archive.loadSkeleton();
    defer roundtripped_skeleton.deinit();
    const roundtripped_animation = try in_archive.loadAnimation();
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
    defer zozz.resetAllocator();

    const raw = try zozz.RawSkeleton.init();
    defer raw.deinit();
    _ = try raw.addJoint(null, "root", restAt(.{ 0, 0, 0 }));
    const original = try raw.build();
    defer original.deinit();

    var mem: MemoryStream = .{ .gpa = gpa };
    defer mem.deinit();
    const bridge = mem.stream();

    const out_archive = try zozz.OArchive.init(&bridge, zozz.nativeEndianness());
    try out_archive.saveSkeleton(original);
    out_archive.deinit();

    mem.pos = 0;
    const in_archive = try zozz.IArchive.init(&bridge);
    defer in_archive.deinit();

    // Wrong guesses first, each one a no-op on the read position.
    try std.testing.expect(!in_archive.testAnimation());
    try std.testing.expect(!in_archive.testFloatTrack());
    try std.testing.expect(!in_archive.testQuaternionTrack());
    // The right guess can be asked more than once, too.
    try std.testing.expect(in_archive.testSkeleton());
    try std.testing.expect(in_archive.testSkeleton());

    // None of the above consumed anything: the object still loads.
    const loaded = try in_archive.loadSkeleton();
    defer loaded.deinit();
    try std.testing.expectEqual(original.numJoints(), loaded.numJoints());
}

test "a stream missing a callback its direction needs is rejected, not crashed into" {
    const gpa = std.testing.allocator;
    try zozz.setAllocator(gpa);
    defer zozz.resetAllocator();

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
    const archive = try zozz.OArchive.init(&write_only, zozz.nativeEndianness());
    archive.deinit();
}

test "an archive written with the opposite endianness byte-swaps its fields, and ozz reads both back identically" {
    const gpa = std.testing.allocator;
    try zozz.setAllocator(gpa);
    defer zozz.resetAllocator();

    const raw = try zozz.RawSkeleton.init();
    defer raw.deinit();
    const root = try raw.addJoint(null, "root", restAt(.{ 0, 0, 0 }));
    _ = try raw.addJoint(root, "child", restAt(.{ 0, 1, 0 }));
    const original = try raw.build();
    defer original.deinit();

    const native = zozz.nativeEndianness();
    const foreign: zozz.Endianness = if (native == .big) .little else .big;

    var native_sink: MemorySink = .{ .gpa = gpa };
    defer native_sink.deinit();
    {
        const bridge = native_sink.stream();
        const archive_native = try zozz.OArchive.init(&bridge, native);
        try archive_native.saveSkeleton(original);
        archive_native.deinit();
    }

    var foreign_sink: MemorySink = .{ .gpa = gpa };
    defer foreign_sink.deinit();
    {
        const bridge = foreign_sink.stream();
        const archive_foreign = try zozz.OArchive.init(&bridge, foreign);
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
    const from_native = try zozz.Skeleton.initFromMemory(native_sink.list.items);
    defer from_native.deinit();
    const from_foreign = try zozz.Skeleton.initFromMemory(foreign_sink.list.items);
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
    defer zozz.resetAllocator();

    const native = zozz.nativeEndianness();
    const foreign: zozz.Endianness = if (native == .big) .little else .big;

    // IArchive's constructor reads the stored byte order off the stream and
    // hands it back no other way, so this is the only route to it.
    var foreign_mem: MemoryStream = .{ .gpa = gpa };
    defer foreign_mem.deinit();
    {
        const bridge = foreign_mem.stream();
        const out = try zozz.OArchive.init(&bridge, foreign);
        try out.saveInt32(42);
        out.deinit();
    }
    foreign_mem.pos = 0;
    {
        const bridge = foreign_mem.stream();
        const in = try zozz.IArchive.init(&bridge);
        defer in.deinit();
        try std.testing.expect(in.endianSwap());
        try std.testing.expectEqual(@as(i32, 42), try in.loadInt32());
    }

    var native_mem: MemoryStream = .{ .gpa = gpa };
    defer native_mem.deinit();
    {
        const bridge = native_mem.stream();
        const out = try zozz.OArchive.init(&bridge, native);
        try out.saveInt32(42);
        out.deinit();
    }
    native_mem.pos = 0;
    {
        const bridge = native_mem.stream();
        const in = try zozz.IArchive.init(&bridge);
        defer in.deinit();
        try std.testing.expect(!in.endianSwap());
    }
}
