//! Offline builders: author a skeleton or an animation at runtime.
//!
//! This is ozz's offline pipeline (`RawSkeleton` -> `SkeletonBuilder`,
//! `RawAnimation` -> `AnimationBuilder`) behind the package's usual handle
//! rules. Building yields the same runtime `Skeleton` / `Animation` the
//! loaders produce, so everything downstream (sampling, local-to-model) is
//! shared.
//!
//! Two contracts worth reading twice:
//!
//! * **Joint order.** The built skeleton stores joints in DEPTH-FIRST order
//!   of the authored hierarchy. Add joints in an order that is itself a
//!   depth-first traversal and built indices equal insertion indices;
//!   otherwise map through `Skeleton.jointName`. Animation tracks pair with
//!   BUILT joint indices by convention — the raw animation never sees a
//!   skeleton.
//! * **Empty tracks bake IDENTITY.** A track with no keys samples as the
//!   identity transform, not the skeleton's rest pose, which the builder
//!   never sees. A consumer whose contract is "unanimated joints hold the
//!   rest pose" must author rest-pose keys itself. Pinned by test below.

const std = @import("std");
const c = @import("c.zig");
const err = @import("error.zig");
const math = @import("math.zig");
const skeleton_mod = @import("skeleton.zig");
const animation_mod = @import("animation.zig");

/// A skeleton under construction: a flat list of (parent, name, rest) joints.
pub const RawSkeleton = struct {
    handle: *c.RawSkeleton,

    pub fn init() err.Error!RawSkeleton {
        var handle: *c.RawSkeleton = undefined;
        try err.check(c.zozzRawSkeletonCreate(&handle));
        return .{ .handle = handle };
    }

    pub fn deinit(self: RawSkeleton) void {
        c.zozzRawSkeletonDestroy(self.handle);
    }

    /// Appends a joint and returns its insertion index. `parent` is null for
    /// a root, else the insertion index of a previously added joint. `name`
    /// is borrowed for the duration of the call only.
    pub fn addJoint(
        self: RawSkeleton,
        parent: ?u32,
        name: [*:0]const u8,
        rest: math.Transform,
    ) err.Error!u32 {
        var index: i32 = undefined;
        const parent_c: i32 = if (parent) |p| @intCast(p) else -1;
        try err.check(c.zozzRawSkeletonAddJoint(self.handle, parent_c, name, &rest, &index));
        return @intCast(index);
    }

    pub fn numJoints(self: RawSkeleton) u32 {
        return @intCast(c.zozzRawSkeletonNumJoints(self.handle));
    }

    /// Validates and builds a runtime skeleton. The raw skeleton is not
    /// consumed; it may be built again or extended further.
    pub fn build(self: RawSkeleton) err.Error!skeleton_mod.Skeleton {
        var handle: *c.Skeleton = undefined;
        try err.check(c.zozzSkeletonBuild(self.handle, &handle));
        return .{ .handle = handle };
    }
};

/// An animation under construction: per-track keyed T/R/S channels.
pub const RawAnimation = struct {
    handle: *c.RawAnimation,

    /// `num_tracks` is fixed for the clip's lifetime; `duration` is seconds,
    /// finite and positive. `name` may be null for an unnamed clip.
    pub fn init(num_tracks: u32, duration_seconds: f32, name: ?[*:0]const u8) err.Error!RawAnimation {
        var handle: *c.RawAnimation = undefined;
        try err.check(c.zozzRawAnimationCreate(@intCast(num_tracks), duration_seconds, name, &handle));
        return .{ .handle = handle };
    }

    pub fn deinit(self: RawAnimation) void {
        c.zozzRawAnimationDestroy(self.handle);
    }

    pub fn numTracks(self: RawAnimation) u32 {
        return @intCast(c.zozzRawAnimationNumTracks(self.handle));
    }

    pub fn duration(self: RawAnimation) f32 {
        return c.zozzRawAnimationDuration(self.handle);
    }

    /// Appends one translation key. `time` must lie within `[0, duration]`;
    /// keys must arrive in non-decreasing time order per channel (violations
    /// surface at `build` as `error.InvalidData`).
    pub fn pushTranslation(self: RawAnimation, track: u32, time: f32, value: [3]f32) err.Error!void {
        try err.check(c.zozzRawAnimationPushTranslation(self.handle, @intCast(track), time, &value));
    }

    /// Appends one rotation key: a quaternion in (x, y, z, w) order — w LAST.
    pub fn pushRotation(self: RawAnimation, track: u32, time: f32, value: [4]f32) err.Error!void {
        try err.check(c.zozzRawAnimationPushRotation(self.handle, @intCast(track), time, &value));
    }

    /// Appends one scale key.
    pub fn pushScale(self: RawAnimation, track: u32, time: f32, value: [3]f32) err.Error!void {
        try err.check(c.zozzRawAnimationPushScale(self.handle, @intCast(track), time, &value));
    }

    /// Validates and builds a compressed runtime animation. The raw animation
    /// is not consumed.
    pub fn build(self: RawAnimation) err.Error!animation_mod.Animation {
        var handle: *c.Animation = undefined;
        try err.check(c.zozzAnimationBuild(self.handle, &handle));
        return .{ .handle = handle };
    }
};

