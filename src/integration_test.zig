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
        try err.map(make(&data, &size));
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
    var failure: zozz.Failure = .{};
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
    try skeleton.restPose(rest, &failure);
    for (rest) |t| try expectSaneTransform(t);

    try std.testing.expect(clip.duration() > 0);
    try std.testing.expect(clip.numTracks() > 0);
    try std.testing.expect(clip.numTracks() <= joints);
    try std.testing.expectEqual(@as(f32, 0), clip.ratioAt(0, .clamp));
    try std.testing.expectEqual(@as(f32, 1), clip.ratioAt(clip.duration() * 2, .clamp));

    // Looping wraps in both directions, and the seam is exact: two clips in
    // is the start again, and a quarter clip BEFORE the start is three
    // quarters through, not clamped to zero and not a negative ratio.
    const total = clip.duration();
    try std.testing.expectApproxEqAbs(@as(f32, 0), clip.ratioAt(total * 2, .loop), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), clip.ratioAt(total * 2.5, .loop), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), clip.ratioAt(-total * 0.25, .loop), 1e-6);
    for ([_]zozz.TimeMode{ .clamp, .loop }) |mode| {
        const r = clip.ratioAt(std.math.inf(f32), mode);
        try std.testing.expect(r >= 0 and r <= 1);
    }

    const pose = try gpa.alloc(zozz.SoaTransform, try zozz.soaBlocks(joints, &failure));
    defer gpa.free(pose);
    var context = try zozz.SamplingContext.initForSkeleton(skeleton, &failure);
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
        try skeleton.restPoseSoa(pose, &failure);
        try (zozz.SamplingJob{ .animation = clip, .context = context, .ratio = ratio, .out = pose }).run(&failure);
        try zozz.pose.toLocalTransforms(pose, locals, &failure);
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

        try (zozz.LocalToModelJob{ .skeleton = skeleton, .locals = pose, .root = null, .out = models }).run(&failure);
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
        (zozz.SamplingJob{ .animation = clip, .context = context, .ratio = std.math.nan(f32), .out = pose }).run(&failure),
    );
    try std.testing.expectEqualSlices(zozz.Frame, &.{.{ .call = .sample, .result = .invalid_argument }}, failure.frames());
}

//=============================================================================
// Tests
//=============================================================================

test "the full pipeline runs against synthetic assets" {
    var failure: zozz.Failure = .{};
    const gpa = std.testing.allocator;
    try zozz.setAllocator(gpa, &failure);
    defer zozz.resetAllocator(&failure) catch |e| std.debug.panic("zozz: {s}", .{@errorName(e)});

    const skeleton_blob = try FixtureBlob.init(zozzFixtureSkeleton);
    defer skeleton_blob.deinit();
    const animation_blob = try FixtureBlob.init(zozzFixtureAnimation);
    defer animation_blob.deinit();

    var skeleton = try zozz.Skeleton.initFromMemory(.init(skeleton_blob.bytes), &failure);
    defer skeleton.deinit();
    var clip = try zozz.Animation.initFromMemory(.init(animation_blob.bytes), &failure);
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
    var failure: zozz.Failure = .{};
    const gpa = std.testing.allocator;
    try zozz.setAllocator(gpa, &failure);
    defer zozz.resetAllocator(&failure) catch |e| std.debug.panic("zozz: {s}", .{@errorName(e)});

    const skeleton_blob = try FixtureBlob.init(zozzFixtureSkeleton);
    defer skeleton_blob.deinit();
    var skeleton = try zozz.Skeleton.initFromMemory(.init(skeleton_blob.bytes), &failure);
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
    try skeleton.restPoseSoa(&copy, &failure);
    try std.testing.expectEqualSlices(zozz.SoaTransform, rest, &copy);
}

