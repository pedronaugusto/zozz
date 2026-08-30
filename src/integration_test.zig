//! End-to-end tests: load -> sample -> convert -> local-to-model.
//!
//! Two sources of assets:
//!
//!   * the synthetic fixture, built through ozz's offline builders and always
//!     version-matched to the vendored runtime. Always runs.
//!   * real `.ozz` files on disk, given via `-Dskeleton_path` /
//!     `-Danimation_path`. Skipped when absent.
//!
//! Both drive the same assertion body, so an on-disk asset is held to exactly
//! the standard the fixture is.
//!
//! Compiled only into the test binary; the fixture symbols below live in the
//! test-only `zozz-fixture` library.

const std = @import("std");
const zozz = @import("zozz.zig");
const err = @import("error.zig");
const test_options = @import("test_options");

//=============================================================================
// Fixture bindings (tests/fixture.h)
//=============================================================================

const Result = zozz.c.Result;

extern fn zozzFixtureSkeleton(out_data: *?*anyopaque, out_size: *usize) Result;
extern fn zozzFixtureAnimation(out_data: *?*anyopaque, out_size: *usize) Result;
extern fn zozzFixtureFree(data: ?*anyopaque) void;

const fixture_joints = 4;

/// Borrowed view of a serialised fixture archive; free with `deinit`.
const FixtureBlob = struct {
    bytes: []const u8,

    fn init(make: *const fn (*?*anyopaque, *usize) callconv(.c) Result) !FixtureBlob {
        var data: ?*anyopaque = null;
        var size: usize = 0;
        try err.check(make(&data, &size));
        const ptr: [*]const u8 = @ptrCast(data orelse return error.TestUnexpectedResult);
        return .{ .bytes = ptr[0..size] };
    }

    fn deinit(self: FixtureBlob) void {
        zozzFixtureFree(@ptrCast(@constCast(self.bytes.ptr)));
    }
};

//=============================================================================
// Shared assertion body
//=============================================================================

fn expectSaneTransform(t: zozz.Transform) !void {
    for (t.translation) |v| try std.testing.expect(std.math.isFinite(v));
    for (t.scale) |v| try std.testing.expect(std.math.isFinite(v));

    var length_squared: f32 = 0;
    for (t.rotation) |v| {
        try std.testing.expect(std.math.isFinite(v));
        length_squared += v * v;
    }
    // ozz stores rotations compressed; the decompressed quaternion is unit
    // length to within the compression error.
    try std.testing.expectApproxEqAbs(@as(f32, 1), length_squared, 1e-3);
}