//=============================================================================
// Tests
//=============================================================================

const pose_mod = @import("pose.zig");
const sampling_mod = @import("sampling.zig");

fn restAt(translation: [3]f32) math.Transform {
    var t = math.transform_identity;
    t.translation = translation;
    return t;
}

test "builder: a depth-first insertion round-trips names, parents and rest pose" {
    const raw = try RawSkeleton.init();
    defer raw.deinit();

    // root -> spine -> {arm_l, arm_r}, inserted depth-first.
    const root = try raw.addJoint(null, "root", restAt(.{ 0, 0, 0 }));
    const spine = try raw.addJoint(root, "spine", restAt(.{ 0, 1, 0 }));
    _ = try raw.addJoint(spine, "arm_l", restAt(.{ -0.5, 0.5, 0 }));
    _ = try raw.addJoint(spine, "arm_r", restAt(.{ 0.5, 0.5, 0 }));
    try std.testing.expectEqual(@as(u32, 4), raw.numJoints());

    const built = try raw.build();
    defer built.deinit();

    try std.testing.expectEqual(@as(u32, 4), built.numJoints());
    try std.testing.expectEqualStrings("root", built.jointName(0).?);
    try std.testing.expectEqualStrings("spine", built.jointName(1).?);
    try std.testing.expectEqualStrings("arm_l", built.jointName(2).?);
    try std.testing.expectEqualStrings("arm_r", built.jointName(3).?);
    try std.testing.expectEqual(skeleton_mod.no_parent, built.jointParent(0));
    try std.testing.expectEqual(@as(i16, 0), built.jointParent(1));
    try std.testing.expectEqual(@as(i16, 1), built.jointParent(2));
    try std.testing.expectEqual(@as(i16, 1), built.jointParent(3));

    var rest: [4]math.Transform = undefined;
    try built.restPose(&rest);
    try std.testing.expectEqual(@as(f32, 1), rest[1].translation[1]);
    try std.testing.expectEqual(@as(f32, -0.5), rest[2].translation[0]);
}

test "builder: a non-depth-first insertion is reindexed depth-first" {
    const raw = try RawSkeleton.init();
    defer raw.deinit();

    // Insertion order: root, a, b, c(child of a). Depth-first order walks a's
    // subtree before b, so c overtakes b in the built skeleton.
    const root = try raw.addJoint(null, "root", math.transform_identity);
    const a = try raw.addJoint(root, "a", math.transform_identity);
    _ = try raw.addJoint(root, "b", math.transform_identity);
    _ = try raw.addJoint(a, "c", math.transform_identity);

    const built = try raw.build();
    defer built.deinit();

    try std.testing.expectEqualStrings("root", built.jointName(0).?);
    try std.testing.expectEqualStrings("a", built.jointName(1).?);
    try std.testing.expectEqualStrings("c", built.jointName(2).?);
    try std.testing.expectEqualStrings("b", built.jointName(3).?);
}