test "a sampling context can be reused across clips after invalidation" {
    var failure: zozz.Failure = .{};
    const gpa = std.testing.allocator;
    try zozz.setAllocator(gpa, &failure);
    defer zozz.resetAllocator(&failure) catch |e| std.debug.panic("zozz: {s}", .{@errorName(e)});

    const skeleton_blob = try FixtureBlob.init(zozzFixtureSkeleton);
    defer skeleton_blob.deinit();
    const animation_blob = try FixtureBlob.init(zozzFixtureAnimation);
    defer animation_blob.deinit();

    var skeleton = try zozz.Skeleton.initFromMemory(.init(skeleton_blob.bytes), &failure);
    defer skeleton.deinit();

    var context = try zozz.SamplingContext.initForSkeleton(skeleton, &failure);
    defer context.deinit();
    var pose: [1]zozz.SoaTransform = undefined;

    // Two clips loaded and freed in turn can land on the same address; ozz
    // detects a clip change by pointer identity, so this is exactly the case
    // invalidate() exists for.
    for (0..3) |_| {
        var clip = try zozz.Animation.initFromMemory(.init(animation_blob.bytes), &failure);
        defer clip.deinit();

        context.invalidate();
        try skeleton.restPoseSoa(&pose, &failure);
        try (zozz.SamplingJob{ .animation = clip, .context = context, .ratio = 0.5, .out = &pose }).run(&failure);

        var locals: [fixture_joints]zozz.Transform = undefined;
        try zozz.pose.toLocalTransforms(&pose, &locals, &failure);
        for (locals) |t| try expectSaneTransform(t);
    }
}

test "a sampling context can be resized in place and go on sampling correctly" {
    var failure: zozz.Failure = .{};
    const gpa = std.testing.allocator;
    try zozz.setAllocator(gpa, &failure);
    defer zozz.resetAllocator(&failure) catch |e| std.debug.panic("zozz: {s}", .{@errorName(e)});

    const skeleton_blob = try FixtureBlob.init(zozzFixtureSkeleton);
    defer skeleton_blob.deinit();
    const animation_blob = try FixtureBlob.init(zozzFixtureAnimation);
    defer animation_blob.deinit();

    var skeleton = try zozz.Skeleton.initFromMemory(.init(skeleton_blob.bytes), &failure);
    defer skeleton.deinit();
    var clip = try zozz.Animation.initFromMemory(.init(animation_blob.bytes), &failure);
    defer clip.deinit();

    // Oversized on purpose — as if sized for a different, bigger skeleton —
    // then shrunk in place. Reusing the handle instead of destroy + recreate
    // is the whole point of resize(); the capacity actually changing, and
    // the context still sampling correctly afterwards, is what proves it
    // really re-allocated rather than being a no-op.
    var context = try zozz.SamplingContext.init(40, &failure);
    defer context.deinit();
    try std.testing.expect(context.maxTracks() >= 40);

    try context.resize(fixture_joints, &failure);
    try std.testing.expectEqual(@as(u32, fixture_joints), context.maxTracks());

    var pose: [1]zozz.SoaTransform = undefined;
    try skeleton.restPoseSoa(&pose, &failure);
    try (zozz.SamplingJob{ .animation = clip, .context = context, .ratio = 0.5, .out = &pose }).run(&failure);

    var locals: [fixture_joints]zozz.Transform = undefined;
    try zozz.pose.toLocalTransforms(&pose, &locals, &failure);
    for (locals) |t| try expectSaneTransform(t);

    // Resizing to zero or negative tracks is rejected outright, not silently
    // accepted as an unusable context.
    try std.testing.expectError(zozz.Error.InvalidArgument, context.resize(0, &failure));
    try std.testing.expectEqualSlices(zozz.Frame, &.{.{ .call = .sampling_context_resize, .result = .invalid_argument }}, failure.frames());
}

test "a pose smaller than the animation is refused" {
    var failure: zozz.Failure = .{};
    const gpa = std.testing.allocator;
    try zozz.setAllocator(gpa, &failure);
    defer zozz.resetAllocator(&failure) catch |e| std.debug.panic("zozz: {s}", .{@errorName(e)});

    const skeleton_blob = try FixtureBlob.init(zozzFixtureSkeleton);
    defer skeleton_blob.deinit();
    const animation_blob = try FixtureBlob.init(zozzFixtureAnimation);
    defer animation_blob.deinit();

    var skeleton = try zozz.Skeleton.initFromMemory(.init(skeleton_blob.bytes), &failure);
    defer skeleton.deinit();
    var clip = try zozz.Animation.initFromMemory(.init(animation_blob.bytes), &failure);
    defer clip.deinit();

    var context = try zozz.SamplingContext.initForSkeleton(skeleton, &failure);
    defer context.deinit();

    // Zero blocks: the fixture's four joints need one. A span too short is
    // refused by the job and by the skeleton's own rest-pose copy, rather
    // than sampled into whatever the caller happened to hand over.
    var too_small: [0]zozz.SoaTransform = undefined;

    try std.testing.expectError(
        zozz.Error.BufferTooSmall,
        (zozz.SamplingJob{ .animation = clip, .context = context, .ratio = 0.5, .out = &too_small }).run(&failure),
    );
    try std.testing.expectEqualSlices(zozz.Frame, &.{.{ .call = .sample, .result = .buffer_too_small }}, failure.frames());
    failure.reset();
    try std.testing.expectError(
        zozz.Error.BufferTooSmall,
        skeleton.restPoseSoa(&too_small, &failure),
    );
    try std.testing.expectEqualSlices(zozz.Frame, &.{.{ .call = .skeleton_rest_pose_soa, .result = .buffer_too_small }}, failure.frames());
}

