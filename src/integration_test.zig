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

    const pose = try zozz.SoaPose.initForSkeleton(skeleton);
    defer pose.deinit();
    const context = try zozz.SamplingContext.initForSkeleton(skeleton);
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
        try pose.setRestPose(skeleton);
        try zozz.sample(clip, context, ratio, pose);
        try pose.toLocalTransforms(locals);
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

        try zozz.localToModel(skeleton, pose, null, models);
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
        zozz.sample(clip, context, std.math.nan(f32), pose),
    );
}

//=============================================================================
// Tests
//=============================================================================

test "the full pipeline runs against synthetic assets" {
    const gpa = std.testing.allocator;
    try zozz.setAllocator(gpa);
    defer zozz.resetAllocator();

    const skeleton_blob = try FixtureBlob.init(zozzFixtureSkeleton);
    defer skeleton_blob.deinit();
    const animation_blob = try FixtureBlob.init(zozzFixtureAnimation);
    defer animation_blob.deinit();

    const skeleton = try zozz.Skeleton.initFromMemory(skeleton_blob.bytes);
    defer skeleton.deinit();
    const clip = try zozz.Animation.initFromMemory(animation_blob.bytes);
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

test "a sampling context can be reused across clips after invalidation" {
    const gpa = std.testing.allocator;
    try zozz.setAllocator(gpa);
    defer zozz.resetAllocator();

    const skeleton_blob = try FixtureBlob.init(zozzFixtureSkeleton);
    defer skeleton_blob.deinit();
    const animation_blob = try FixtureBlob.init(zozzFixtureAnimation);
    defer animation_blob.deinit();

    const skeleton = try zozz.Skeleton.initFromMemory(skeleton_blob.bytes);
    defer skeleton.deinit();

    const context = try zozz.SamplingContext.initForSkeleton(skeleton);
    defer context.deinit();
    const pose = try zozz.SoaPose.initForSkeleton(skeleton);
    defer pose.deinit();

    // Two clips loaded and freed in turn can land on the same address; ozz
    // detects a clip change by pointer identity, so this is exactly the case
    // invalidate() exists for.
    for (0..3) |_| {
        const clip = try zozz.Animation.initFromMemory(animation_blob.bytes);
        defer clip.deinit();

        context.invalidate();
        try pose.setRestPose(skeleton);
        try zozz.sample(clip, context, 0.5, pose);

        var locals: [fixture_joints]zozz.Transform = undefined;
        try pose.toLocalTransforms(&locals);
        for (locals) |t| try expectSaneTransform(t);
    }
}

test "a pose smaller than the animation is refused" {
    const gpa = std.testing.allocator;
    try zozz.setAllocator(gpa);
    defer zozz.resetAllocator();

    const skeleton_blob = try FixtureBlob.init(zozzFixtureSkeleton);
    defer skeleton_blob.deinit();
    const animation_blob = try FixtureBlob.init(zozzFixtureAnimation);
    defer animation_blob.deinit();

    const skeleton = try zozz.Skeleton.initFromMemory(skeleton_blob.bytes);
    defer skeleton.deinit();
    const clip = try zozz.Animation.initFromMemory(animation_blob.bytes);
    defer clip.deinit();

    const context = try zozz.SamplingContext.initForSkeleton(skeleton);
    defer context.deinit();

    const too_small = try zozz.SoaPose.init(fixture_joints - 1);
    defer too_small.deinit();

    try std.testing.expectError(
        zozz.Error.BufferTooSmall,
        zozz.sample(clip, context, 0.5, too_small),
    );
    try std.testing.expectError(
        zozz.Error.SkeletonMismatch,
        too_small.setRestPose(skeleton),
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
    defer zozz.resetAllocator();

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
