//! The README's Usage section, as a program that runs.
//!
//! Everything between the two `README:usage` markers is what README.md shows:
//! `ci/readme_usage.sh` extracts it and `ci/check-docs.sh` compares, so the
//! snippet a reader copies is the snippet CI executes. Before the markers is
//! what a real application already has — assets its toolchain produced — and
//! after them is the assertion that the frame actually did something.

const std = @import("std");
const zozz = @import("zozz");

/// A real pipeline exports `.ozz` files from a DCC tool. This authors the
/// same two objects with the offline builders and writes them, so the example
/// needs no assets and still loads the way an application does.
fn authorAssets() !void {
    var raw_skeleton = try zozz.RawSkeleton.init();
    defer raw_skeleton.deinit();
    const root = try raw_skeleton.addJoint(null, "root", zozz.transform_identity);
    var child_rest = zozz.transform_identity;
    child_rest.translation = .{ 0, 1, 0 };
    _ = try raw_skeleton.addJoint(root, "child", child_rest);

    var skeleton = try raw_skeleton.build();
    defer skeleton.deinit();
    try zozz.saveSkeletonToFile(skeleton, "skeleton.ozz");

    // Every track is fully keyed, the child's included: a raw animation never
    // sees a skeleton, so a track with no keys bakes IDENTITY rather than the
    // rest pose.
    var raw_clip = try zozz.RawAnimation.init(2, 2.0, "walk");
    defer raw_clip.deinit();
    try raw_clip.pushTranslation(0, 0.0, .{ 0, 0, 0 });
    try raw_clip.pushTranslation(0, 2.0, .{ 4, 0, 0 });
    try raw_clip.pushTranslation(1, 0.0, .{ 0, 1, 0 });
    for (0..2) |track| {
        try raw_clip.pushRotation(@intCast(track), 0.0, .{ 0, 0, 0, 1 });
        try raw_clip.pushScale(@intCast(track), 0.0, .{ 1, 1, 1 });
    }

    var clip = try raw_clip.build();
    defer clip.deinit();
    try zozz.saveAnimationToFile(clip, "walk.ozz");
}

pub fn main() !void {
    var gpa_state = std.heap.DebugAllocator(.{}){};
    defer std.debug.assert(gpa_state.deinit() == .ok);
    const gpa = gpa_state.allocator();

    // build.zig runs this with its working directory set to zig-out, so the
    // two files below are this example's own and the paths in the Usage block
    // can stay plain. Authored before the allocator seam is installed: these
    // objects are gone again by the time the Usage block starts.
    try authorAssets();

    const time_seconds: f32 = 0.5;

    // --- README:usage ---
    try zozz.setAllocator(gpa);
    // Runs last, and can fail: restoring ozz's own allocator is refused while
    // blocks this one produced are still live.
    defer zozz.resetAllocator() catch |e| std.debug.panic("zozz: {s}", .{@errorName(e)});

    // A handle is destroyed through a pointer, so it is a `var`: `deinit`
    // nulls it, which makes a second destroy a no-op and a use after it a
    // checked panic rather than a read of freed memory.
    var skeleton = try zozz.Skeleton.initFromFile("skeleton.ozz");
    defer skeleton.deinit();

    var clip = try zozz.Animation.initFromFile("walk.ozz");
    defer clip.deinit();

    // The caller owns the pose. It can be a stack array, an arena slice, or a
    // sub-range of a batch; `soaBlocks` says how long it has to be.
    const blocks = try zozz.soaBlocks(skeleton.numJoints());
    const pose = try gpa.alloc(zozz.SoaTransform, blocks);
    defer gpa.free(pose);

    var context = try zozz.SamplingContext.initForSkeleton(skeleton);
    defer context.deinit();

    // Per frame:
    try skeleton.restPoseSoa(pose);
    try (zozz.SamplingJob{
        .animation = clip,
        .context = context,
        // `.loop` wraps in both directions; `.clamp` holds the end poses.
        .ratio = clip.ratioAt(time_seconds, .loop),
        .out = pose,
    }).run();

    // Either read local transforms out...
    const locals = try gpa.alloc(zozz.Transform, skeleton.numJoints());
    defer gpa.free(locals);
    try zozz.pose.toLocalTransforms(pose, locals);

    // ...or flatten the hierarchy to model space. Note the 16-byte alignment.
    const models = try gpa.alignedAlloc(zozz.Mat4, .@"16", skeleton.numJoints());
    defer gpa.free(models);
    try (zozz.LocalToModelJob{
        .skeleton = skeleton,
        .locals = pose,
        .root = null,
        .out = models,
    }).run();

    // Blending takes the same spans and allocates nothing per call. `walk`
    // and `run` here are two more poses, sampled the same way as `pose`.
    const walk = try gpa.alloc(zozz.SoaTransform, blocks);
    defer gpa.free(walk);
    const run = try gpa.alloc(zozz.SoaTransform, blocks);
    defer gpa.free(run);
    const rest = try gpa.alloc(zozz.SoaTransform, blocks);
    defer gpa.free(rest);
    @memcpy(walk, pose);
    @memcpy(run, pose);
    try skeleton.restPoseSoa(rest);
    try (zozz.BlendingJob{
        .layers = &.{ zozz.blending.layer(0.5, walk), zozz.blending.layer(0.5, run) },
        .rest_pose = rest,
        .out = pose,
    }).run();

    // A joint's skinning matrix is its model matrix times its inverse bind
    // pose — the inverse of where the joint sat when the mesh was authored.
    const joint = 1;
    const inverse_bind = zozz.math.mat4.invert(models[joint], null);
    const skinning = zozz.math.mat4.mul(models[joint], inverse_bind);
    // --- README:usage ---

    // The root translates from 0 to 4 over two seconds, so half a second in
    // it must have reached 1. Nothing above is a no-op.
    if (!std.math.approxEqAbs(f32, locals[0].translation[0], 1, 1e-2)) {
        return error.RootDidNotMove;
    }
    // A matrix times its own inverse is the identity, whatever the pose.
    if (!std.math.approxEqAbs(f32, skinning.m[0], 1, 1e-4)) {
        return error.SkinningMatrixWrong;
    }

    std.debug.print("usage example ok\n", .{});
}