test "the full pipeline runs against .ozz files on disk" {
    var failure: zozz.Failure = .{};
    // Opt-in: needs -Dskeleton_path and -Danimation_path. Useful for checking
    // a specific asset, or a specific archive version, against the same bar
    // the fixture is held to.
    const skeleton_path = test_options.skeleton_path orelse return error.SkipZigTest;
    const animation_path = test_options.animation_path orelse return error.SkipZigTest;

    const gpa = std.testing.allocator;
    try zozz.setAllocator(gpa, &failure);
    defer zozz.resetAllocator(&failure) catch |e| std.debug.panic("zozz: {s}", .{@errorName(e)});

    var skeleton_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var animation_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;

    const skeleton = try zozz.Skeleton.initFromFile(
        try std.fmt.bufPrintZ(&skeleton_buf, "{s}", .{skeleton_path}),
        &failure,
    );
    defer skeleton.deinit();
    const clip = try zozz.Animation.initFromFile(
        try std.fmt.bufPrintZ(&animation_buf, "{s}", .{animation_path}),
        &failure,
    );
    defer clip.deinit();

    try expectPipelineWorks(gpa, skeleton, clip);
}

test "a truncated archive is refused rather than trusted" {
    var failure: zozz.Failure = .{};
    // A VALID archive cut short: the tag passes, then reads run past the end.
    // ozz ignores short reads under NDEBUG, so a bogus length is trusted.
    // ConstMemoryStream zero-fills past the end and latches a flag the loader
    // checks; this walks every fixture prefix, requiring none load. Skipped
    // under the C sanitizer, off by default: upstream ozz null-derefs on a
    // zero-entry keyframe array here, and `-Dsanitize_c=true` turns it on.
    if (zozz.options.sanitize_c) return error.SkipZigTest;

    const gpa = std.testing.allocator;
    try zozz.setAllocator(gpa, &failure);
    defer zozz.resetAllocator(&failure) catch |e| std.debug.panic("zozz: {s}", .{@errorName(e)});

    const skeleton_blob = try FixtureBlob.init(zozzFixtureSkeleton);
    defer skeleton_blob.deinit();
    const animation_blob = try FixtureBlob.init(zozzFixtureAnimation);
    defer animation_blob.deinit();

    var len: usize = 1;
    while (len < skeleton_blob.bytes.len) : (len += 1) {
        if (zozz.Skeleton.initFromMemory(.init(skeleton_blob.bytes[0..len]), &failure)) |loaded| {
            var accepted = loaded;
            accepted.deinit();
            std.debug.print("truncated skeleton accepted at {d} bytes\n", .{len});
            return error.TestUnexpectedResult;
        } else |_| {}
    }

    len = 1;
    while (len < animation_blob.bytes.len) : (len += 1) {
        if (zozz.Animation.initFromMemory(.init(animation_blob.bytes[0..len]), &failure)) |loaded| {
            var accepted = loaded;
            accepted.deinit();
            std.debug.print("truncated animation accepted at {d} bytes\n", .{len});
            return error.TestUnexpectedResult;
        } else |_| {}
    }

    // The complete archives must still load, so the test cannot pass by
    // rejecting everything.
    var whole_skeleton = try zozz.Skeleton.initFromMemory(.init(skeleton_blob.bytes), &failure);
    whole_skeleton.deinit();
    var whole_animation = try zozz.Animation.initFromMemory(.init(animation_blob.bytes), &failure);
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
    var failure: zozz.Failure = .{};
    const gpa = std.testing.allocator;
    try zozz.setAllocator(gpa, &failure);
    defer zozz.resetAllocator(&failure) catch |e| std.debug.panic("zozz: {s}", .{@errorName(e)});

    const animation_blob = try FixtureBlob.init(zozzFixtureAnimation);
    defer animation_blob.deinit();

    var original = try zozz.Animation.initFromMemory(.init(animation_blob.bytes), &failure);
    defer original.deinit();

    var buffer: WriteBuffer = .{ .gpa = gpa };
    defer buffer.deinit();
    const bridge = buffer.stream();

    var archive = try zozz.OArchive.init(&bridge, zozz.nativeEndianness(), &failure);
    try archive.saveAnimation(original, &failure);
    archive.deinit();

    // The write path reproduces the exact archive ozz's own serialisation
    // does: same tag, same version, same bytes, not merely a
    // similarly-shaped one.
    try std.testing.expectEqualSlices(u8, animation_blob.bytes, buffer.list.items);

    var roundtripped = try zozz.Animation.initFromMemory(.init(buffer.list.items), &failure);
    defer roundtripped.deinit();

    try std.testing.expectEqualStrings(original.name(), roundtripped.name());
    try std.testing.expectEqual(original.duration(), roundtripped.duration());
    try std.testing.expectEqual(original.numTracks(), roundtripped.numTracks());

    // Sampling must behave identically too, not just report identical
    // metadata. Two contexts, one per clip instance, sidestep the
    // pointer-identity cache invalidation a single shared context would need
    // on every swap between the two.
    var context_a = try zozz.SamplingContext.init(original.numTracks(), &failure);
    defer context_a.deinit();
    var context_b = try zozz.SamplingContext.init(roundtripped.numTracks(), &failure);
    defer context_b.deinit();
    var pose_a: [1]zozz.SoaTransform = undefined;
    var pose_b: [1]zozz.SoaTransform = undefined;

    var locals_a: [fixture_joints]zozz.Transform = undefined;
    var locals_b: [fixture_joints]zozz.Transform = undefined;
    for ([_]f32{ 0.0, 0.3, 0.5, 0.75, 1.0 }) |ratio| {
        try (zozz.SamplingJob{ .animation = original, .context = context_a, .ratio = ratio, .out = &pose_a }).run(&failure);
        try zozz.pose.toLocalTransforms(&pose_a, &locals_a, &failure);

        try (zozz.SamplingJob{ .animation = roundtripped, .context = context_b, .ratio = ratio, .out = &pose_b }).run(&failure);
        try zozz.pose.toLocalTransforms(&pose_b, &locals_b, &failure);

        for (locals_a, locals_b) |a, b| {
            try std.testing.expectEqual(a.translation, b.translation);
            try std.testing.expectEqual(a.rotation, b.rotation);
            try std.testing.expectEqual(a.scale, b.scale);
        }
    }
}