/// Everything a loaded skeleton/clip pair must satisfy, whatever its origin.
fn expectPipelineWorks(
    gpa: std.mem.Allocator,
    skeleton: zozz.Skeleton,
    clip: zozz.Animation,
) !void {
    const joints = skeleton.numJoints();
    try std.testing.expect(joints > 0);
    try std.testing.expectEqual((joints + 3) / 4, skeleton.numSoaJoints());

    // Every joint must name itself and point at a parent that precedes it —
    // ozz relies on that ordering for its single-pass local-to-model walk.
    for (0..joints) |i| {
        const joint: u32 = @intCast(i);
        try std.testing.expect(skeleton.jointName(joint) != null);
        const parent = skeleton.jointParent(joint);
        try std.testing.expect(parent == zozz.no_parent or parent < @as(i16, @intCast(joint)));
    }
    try std.testing.expect(skeleton.jointName(joints) == null);

    const rest = try gpa.alloc(zozz.Transform, joints);
    defer gpa.free(rest);
    try skeleton.restPose(rest);
    for (rest) |t| try expectSaneTransform(t);

    try std.testing.expect(clip.duration() > 0);
    try std.testing.expect(clip.numTracks() > 0);
    try std.testing.expect(clip.numTracks() <= joints);
    try std.testing.expectEqual(@as(f32, 0), clip.ratioAt(0));
    try std.testing.expectEqual(@as(f32, 1), clip.ratioAt(clip.duration() * 2));

    const pose = try gpa.alloc(zozz.SoaTransform, try zozz.soaBlocks(joints));
    defer gpa.free(pose);
    var context = try zozz.SamplingContext.initForSkeleton(skeleton);
    defer context.deinit();
    try std.testing.expect(context.maxTracks() >= joints);

    const locals = try gpa.alloc(zozz.Transform, joints);
    defer gpa.free(locals);
    const first = try gpa.alloc(zozz.Transform, joints);
    defer gpa.free(first);

    // Model-space output must be 16-byte aligned.
    const models = try gpa.alignedAlloc(zozz.Mat4, .@"16", joints);
    defer gpa.free(models);

    var moved = false;
    for ([_]f32{ 0.0, 0.25, 0.5, 0.75, 1.0 }, 0..) |ratio, step| {
        try skeleton.restPoseSoa(pose);
        try (zozz.SamplingJob{ .animation = clip, .context = context, .ratio = ratio, .out = pose }).run();
        try zozz.pose.toLocalTransforms(pose, locals);
        for (locals) |t| try expectSaneTransform(t);

        if (step == 0) {
            @memcpy(first, locals);
        } else {
            for (first, locals) |a, b| {
                if (@abs(a.translation[0] - b.translation[0]) > 1e-4 or
                    @abs(a.rotation[0] - b.rotation[0]) > 1e-4)
                {
                    moved = true;
                }
            }
        }

        try (zozz.LocalToModelJob{ .skeleton = skeleton, .locals = pose, .root = null, .out = models }).run();
        for (models) |m| {
            for (m.m) |value| try std.testing.expect(std.math.isFinite(value));
        }

        // A root joint has no parent, so its model matrix is its local
        // transform alone: the translation column must match.
        for (0..joints) |i| {
            if (skeleton.jointParent(@intCast(i)) != zozz.no_parent) continue;
            const m = models[i].m;
            try std.testing.expectApproxEqAbs(locals[i].translation[0], m[12], 1e-4);
            try std.testing.expectApproxEqAbs(locals[i].translation[1], m[13], 1e-4);
            try std.testing.expectApproxEqAbs(locals[i].translation[2], m[14], 1e-4);
        }
    }

    // A clip that never moves anything would make every assertion above pass
    // vacuously.
    try std.testing.expect(moved);

    // NaN must be refused rather than poisoning the pose.
    try std.testing.expectError(
        zozz.Error.InvalidArgument,
        (zozz.SamplingJob{ .animation = clip, .context = context, .ratio = std.math.nan(f32), .out = pose }).run(),
    );
}

//=============================================================================
// Tests
//=============================================================================

test "the full pipeline runs against synthetic assets" {
    const gpa = std.testing.allocator;
    try zozz.setAllocator(gpa);
    defer zozz.resetAllocator() catch unreachable;

    const skeleton_blob = try FixtureBlob.init(zozzFixtureSkeleton);
    defer skeleton_blob.deinit();
    const animation_blob = try FixtureBlob.init(zozzFixtureAnimation);
    defer animation_blob.deinit();

    var skeleton = try zozz.Skeleton.initFromMemory(skeleton_blob.bytes);
    defer skeleton.deinit();
    var clip = try zozz.Animation.initFromMemory(animation_blob.bytes);
    defer clip.deinit();

    // The fixture's shape is known, so assert it exactly — this catches a
    // builder or archive change that the generic body would tolerate.
    try std.testing.expectEqual(@as(u32, fixture_joints), skeleton.numJoints());
    try std.testing.expectEqualStrings("root", skeleton.jointName(0).?);
    try std.testing.expectEqual(zozz.no_parent, skeleton.jointParent(0));
    try std.testing.expectEqualStrings("fixture", clip.name());
    try std.testing.expectApproxEqAbs(@as(f32, 1), clip.duration(), 1e-6);

    try expectPipelineWorks(gpa, skeleton, clip);
}

