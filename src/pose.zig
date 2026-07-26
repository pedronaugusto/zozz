//! A pose in ozz's structure-of-arrays layout.
//!
//! SoA is the currency of ozz's job pipeline: sampling writes it, blending
//! consumes and produces it, local-to-model reads it. It stays opaque so no
//! consumer depends on the SIMD layout, while chaining jobs still costs no
//! conversion. Convert to `Transform` only at the edges.

const std = @import("std");
const c = @import("c.zig");
const err = @import("error.zig");
const math = @import("math.zig");
const Skeleton = @import("skeleton.zig").Skeleton;

pub const SoaPose = struct {
    handle: *c.SoaPose,

    /// Allocates storage for `num_joints`, rounded up to a whole SoA block,
    /// initialised to identity.
    pub fn init(num_joints: u32) err.Error!SoaPose {
        var handle: *c.SoaPose = undefined;
        try err.check(c.zozzSoaPoseCreate(@intCast(num_joints), &handle));
        return .{ .handle = handle };
    }

    /// Allocates a pose sized to a skeleton — the common case, since a pose
    /// smaller than its skeleton cannot be fed to `localToModel`.
    pub fn initForSkeleton(skeleton: Skeleton) err.Error!SoaPose {
        return init(skeleton.numJoints());
    }

    pub fn deinit(self: SoaPose) void {
        c.zozzSoaPoseDestroy(self.handle);
    }

    pub fn numJoints(self: SoaPose) u32 {
        return @intCast(c.zozzSoaPoseNumJoints(self.handle));
    }

    pub fn setIdentity(self: SoaPose) err.Error!void {
        try err.check(c.zozzSoaPoseSetIdentity(self.handle));
    }

    /// Seeds the pose from the skeleton's rest pose. Do this before sampling a
    /// clip that animates fewer joints than the skeleton has, otherwise the
    /// un-animated joints keep whatever was in the buffer.
    pub fn setRestPose(self: SoaPose, skeleton: Skeleton) err.Error!void {
        try err.check(c.zozzSoaPoseSetRestPose(self.handle, skeleton.handle));
    }

    /// SoA -> AoS. `out` must hold at least `numJoints` entries.
    pub fn toLocalTransforms(self: SoaPose, out: []math.Transform) err.Error!void {
        try err.check(c.zozzSoaPoseToLocalTransforms(self.handle, out.ptr, out.len));
    }

    /// AoS -> SoA. `in` must hold at least `numJoints` entries; a trailing
    /// partial block is padded with identity.
    pub fn fromLocalTransforms(self: SoaPose, in: []const math.Transform) err.Error!void {
        try err.check(c.zozzSoaPoseFromLocalTransforms(self.handle, in.ptr, in.len));
    }
};