//=============================================================================
// The refusal record
//=============================================================================

/// An honest skeleton archive of `joints` joints, laid out as ozz's
/// `Skeleton::Save` writes one (src/animation/runtime/skeleton.cc): the
/// endianness byte, the tag with its NUL, version 2, the joint and name-byte
/// counts, an empty name and a root parent per joint, and zeroed SoA rest
/// poses, one block per four joints.
fn skeletonArchive(gpa: std.mem.Allocator, comptime joints: u16) ![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(gpa);
    try bytes.append(gpa, switch (std.lang.Endian.native) {
        .big => 0,
        .little => 1,
    });
    try bytes.appendSlice(gpa, "ozz-skeleton\x00");
    const version: u32 = 2;
    const count: i32 = joints;
    try bytes.appendSlice(gpa, std.mem.asBytes(&version));
    try bytes.appendSlice(gpa, std.mem.asBytes(&count));
    try bytes.appendSlice(gpa, std.mem.asBytes(&count));
    try bytes.appendNTimes(gpa, 0, joints);
    const root: i16 = zozz.c.no_parent;
    for (0..joints) |_| try bytes.appendSlice(gpa, std.mem.asBytes(&root));
    try bytes.appendNTimes(gpa, 0, (joints + 3) / 4 * @sizeOf(zozz.SoaTransform));
    return bytes.toOwnedSlice(gpa);
}

