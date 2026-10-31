//! A pose in ozz's structure-of-arrays layout, owned by the caller.
//!
//! SoA is the currency of ozz's job pipeline: sampling writes it, blending
//! consumes and produces it, local-to-model reads it. A pose is an array of
//! `SoaTransform`, one per four joints, and every function here takes that
//! array as a slice — the `ozz::span<SoaTransform>` ozz's own jobs take.
//! Nothing here allocates. Convert to `Transform` only at the edges.
//!
//! The layout is public on purpose: a pose can live in an arena, on the
//! stack, inside a larger struct, or as a sub-range of a batch, and two poses
//! can be sub-ranges of one allocation. An opaque handle made all of those
//! impossible and cost a heap allocation per pose.
const c = @import("c.zig");
const err = @import("error.zig");
const math = @import("math.zig");

/// Four joints' local-space transforms. Re-exported from `math`, which is
/// where the plain-data types live.
pub const SoaTransform = math.SoaTransform;

// `math.SimdFloat4` is a `@Vector(4, f32)` and `c.SimdFloat4` is the struct
// the header declares. They are the same sixteen bytes, which is what makes
// the cast in `packJointWeights` a reinterpretation rather than a conversion,
// and this is where that is established rather than assumed.
comptime {
    if (@sizeOf(math.SimdFloat4) != @sizeOf(c.SimdFloat4) or
        @alignOf(math.SimdFloat4) != @alignOf(c.SimdFloat4))
    {
        @compileError("math.SimdFloat4 and c.SimdFloat4 must agree in size and alignment");
    }
}

/// SoA blocks needed for `num_joints`: ceil(num_joints / 4), ozz's
/// num_soa_joints. `error.InvalidArgument`, named `.soa_blocks`, for 0 or
/// above `max_joints`, so a caller cannot size a buffer from a count ozz
/// would have refused.
pub fn soaBlocks(num_joints: u32, failure: *err.Failure) err.Error!usize {
    const joints = try err.narrow(failure, .soa_blocks, c_int, num_joints);
    const blocks = c.zozzSoaBlocks(joints);
    if (blocks == 0) return err.refuse(failure, .soa_blocks, err.Error.InvalidArgument);
    return blocks;
}

/// Fills every block with the identity transform.
pub fn setIdentity(pose: []SoaTransform, failure: *err.Failure) err.Error!void {
    try err.check(failure, .soa_pose_set_identity, c.zozzSoaPoseSetIdentity(pose.ptr, pose.len));
}

/// SoA -> AoS. `pose` must cover `out.len` joints.
pub fn toLocalTransforms(pose: []const SoaTransform, out: []math.Transform, failure: *err.Failure) err.Error!void {
    try err.check(failure, .soa_pose_to_local_transforms, c.zozzSoaPoseToLocalTransforms(pose.ptr, pose.len, out.ptr, out.len));
}

/// AoS -> SoA. `pose` must cover `in.len` joints; the lanes of a trailing
/// partial block are filled with identity, so the whole slice is valid input
/// to a job that reads it a block at a time.
pub fn fromLocalTransforms(in: []const math.Transform, pose: []SoaTransform, failure: *err.Failure) err.Error!void {
    try err.check(failure, .soa_pose_from_local_transforms, c.zozzSoaPoseFromLocalTransforms(in.ptr, in.len, pose.ptr, pose.len));
}

/// Packs flat per-joint weights into the SoA registers a `BlendingLayer`
/// mask is made of. Lanes past `in.len` are filled with 1.0, the "fully
/// weighted" meaning ozz gives an absent mask. Values are not clamped: ozz
/// treats a negative weight as 0, and above 1 is valid wherever
/// normalisation allows it. Every value must be finite.
pub fn packJointWeights(in: []const f32, out: []math.SimdFloat4, failure: *err.Failure) err.Error!void {
    try err.check(failure, .soa_weights_pack, c.zozzSoaWeightsPack(in.ptr, in.len, @ptrCast(out.ptr), out.len)); // aegis: no-danger: math.SimdFloat4 and c.SimdFloat4 are the same 16 bytes at the same alignment, asserted at comptime above
}
