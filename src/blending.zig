//! Pose blending: weighted, additive and per-joint partial blending, all one
//! job (ozz::animation::BlendingJob).

const std = @import("std");
const c = @import("c.zig");
const err = @import("error.zig");
const math = @import("math.zig");

const SoaTransform = math.SoaTransform;

/// One blend input: a pose, its weight, and an optional partial-blend mask.
/// `ozz::animation::BlendingJob::Layer` field for field, so `run` hands the
/// caller's array straight to the job. Build one with `layer` or
/// `maskedLayer`; every buffer is borrowed for the `run` call only.
pub const Layer = c.BlendingLayer;

/// ozz's own `BlendingJob::threshold` default.
pub const default_threshold: f32 = 0.1;

/// A layer weighing every joint the same.
pub fn layer(weight: f32, transform: []const SoaTransform) Layer {
    return .{
        .weight = weight,
        .transform = transform.ptr,
        .num_transform = transform.len,
        .joint_weights = null,
        .num_joint_weights = 0,
    };
}

/// A layer with a per-joint mask, as `pose.packJointWeights` writes it: one
/// register per four joints, multiplied onto `weight` joint by joint.
pub fn maskedLayer(
    weight: f32,
    transform: []const SoaTransform,
    joint_weights: []const math.SimdFloat4,
) Layer {
    return .{
        .weight = weight,
        .transform = transform.ptr,
        .num_transform = transform.len,
        .joint_weights = @ptrCast(joint_weights.ptr),
        .num_joint_weights = joint_weights.len,
    };
}

/// Mirrors `ozz::animation::BlendingJob`. Blends `layers` and adds
/// `additive_layers` on top, into `out` — ozz's own two-pass split, not a
/// second pass this wrapper adds. A joint whose accumulated `layers` weight
/// falls below `threshold` (finite, > 0) is taken from `rest_pose` instead.
/// `out.len` sets the SoA block count every other buffer is measured against;
/// a `rest_pose` shorter than that is `error.InvalidArgument`.
pub const BlendingJob = struct {
    layers: []const Layer,
    additive_layers: []const Layer = &.{},
    rest_pose: []const SoaTransform,
    threshold: f32 = default_threshold,
    out: []SoaTransform,

    /// Runs the blending job. Nothing is allocated: the layer arrays are
    /// already in the layout ozz reads.
    pub fn run(self: BlendingJob) err.Error!void {
        // The only length this wrapper cannot forward. `blocks` below is the
        // count of BOTH `rest_pose` and `out` — that is the C contract, and
        // the span ozz validates is built from it, so ozz cannot see a
        // `rest_pose` that is short and would read past its end for every
        // joint that falls back to it. Every other buffer here carries its
        // own count across the boundary; this one is checked instead.
        if (self.rest_pose.len < self.out.len) return err.Error.InvalidArgument;
        try err.check(c.zozzBlendingRun(
            self.layers.ptr,
            self.layers.len,
            self.additive_layers.ptr,
            self.additive_layers.len,
            self.rest_pose.ptr,
            self.threshold,
            self.out.ptr,
            self.out.len,
        ));
    }
};