/// A read-only `zozz.Stream` over borrowed bytes, for the IArchive path.
const ReadBuffer = struct {
    bytes: []const u8,
    pos: usize = 0,

    fn opened(user: ?*anyopaque) callconv(.c) c_int {
        _ = user;
        return 1;
    }

    fn read(user: ?*anyopaque, buffer: ?*anyopaque, size: usize) callconv(.c) usize {
        const self: *ReadBuffer = @ptrCast(@alignCast(user orelse return 0));
        const out: [*]u8 = @ptrCast(buffer orelse return 0);
        const n = @min(self.bytes.len - self.pos, size);
        @memcpy(out[0..n], self.bytes[self.pos..][0..n]);
        self.pos += n;
        return n;
    }

    fn seek(user: ?*anyopaque, offset: c_int, origin: zozz.SeekOrigin) callconv(.c) c_int {
        const self: *ReadBuffer = @ptrCast(@alignCast(user orelse return -1));
        const base: i64 = switch (origin) {
            .current => @intCast(self.pos),
            .end => @intCast(self.bytes.len),
            .set => 0,
        };
        const target = base + offset;
        if (target < 0 or target > @as(i64, @intCast(self.bytes.len))) return -1;
        self.pos = @intCast(target);
        return 0;
    }

    fn tell(user: ?*anyopaque) callconv(.c) c_int {
        const self: *ReadBuffer = @ptrCast(@alignCast(user orelse return -1));
        return @intCast(self.pos);
    }

    fn stream(self: *ReadBuffer) zozz.Stream {
        return .{ .opened = &opened, .write = null, .read = &read, .seek = &seek, .tell = &tell, .user = self };
    }
};

/// What a caller left in its record before a load, which the load must not
/// hand back.
const stale_refusal: zozz.c.Refusal = .{ .what = "stale", .value = 7, .limit = 9 };

fn expectCleared(refusal: zozz.c.Refusal) !void {
    try std.testing.expectEqual(@as(?[*:0]const u8, null), refusal.what);
    try std.testing.expectEqual(@as(u64, 0), refusal.value);
    try std.testing.expectEqual(@as(u64, 0), refusal.limit);
}

fn expectRefusal(frame: zozz.Frame, call: err.Call, what: []const u8, value: u64, limit: u64) !void {
    try std.testing.expectEqual(call, frame.call);
    try std.testing.expectEqual(zozz.c.Result.bad_format, frame.result);
    try std.testing.expectEqualStrings(what, frame.refusal.named() orelse return error.TestUnexpectedResult);
    try std.testing.expectEqual(value, frame.refusal.value);
    try std.testing.expectEqual(limit, frame.refusal.limit);
}

test "a loader clears the caller's refusal record on every outcome but a content refusal" {
    var failure: zozz.Failure = .{};
    const gpa = std.testing.allocator;
    try zozz.setAllocator(gpa, &failure);
    defer zozz.resetAllocator(&failure) catch |e| std.debug.panic("zozz: {s}", .{@errorName(e)});

    const blob = try FixtureBlob.init(zozzFixtureSkeleton);
    defer blob.deinit();
    const bytes = blob.bytes;
    var handle: *zozz.c.Skeleton = undefined;

    var refusal = stale_refusal;
    try std.testing.expectEqual(zozz.c.Result.ok, zozz.c.zozzSkeletonLoadMemory(bytes.ptr, bytes.len, &handle, &refusal));
    zozz.c.zozzSkeletonDestroy(handle);
    try expectCleared(refusal);

    // An archive cut where no count reaches is refused, but not for its
    // content: the stream ran short.
    refusal = stale_refusal;
    try std.testing.expectEqual(zozz.c.Result.io, zozz.c.zozzSkeletonLoadMemory(bytes.ptr, bytes.len - 1, &handle, &refusal));
    try expectCleared(refusal);

    // Cut through its counts, it ends before what they claim: IO, naming the
    // count and what fits.
    refusal = stale_refusal;
    try std.testing.expectEqual(zozz.c.Result.io, zozz.c.zozzSkeletonLoadMemory(bytes.ptr, bytes.len / 2, &handle, &refusal));
    try std.testing.expect(refusal.what != null);
    try std.testing.expect(refusal.limit < refusal.value);

    refusal = stale_refusal;
    try std.testing.expectEqual(zozz.c.Result.file_not_found, zozz.c.zozzSkeletonLoadFile("/nonexistent/zozz/skeleton.ozz", &handle, &refusal));
    try expectCleared(refusal);

    refusal = stale_refusal;
    try std.testing.expectEqual(zozz.c.Result.invalid_argument, zozz.c.zozzSkeletonLoadMemory(bytes.ptr, 0, &handle, &refusal));
    try expectCleared(refusal);

    // NULL asks for no record.
    try std.testing.expectEqual(zozz.c.Result.ok, zozz.c.zozzSkeletonLoadMemory(bytes.ptr, bytes.len, &handle, null));
    zozz.c.zozzSkeletonDestroy(handle);

    // Through the wrapper, a refusal that is not about content carries none.
    if (zozz.Skeleton.initFromMemory(.init(bytes[0 .. bytes.len - 1]), &failure)) |accepted| {
        var skeleton = accepted;
        skeleton.deinit();
        return error.TestUnexpectedResult;
    } else |_| {}
    try std.testing.expectEqual(@as(usize, 1), failure.frames().len);
    try std.testing.expectEqual(@as(?[]const u8, null), failure.frames()[0].refusal.named());
}