test "builder: a built animation samples what was authored" {
    const raw_skel = try RawSkeleton.init();
    defer raw_skel.deinit();
    const root = try raw_skel.addJoint(null, "root", math.transform_identity);
    _ = try raw_skel.addJoint(root, "child", restAt(.{ 0, 1, 0 }));
    const skel = try raw_skel.build();
    defer skel.deinit();

    const raw_anim = try RawAnimation.init(2, 2.0, "authored");
    defer raw_anim.deinit();
    // Root translates 0 -> (4, 0, 0) linearly; both tracks fully keyed.
    for (0..2) |track| {
        const x: f32 = if (track == 0) 4 else 0;
        try raw_anim.pushTranslation(@intCast(track), 0.0, .{ 0, 0, 0 });
        try raw_anim.pushTranslation(@intCast(track), 2.0, .{ x, 0, 0 });
        try raw_anim.pushRotation(@intCast(track), 0.0, .{ 0, 0, 0, 1 });
        try raw_anim.pushScale(@intCast(track), 0.0, .{ 1, 1, 1 });
    }
    const clip = try raw_anim.build();
    defer clip.deinit();
    try std.testing.expectEqual(@as(f32, 2.0), clip.duration());
    try std.testing.expectEqual(@as(u32, 2), clip.numTracks());

    const pose = try pose_mod.SoaPose.initForSkeleton(skel);
    defer pose.deinit();
    const context = try sampling_mod.SamplingContext.initForSkeleton(skel);
    defer context.deinit();

    // Tolerance is the builder's compression, not sampling noise: ozz stores
    // keys with quantized timepoints and half-float components (measured here:
    // the midpoint sample of a 0 -> 4 lerp lands at 1.9995117).
    var locals: [2]math.Transform = undefined;
    try sampling_mod.sample(clip, context, 0.5, pose);
    try pose.toLocalTransforms(&locals);
    try std.testing.expectApproxEqAbs(@as(f32, 2), locals[0].translation[0], 1e-2);

    try sampling_mod.sample(clip, context, 1.0, pose);
    try pose.toLocalTransforms(&locals);
    try std.testing.expectApproxEqAbs(@as(f32, 4), locals[0].translation[0], 1e-2);
}

test "builder: an empty track bakes identity, not the rest pose" {
    // The contract this test pins is load-bearing for consumers whose rule is
    // "unanimated joints hold the rest pose": ozz's AnimationBuilder writes
    // identity keys for a track with no keys (animation_builder.cc, CopyRaw),
    // and it cannot do otherwise — a RawAnimation never sees a skeleton.
    const raw_skel = try RawSkeleton.init();
    defer raw_skel.deinit();
    const root = try raw_skel.addJoint(null, "root", math.transform_identity);
    _ = try raw_skel.addJoint(root, "still", restAt(.{ 5, 5, 5 }));
    const skel = try raw_skel.build();
    defer skel.deinit();

    const raw_anim = try RawAnimation.init(2, 1.0, null);
    defer raw_anim.deinit();
    try raw_anim.pushTranslation(0, 0.0, .{ 1, 0, 0 });
    // Track 1: no keys at all.
    const clip = try raw_anim.build();
    defer clip.deinit();

    const pose = try pose_mod.SoaPose.initForSkeleton(skel);
    defer pose.deinit();
    const context = try sampling_mod.SamplingContext.initForSkeleton(skel);
    defer context.deinit();

    // Seed the pose with the rest pose, then sample: the empty track has
    // baked keys, so sampling OVERWRITES the seeded rest pose with identity.
    try pose.setRestPose(skel);
    try sampling_mod.sample(clip, context, 0.0, pose);
    var locals: [2]math.Transform = undefined;
    try pose.toLocalTransforms(&locals);
    try std.testing.expectEqual(@as(f32, 0), locals[1].translation[0]);
    try std.testing.expectEqual(@as(f32, 0), locals[1].translation[1]);
}

test "builder: validation failures are errors, not asserts" {
    const raw_skel = try RawSkeleton.init();
    defer raw_skel.deinit();

    // Parent index that does not exist yet.
    try std.testing.expectError(
        error.InvalidArgument,
        raw_skel.addJoint(7, "orphan", math.transform_identity),
    );
    // An empty skeleton cannot build.
    try std.testing.expectError(error.InvalidData, raw_skel.build());

    // Animation-side argument shapes.
    try std.testing.expectError(error.InvalidArgument, RawAnimation.init(0, 1.0, null));
    try std.testing.expectError(error.InvalidArgument, RawAnimation.init(1, 0.0, null));
    try std.testing.expectError(error.InvalidArgument, RawAnimation.init(1, std.math.nan(f32), null));

    const raw_anim = try RawAnimation.init(1, 1.0, null);
    defer raw_anim.deinit();
    // Out-of-range track, out-of-range time, non-finite value.
    try std.testing.expectError(error.InvalidArgument, raw_anim.pushTranslation(1, 0.0, .{ 0, 0, 0 }));
    try std.testing.expectError(error.InvalidArgument, raw_anim.pushTranslation(0, 2.0, .{ 0, 0, 0 }));
    try std.testing.expectError(
        error.InvalidArgument,
        raw_anim.pushTranslation(0, 0.0, .{ std.math.inf(f32), 0, 0 }),
    );

    // Keys out of order pass the push (per-call checks cannot see order
    // without forbidding legitimate equal-time replaces) and fail at build.
    try raw_anim.pushTranslation(0, 0.75, .{ 0, 0, 0 });
    try raw_anim.pushTranslation(0, 0.25, .{ 1, 0, 0 });
    try std.testing.expectError(error.InvalidData, raw_anim.build());
}