test "the bulk skeleton accessors are ozz's own arrays, not copies" {
    const gpa = std.testing.allocator;
    try zozz.setAllocator(gpa);
    defer zozz.resetAllocator() catch unreachable;

    const skeleton_blob = try FixtureBlob.init(zozzFixtureSkeleton);
    defer skeleton_blob.deinit();
    var skeleton = try zozz.Skeleton.initFromMemory(skeleton_blob.bytes);
    defer skeleton.deinit();

    const parents = skeleton.jointParents();
    const names = skeleton.jointNames();
    const rest = skeleton.jointRestPoses();

    try std.testing.expectEqual(@as(usize, fixture_joints), parents.len);
    try std.testing.expectEqual(@as(usize, fixture_joints), names.len);
    try std.testing.expectEqual(@as(usize, skeleton.numSoaJoints()), rest.len);

    // Every entry agrees with the per-joint accessor it replaces, which is
    // what makes the bulk form a saving rather than a second answer.
    for (0..skeleton.numJoints()) |i| {
        const joint: u32 = @intCast(i);
        try std.testing.expectEqual(skeleton.jointParent(joint), parents[i]);
        try std.testing.expectEqualStrings(
            skeleton.jointName(joint).?,
            std.mem.span(names[i]),
        );
    }

    // Parents are depth-first, so a joint's parent always precedes it. ozz
    // relies on this in every local-to-model walk; nothing else here checks it.
    for (parents, 0..) |parent, i| {
        try std.testing.expect(parent < @as(i16, @intCast(i)));
    }

    // A VIEW, not a copy: the same call twice hands back the same storage, so
    // no allocation happened and the caller may hold it for the skeleton's
    // lifetime. A copying accessor would fail this.
    try std.testing.expectEqual(parents.ptr, skeleton.jointParents().ptr);
    try std.testing.expectEqual(names.ptr, skeleton.jointNames().ptr);
    try std.testing.expectEqual(rest.ptr, skeleton.jointRestPoses().ptr);

    // And it is the same rest pose zozzSkeletonRestPoseSoa copies out, which
    // is the accessor a caller that means to WRITE the pose still needs.
    var copy: [(fixture_joints + 3) / 4]zozz.SoaTransform align(16) = undefined;
    try skeleton.restPoseSoa(&copy);
    try std.testing.expectEqualSlices(zozz.SoaTransform, rest, &copy);
}

test "a sampling context can be reused across clips after invalidation" {
    const gpa = std.testing.allocator;
    try zozz.setAllocator(gpa);
    defer zozz.resetAllocator() catch unreachable;

    const skeleton_blob = try FixtureBlob.init(zozzFixtureSkeleton);
    defer skeleton_blob.deinit();
    const animation_blob = try FixtureBlob.init(zozzFixtureAnimation);
    defer animation_blob.deinit();

    var skeleton = try zozz.Skeleton.initFromMemory(skeleton_blob.bytes);
    defer skeleton.deinit();

    var context = try zozz.SamplingContext.initForSkeleton(skeleton);
    defer context.deinit();
    var pose: [1]zozz.SoaTransform = undefined;

    // Two clips loaded and freed in turn can land on the same address; ozz
    // detects a clip change by pointer identity, so this is exactly the case
    // invalidate() exists for.
    for (0..3) |_| {
        var clip = try zozz.Animation.initFromMemory(animation_blob.bytes);
        defer clip.deinit();

        context.invalidate();
        try skeleton.restPoseSoa(&pose);
        try (zozz.SamplingJob{ .animation = clip, .context = context, .ratio = 0.5, .out = &pose }).run();

        var locals: [fixture_joints]zozz.Transform = undefined;
        try zozz.pose.toLocalTransforms(&pose, &locals);
        for (locals) |t| try expectSaneTransform(t);
    }
}

test "a sampling context can be resized in place and go on sampling correctly" {
    const gpa = std.testing.allocator;
    try zozz.setAllocator(gpa);
    defer zozz.resetAllocator() catch unreachable;

    const skeleton_blob = try FixtureBlob.init(zozzFixtureSkeleton);
    defer skeleton_blob.deinit();
    const animation_blob = try FixtureBlob.init(zozzFixtureAnimation);
    defer animation_blob.deinit();

    var skeleton = try zozz.Skeleton.initFromMemory(skeleton_blob.bytes);
    defer skeleton.deinit();
    var clip = try zozz.Animation.initFromMemory(animation_blob.bytes);
    defer clip.deinit();

    // Oversized on purpose — as if sized for a different, bigger skeleton —
    // then shrunk in place. Reusing the handle instead of destroy + recreate
    // is the whole point of resize(); the capacity actually changing, and
    // the context still sampling correctly afterwards, is what proves it
    // really re-allocated rather than being a no-op.
    var context = try zozz.SamplingContext.init(40);
    defer context.deinit();
    try std.testing.expect(context.maxTracks() >= 40);

    try context.resize(fixture_joints);
    try std.testing.expectEqual(@as(u32, fixture_joints), context.maxTracks());

    var pose: [1]zozz.SoaTransform = undefined;
    try skeleton.restPoseSoa(&pose);
    try (zozz.SamplingJob{ .animation = clip, .context = context, .ratio = 0.5, .out = &pose }).run();

    var locals: [fixture_joints]zozz.Transform = undefined;
    try zozz.pose.toLocalTransforms(&pose, &locals);
    for (locals) |t| try expectSaneTransform(t);

    // Resizing to zero or negative tracks is rejected outright, not silently
    // accepted as an unusable context.
    try std.testing.expectError(zozz.Error.InvalidArgument, context.resize(0));
}