test "a content refusal names the count, what the archive held and the bound it broke" {
    var failure: zozz.Failure = .{};
    const gpa = std.testing.allocator;
    try zozz.setAllocator(gpa, &failure);
    defer zozz.resetAllocator(&failure) catch |e| std.debug.panic("zozz: {s}", .{@errorName(e)});

    // At the limit the same layout loads, so what refuses the next archive is
    // its count and nothing else about it.
    const at_limit = try skeletonArchive(gpa, zozz.c.max_joints);
    defer gpa.free(at_limit);
    var loaded = try zozz.Skeleton.initFromMemory(.init(at_limit), &failure);
    try std.testing.expectEqual(@as(u32, zozz.c.max_joints), loaded.numJoints());
    loaded.deinit();

    const over = try skeletonArchive(gpa, zozz.c.max_joints + 1);
    defer gpa.free(over);
    try std.testing.expectError(err.Error.BadFormat, zozz.Skeleton.initFromMemory(.init(over), &failure));
    try std.testing.expectEqual(@as(usize, 1), failure.frames().len);
    try expectRefusal(failure.frames()[0], .skeleton_load_memory, "Skeleton.num_joints", zozz.c.max_joints + 1, zozz.c.max_joints);
    failure.reset();

    // The C ABI fills the caller's record itself.
    var refusal = stale_refusal;
    var handle: *zozz.c.Skeleton = undefined;
    try std.testing.expectEqual(zozz.c.Result.bad_format, zozz.c.zozzSkeletonLoadMemory(over.ptr, over.len, &handle, &refusal));
    try std.testing.expectEqualStrings("Skeleton.num_joints", std.mem.span(refusal.what orelse return error.TestUnexpectedResult));
    try std.testing.expectEqual(@as(u64, zozz.c.max_joints + 1), refusal.value);
    try std.testing.expectEqual(@as(u64, zozz.c.max_joints), refusal.limit);

    // And so does a host's stream, through IArchive.
    var reader: ReadBuffer = .{ .bytes = over };
    const bridge = reader.stream();
    var in_archive = try zozz.IArchive.init(.init(&bridge), &failure);
    defer in_archive.deinit();
    try std.testing.expectError(err.Error.BadFormat, in_archive.loadSkeleton(&failure));
    try std.testing.expectEqual(@as(usize, 1), failure.frames().len);
    try expectRefusal(failure.frames()[0], .i_archive_load_skeleton, "Skeleton.num_joints", zozz.c.max_joints + 1, zozz.c.max_joints);
}

//=============================================================================
// Versions and counts (libs/patches/ozz-archive-counts.patch)
//=============================================================================

const archives = @import("testing/archives.zig");

fn expectRecord(frame: zozz.Frame, call: err.Call, result: zozz.c.Result, what: []const u8, value: u64, limit: u64) !void {
    try std.testing.expectEqual(call, frame.call);
    try std.testing.expectEqual(result, frame.result);
    try std.testing.expectEqualStrings(what, frame.refusal.named() orelse return error.TestUnexpectedResult);
    try std.testing.expectEqual(value, frame.refusal.value);
    try std.testing.expectEqual(limit, frame.refusal.limit);
}

