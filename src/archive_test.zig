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
        return .{ .opened = &opened, .write = &write, .user = self };
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
        return .{ .opened = &opened, .write = &write, .user = self };
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
    const archive = try zozz.OArchive.init(&bridge);
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
    const archive = try zozz.OArchive.init(&bridge);
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
    const pose_a = try zozz.SoaPose.init(original.numTracks());
    defer pose_a.deinit();
    const pose_b = try zozz.SoaPose.init(roundtripped.numTracks());
    defer pose_b.deinit();

    var locals_a: [2]zozz.Transform = undefined;
    var locals_b: [2]zozz.Transform = undefined;
    for ([_]f32{ 0.0, 0.3, 0.5, 0.75, 1.0 }) |ratio| {
        try (zozz.SamplingJob{ .animation = original, .context = context_a, .ratio = ratio, .out = pose_a }).run();
        try pose_a.toLocalTransforms(&locals_a);
        try (zozz.SamplingJob{ .animation = roundtripped, .context = context_b, .ratio = ratio, .out = pose_b }).run();
        try pose_b.toLocalTransforms(&locals_b);

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

    const archive = try zozz.OArchive.init(&bridge);
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
    const archive = try zozz.OArchive.init(&bridge);
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
    const archive = try zozz.OArchive.init(&bridge);
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