test "a pose smaller than the animation is refused" {
    const gpa = std.testing.allocator;
    try zozz.setAllocator(gpa);
    defer zozz.resetAllocator() catch unreachable;

    const skeleton_blob = try FixtureBlob.init(zozzFixtureSkeleton);
    defer skeleton_blob.deinit();
    const animation_blob = try FixtureBlob.init(zozzFixtureAnimation);
    defer animation_blob.deinit();

    var skeleton = try zozz.Skeleton.initFromMemory(skeleton_blob.bytes);
    defer skeleton.deinit();
    var clip = try zozz.Animation.initFromMemory(animation_blob.bytes);
    defer clip.deinit();

    var context = try zozz.SamplingContext.initForSkeleton(skeleton);
    defer context.deinit();

    // Zero blocks: the fixture's four joints need one. A span too short is
    // refused by the job and by the skeleton's own rest-pose copy, rather
    // than sampled into whatever the caller happened to hand over.
    var too_small: [0]zozz.SoaTransform = undefined;

    try std.testing.expectError(
        zozz.Error.BufferTooSmall,
        (zozz.SamplingJob{ .animation = clip, .context = context, .ratio = 0.5, .out = &too_small }).run(),
    );
    try std.testing.expectError(
        zozz.Error.BufferTooSmall,
        skeleton.restPoseSoa(&too_small),
    );
}

test "the full pipeline runs against .ozz files on disk" {
    // Opt-in: needs -Dskeleton_path and -Danimation_path. Useful for checking
    // a specific asset, or a specific archive version, against the same bar
    // the fixture is held to.
    const skeleton_path = test_options.skeleton_path orelse return error.SkipZigTest;
    const animation_path = test_options.animation_path orelse return error.SkipZigTest;

    const gpa = std.testing.allocator;
    try zozz.setAllocator(gpa);
    defer zozz.resetAllocator() catch unreachable;

    var skeleton_buf: [std.fs.max_path_bytes]u8 = undefined;
    var animation_buf: [std.fs.max_path_bytes]u8 = undefined;

    const skeleton = try zozz.Skeleton.initFromFile(
        try std.fmt.bufPrintZ(&skeleton_buf, "{s}", .{skeleton_path}),
    );
    defer skeleton.deinit();
    const clip = try zozz.Animation.initFromFile(
        try std.fmt.bufPrintZ(&animation_buf, "{s}", .{animation_path}),
    );
    defer clip.deinit();

    try expectPipelineWorks(gpa, skeleton, clip);
}

test "a truncated archive is refused rather than trusted" {
    // A VALID archive cut short: the tag passes, then reads run past the end.
    // ozz ignores short reads under NDEBUG, so a bogus length is trusted.
    // ConstMemoryStream zero-fills past the end and latches a flag the loader
    // checks; this walks every fixture prefix, requiring none load. Skipped
    // under the C sanitizer, off by default: upstream ozz null-derefs on a
    // zero-entry keyframe array here, and `-Dsanitize_c=true` turns it on.
    if (zozz.options.sanitize_c) return error.SkipZigTest;

    const gpa = std.testing.allocator;
    try zozz.setAllocator(gpa);
    defer zozz.resetAllocator() catch unreachable;

    const skeleton_blob = try FixtureBlob.init(zozzFixtureSkeleton);
    defer skeleton_blob.deinit();
    const animation_blob = try FixtureBlob.init(zozzFixtureAnimation);
    defer animation_blob.deinit();

    var len: usize = 1;
    while (len < skeleton_blob.bytes.len) : (len += 1) {
        if (zozz.Skeleton.initFromMemory(skeleton_blob.bytes[0..len])) |loaded| {
            var accepted = loaded;
            accepted.deinit();
            std.debug.print("truncated skeleton accepted at {d} bytes\n", .{len});
            return error.TestUnexpectedResult;
        } else |_| {}
    }

    len = 1;
    while (len < animation_blob.bytes.len) : (len += 1) {
        if (zozz.Animation.initFromMemory(animation_blob.bytes[0..len])) |loaded| {
            var accepted = loaded;
            accepted.deinit();
            std.debug.print("truncated animation accepted at {d} bytes\n", .{len});
            return error.TestUnexpectedResult;
        } else |_| {}
    }

    // The complete archives must still load, so the test cannot pass by
    // rejecting everything.
    var whole_skeleton = try zozz.Skeleton.initFromMemory(skeleton_blob.bytes);
    whole_skeleton.deinit();
    var whole_animation = try zozz.Animation.initFromMemory(animation_blob.bytes);
    whole_animation.deinit();
}