/// Loads `bytes` as a `T` through its Zig wrapper, expecting `e` and one
/// frame carrying the record named. An object that loads is not freed: the
/// test has failed, and the leak report says so a second time.
fn expectLoadRefused(comptime T: type, bytes: []const u8, call: err.Call, e: err.Error, what: []const u8, value: u64, limit: u64) !void {
    var failure: zozz.Failure = .{};
    if (T.initFromMemory(.init(bytes), &failure)) |_| {
        return error.TestUnexpectedResult;
    } else |got| try std.testing.expectEqual(e, got);
    try std.testing.expectEqual(@as(usize, 1), failure.frames().len);
    try expectRecord(failure.frames()[0], call, err.resultOf(e), what, value, limit);
}

test "a version ozz cannot read is refused, not loaded as an empty object" {
    var failure: zozz.Failure = .{};
    const gpa = std.testing.allocator;
    try zozz.setAllocator(gpa, &failure);
    defer zozz.resetAllocator(&failure) catch |e| std.debug.panic("zozz: {s}", .{@errorName(e)});

    var skeleton: archives.Writer = try .init(gpa, "ozz-skeleton", 3);
    defer skeleton.deinit();
    try expectLoadRefused(zozz.Skeleton, skeleton.bytes.items, .skeleton_load_memory, err.Error.BadFormat, "Skeleton.version", 3, 2);

    var animation: archives.Writer = try .init(gpa, "ozz-animation", 6);
    defer animation.deinit();
    try expectLoadRefused(zozz.Animation, animation.bytes.items, .animation_load_memory, err.Error.BadFormat, "Animation.version", 6, 7);

    var track: archives.Writer = try .init(gpa, "ozz-float_track", 2);
    defer track.deinit();
    try expectLoadRefused(zozz.FloatTrack, track.bytes.items, .float_track_load_memory, err.Error.BadFormat, "Track.version", 2, 1);

    var raw: archives.Writer = try .init(gpa, "ozz-raw_skeleton", 2);
    defer raw.deinit();
    try expectLoadRefused(zozz.RawSkeleton, raw.bytes.items, .raw_skeleton_load_memory, err.Error.BadFormat, "RawSkeleton.version", 2, 1);
}

test "a count outside what ozz can hold is refused before Load allocates for it" {
    var failure: zozz.Failure = .{};
    const gpa = std.testing.allocator;
    try zozz.setAllocator(gpa, &failure);
    defer zozz.resetAllocator(&failure) catch |e| std.debug.panic("zozz: {s}", .{@errorName(e)});

    // More timepoints than a uint16 ratio index can name, with the bytes to
    // hold them, so ozz's limit is the bound and not the archive's length.
    const timepoints = std.math.maxInt(u16) + 1;
    var animation = try archives.animationHeader(gpa, .{ 0, timepoints, 0, 0, 0, 0, 0, 0, 0, 0, 0 });
    defer animation.deinit();
    try animation.zeros(timepoints * @sizeOf(f32));
    try expectLoadRefused(zozz.Animation, animation.bytes.items, .animation_load_memory, err.Error.BadFormat, "Animation.timepoints_count", timepoints, std.math.maxInt(u16));

    // Four joints cannot be named in one byte.
    var skeleton = try archives.skeleton(gpa, 4, 1);
    defer skeleton.deinit();
    try expectLoadRefused(zozz.Skeleton, skeleton.bytes.items, .skeleton_load_memory, err.Error.BadFormat, "Skeleton.chars_count", 1, 4);
}

test "a count past the bytes left is an archive that ends early, and the frame says which" {
    var failure: zozz.Failure = .{};
    const gpa = std.testing.allocator;
    try zozz.setAllocator(gpa, &failure);
    defer zozz.resetAllocator(&failure) catch |e| std.debug.panic("zozz: {s}", .{@errorName(e)});

    // The fuzzer's crash: a negative name-block size, read as a count, sized
    // the skeleton's allocation (skeleton.cc, Allocate).
    var skeleton = try archives.skeleton(gpa, 1, -1);
    defer skeleton.deinit();
    const after_count = 1 + @sizeOf(i16) + 160;
    try expectLoadRefused(zozz.Skeleton, skeleton.bytes.items, .skeleton_load_memory, err.Error.ReadFailed, "Skeleton.chars_count", std.math.maxInt(u32), after_count);

    var track = try archives.floatTrackHeader(gpa, 1000, 0);
    defer track.deinit();
    try expectLoadRefused(zozz.FloatTrack, track.bytes.items, .float_track_load_memory, err.Error.ReadFailed, "Track.num_keys", 1000, 0);

    // A host's stream knows its length too.
    var reader: ReadBuffer = .{ .bytes = track.bytes.items };
    const bridge = reader.stream();
    var in_archive = try zozz.IArchive.init(.init(&bridge), &failure);
    defer in_archive.deinit();
    try std.testing.expectError(err.Error.ReadFailed, in_archive.loadFloatTrack(&failure));
    try std.testing.expectEqual(@as(usize, 1), failure.frames().len);
    try expectRecord(failure.frames()[0], .i_archive_load_float_track, .io, "Track.num_keys", 1000, 0);
}

