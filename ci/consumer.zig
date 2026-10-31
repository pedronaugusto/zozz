//! A downstream consumer of the `zozz` Zig module.
//!
//! Deliberately ordinary rather than clever: what is under test is that a
//! consumer can reach the module at all, that its allocator seam works from
//! out here, and that the build options it was compiled with are visible on
//! the other side.
const std = @import("std");
const zozz = @import("zozz");

fn restAt(translation: [3]f32) zozz.Transform {
    var t = zozz.transform_identity;
    t.translation = translation;
    return t;
}

pub fn main() !void {
    var failure: zozz.Failure = .{};
    var gpa_state: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    defer std.debug.assert(gpa_state.deinit() == 0);
    const gpa = gpa_state.allocator();

    // The allocator seam is process-wide, mirroring ozz. A leak or a
    // double-free anywhere below fails the SafeAllocator's deinit above,
    // which is the strongest assertion this consumer can make.
    try zozz.setAllocator(gpa, &failure);
    // Restoring ozz's own allocator is refused while blocks this one produced
    // are still live, so this defer runs last and its error is a real one.
    defer zozz.resetAllocator(&failure) catch |e| std.debug.panic("zozz: {s}", .{@errorName(e)});

    // Author a two-joint skeleton and a clip that translates its root, using
    // the offline builders — no asset files, so this runs anywhere.
    var raw_skeleton = try zozz.RawSkeleton.init(&failure);
    defer raw_skeleton.deinit();
    const root = try raw_skeleton.addJoint(null, "root", zozz.transform_identity, &failure);
    _ = try raw_skeleton.addJoint(root, "child", restAt(.{ 0, 1, 0 }), &failure);

    var skeleton = try raw_skeleton.build(&failure);
    defer skeleton.deinit();
    if (skeleton.numJoints() != 2) return error.WrongJointCount;
    if (skeleton.jointParent(0) != zozz.no_parent) return error.RootHasAParent;

    // Both tracks are fully keyed, including the child's, which simply holds
    // its rest offset. That is not padding: a track with no keys bakes
    // IDENTITY rather than the rest pose, because a raw animation never sees
    // a skeleton — so a consumer whose rule is "unanimated joints hold the
    // rest pose" has to author those keys, exactly as here.
    var raw_clip = try zozz.RawAnimation.init(2, 2.0, "walk", &failure);
    defer raw_clip.deinit();
    try raw_clip.pushTranslation(0, 0.0, .{ 0, 0, 0 }, &failure);
    try raw_clip.pushTranslation(0, 2.0, .{ 4, 0, 0 }, &failure);
    try raw_clip.pushTranslation(1, 0.0, .{ 0, 1, 0 }, &failure);
    for (0..2) |track| {
        try raw_clip.pushRotation(@intCast(track), 0.0, .{ 0, 0, 0, 1 }, &failure);
        try raw_clip.pushScale(@intCast(track), 0.0, .{ 1, 1, 1 }, &failure);
    }

    var clip = try raw_clip.build(&failure);
    defer clip.deinit();

    // The caller owns the pose: two joints are one SoA block, on the stack.
    var pose: [1]zozz.SoaTransform = undefined;
    var context = try zozz.SamplingContext.initForSkeleton(skeleton, &failure);
    defer context.deinit();

    try skeleton.restPoseSoa(&pose, &failure);
    try (zozz.SamplingJob{
        .animation = clip,
        .context = context,
        .ratio = clip.ratioAt(1.0, .clamp),
        .out = &pose,
    }).run(&failure);

    var locals: [2]zozz.Transform = undefined;
    try zozz.pose.toLocalTransforms(&pose, &locals, &failure);

    // The whole point of linking a library rather than a header: halfway
    // through a 0 -> 4 lerp the root must have moved. The tolerance is the
    // builder's key compression, not sampling noise.
    if (!std.math.approxEqAbs(f32, locals[0].translation[0], 2, 1e-2)) {
        return error.RootDidNotMove;
    }

    // LocalToModelJob needs a 16-byte-aligned destination, which an array of
    // zozz.Mat4 is by construction — a consumer that gets this wrong is
    // refused rather than faulting inside ozz.
    //
    // Column-major: m[12..15] is the translation column. The child must have
    // inherited the root's x while keeping its own y, which is the hierarchy
    // walk actually having happened rather than a memcpy of the locals.
    var models: [2]zozz.Mat4 = undefined;
    try (zozz.LocalToModelJob{
        .skeleton = skeleton,
        .locals = &pose,
        .root = null,
        .out = &models,
    }).run(&failure);
    if (!std.math.approxEqAbs(f32, models[1].m[12], 2, 1e-2) or
        !std.math.approxEqAbs(f32, models[1].m[13], 1, 1e-2))
    {
        return error.ChildNotWhereItsParentPutIt;
    }

    // `options` is a separate module the dependency has to export alongside
    // `zozz` itself, and it is what a consumer branches on to know how the C
    // library was actually compiled. Reaching it from out here is the test.
    if (@TypeOf(zozz.options.sanitize_c) != bool) return error.OptionsNotReachable;

    // What the clip was authored with, read back across the boundary.
    if (!std.mem.eql(u8, clip.name(), "walk")) return error.ClipNameLost;
    if (clip.duration() != 2) return error.ClipDurationLost;
}