//=============================================================================
// Archive write path
//=============================================================================

/// A growable in-memory destination implementing `zozz.Stream`, so the write
/// path is exercised through the same host-bridge seam a real consumer would
/// use — not through the file convenience, which never touches the bridge.
const WriteBuffer = struct {
    list: std.ArrayList(u8) = .empty,
    gpa: std.mem.Allocator,

    fn deinit(self: *WriteBuffer) void {
        self.list.deinit(self.gpa);
    }

    fn opened(user: ?*anyopaque) callconv(.c) c_int {
        _ = user;
        return 1;
    }

    fn write(user: ?*anyopaque, data: ?*const anyopaque, size: usize) callconv(.c) usize {
        const self: *WriteBuffer = @ptrCast(@alignCast(user orelse return 0));
        const bytes: [*]const u8 = @ptrCast(data orelse return 0);
        self.list.appendSlice(self.gpa, bytes[0..size]) catch return 0;
        return size;
    }

    fn stream(self: *WriteBuffer) zozz.Stream {
        return .{ .opened = &opened, .write = &write, .read = null, .seek = null, .tell = null, .user = self };
    }
};

test "an animation written through the archive and read back compares equal to the original" {
    const gpa = std.testing.allocator;
    try zozz.setAllocator(gpa);
    defer zozz.resetAllocator() catch unreachable;

    const animation_blob = try FixtureBlob.init(zozzFixtureAnimation);
    defer animation_blob.deinit();

    var original = try zozz.Animation.initFromMemory(animation_blob.bytes);
    defer original.deinit();

    var buffer: WriteBuffer = .{ .gpa = gpa };
    defer buffer.deinit();
    const bridge = buffer.stream();

    var archive = try zozz.OArchive.init(&bridge, zozz.nativeEndianness());
    try archive.saveAnimation(original);
    archive.deinit();

    // The write path reproduces the exact archive ozz's own serialisation
    // does: same tag, same version, same bytes, not merely a
    // similarly-shaped one.
    try std.testing.expectEqualSlices(u8, animation_blob.bytes, buffer.list.items);

    var roundtripped = try zozz.Animation.initFromMemory(buffer.list.items);
    defer roundtripped.deinit();

    try std.testing.expectEqualStrings(original.name(), roundtripped.name());
    try std.testing.expectEqual(original.duration(), roundtripped.duration());
    try std.testing.expectEqual(original.numTracks(), roundtripped.numTracks());

    // Sampling must behave identically too, not just report identical
    // metadata. Two contexts, one per clip instance, sidestep the
    // pointer-identity cache invalidation a single shared context would need
    // on every swap between the two.
    var context_a = try zozz.SamplingContext.init(original.numTracks());
    defer context_a.deinit();
    var context_b = try zozz.SamplingContext.init(roundtripped.numTracks());
    defer context_b.deinit();
    var pose_a: [1]zozz.SoaTransform = undefined;
    var pose_b: [1]zozz.SoaTransform = undefined;

    var locals_a: [fixture_joints]zozz.Transform = undefined;
    var locals_b: [fixture_joints]zozz.Transform = undefined;
    for ([_]f32{ 0.0, 0.3, 0.5, 0.75, 1.0 }) |ratio| {
        try (zozz.SamplingJob{ .animation = original, .context = context_a, .ratio = ratio, .out = &pose_a }).run();
        try zozz.pose.toLocalTransforms(&pose_a, &locals_a);

        try (zozz.SamplingJob{ .animation = roundtripped, .context = context_b, .ratio = ratio, .out = &pose_b }).run();
        try zozz.pose.toLocalTransforms(&pose_b, &locals_b);

        for (locals_a, locals_b) |a, b| {
            try std.testing.expectEqual(a.translation, b.translation);
            try std.testing.expectEqual(a.rotation, b.rotation);
            try std.testing.expectEqual(a.scale, b.scale);
        }
    }
}