test "every vector and string a raw archive sizes is checked before it is resized" {
    // A standard container has no way to report an allocation zozz's
    // allocator refused (design.md), so no count read from an archive may
    // reach a resize unchecked.
    var failure: zozz.Failure = .{};
    const gpa = std.testing.allocator;
    try zozz.setAllocator(gpa, &failure);
    defer zozz.resetAllocator(&failure) catch |e| std.debug.panic("zozz: {s}", .{@errorName(e)});

    const count = std.math.maxInt(i32);
    const Load = *const fn ([*]const u8, usize, *?*anyopaque, ?*zozz.c.Refusal) callconv(.c) Result;
    const Loader = struct { tag: []const u8, load: Load, track: bool };
    const loaders = [_]Loader{
        .{ .tag = "ozz-raw_skeleton", .load = @ptrCast(&zozz.c.zozzRawSkeletonLoadMemory), .track = false },
        .{ .tag = "ozz-raw_animation", .load = @ptrCast(&zozz.c.zozzRawAnimationLoadMemory), .track = false },
        .{ .tag = "ozz-raw_float_track", .load = @ptrCast(&zozz.c.zozzRawFloatTrackLoadMemory), .track = true },
        .{ .tag = "ozz-raw_float2_track", .load = @ptrCast(&zozz.c.zozzRawFloat2TrackLoadMemory), .track = true },
        .{ .tag = "ozz-raw_float3_track", .load = @ptrCast(&zozz.c.zozzRawFloat3TrackLoadMemory), .track = true },
        .{ .tag = "ozz-raw_float4_track", .load = @ptrCast(&zozz.c.zozzRawFloat4TrackLoadMemory), .track = true },
        .{ .tag = "ozz-raw_quat_track", .load = @ptrCast(&zozz.c.zozzRawQuaternionTrackLoadMemory), .track = true },
    };
    var reached: usize = 0;
    for (loaders) |loader| {
        for (std.enums.values(archives.RawSize)) |size| {
            const name = @tagName(size);
            const fits = if (loader.track)
                std.mem.startsWith(u8, name, "track_")
            else
                std.mem.startsWith(u8, name, loader.tag["ozz-raw_".len..]);
            if (!fits) continue;
            var w = try size.archive(gpa, loader.tag, count);
            defer w.deinit();
            var handle: ?*anyopaque = null;
            var refusal = stale_refusal;
            try std.testing.expectEqual(Result.io, loader.load(w.bytes.items.ptr, w.bytes.items.len, &handle, &refusal));
            try std.testing.expectEqualStrings(size.what(), std.mem.span(refusal.what orelse return error.TestUnexpectedResult));
            try std.testing.expectEqual(@as(u64, count), refusal.value);
            try std.testing.expectEqual(@as(u64, 0), refusal.limit);
            reached += 1;
        }
    }
    // Three in a raw skeleton, five in a raw animation, two in each track.
    try std.testing.expectEqual(@as(usize, 3 + 5 + 2 * 5), reached);
}

test "a raw skeleton nests no deeper than ozz's joint limit" {
    var failure: zozz.Failure = .{};
    const gpa = std.testing.allocator;
    try zozz.setAllocator(gpa, &failure);
    defer zozz.resetAllocator(&failure) catch |e| std.debug.panic("zozz: {s}", .{@errorName(e)});

    var at_limit = try archives.rawSkeletonChain(gpa, zozz.c.max_joints);
    defer at_limit.deinit();
    var loaded = try zozz.RawSkeleton.initFromMemory(.init(at_limit.bytes.items), &failure);
    loaded.deinit();

    var over = try archives.rawSkeletonChain(gpa, zozz.c.max_joints + 1);
    defer over.deinit();
    try expectLoadRefused(zozz.RawSkeleton, over.bytes.items, .raw_skeleton_load_memory, err.Error.BadFormat, "RawSkeleton.depth", zozz.c.max_joints + 1, zozz.c.max_joints);
}
