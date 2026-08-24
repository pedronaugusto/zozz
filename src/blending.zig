//! Pose blending: weighted, additive and per-joint partial blending, all one
//! job (ozz::animation::BlendingJob).

const std = @import("std");
const c = @import("c.zig");
const err = @import("error.zig");
const SoaPose = @import("pose.zig").SoaPose;

/// A per-joint SoA weight buffer, for partial blending.
///
/// See `zozz_blending.h`'s ZozzSoaWeights for why this is a handle rather
/// than a raw float slice: it holds the same SIMD-packed layout a blend job
/// actually reads, built once with `fromArray` and reused across every
/// `run` call that wants the same mask.
pub const SoaWeights = struct {
    handle: *c.SoaWeights,

    /// Allocates storage for `num_joints`, rounded up to a whole SoA block,
    /// every joint initialised to a weight of 1.0.
    pub fn init(num_joints: u32) err.Error!SoaWeights {
        var handle: *c.SoaWeights = undefined;
        try err.check(c.zozzSoaWeightsCreate(@intCast(num_joints), &handle));
        return .{ .handle = handle };
    }

    pub fn deinit(self: SoaWeights) void {
        c.zozzSoaWeightsDestroy(self.handle);
    }

    /// Packs `in` (at least as many entries as the buffer has joints) into
    /// SoA blocks. Values are not clamped: ozz treats a negative weight as
    /// 0. Every value must be finite.
    pub fn fromArray(self: SoaWeights, in: []const f32) err.Error!void {
        try err.check(c.zozzSoaWeightsFromArray(self.handle, in.ptr, in.len));
    }
};

/// One blend input: a pose, its weight, and an optional partial-blend mask.
/// `transform` and `joint_weights` are borrowed for the `run` call only.
pub const Layer = struct {
    weight: f32,
    transform: SoaPose,
    joint_weights: ?SoaWeights = null,

    fn toC(self: Layer) c.BlendingLayer {
        return .{
            .weight = self.weight,
            .transform = self.transform.handle,
            .joint_weights = if (self.joint_weights) |w| w.handle else null,
        };
    }
};

/// Mirrors `ozz::animation::BlendingJob`.
///
/// Blends `layers` and adds `additive_layers` on top, into `out` — ozz's own
/// two-pass split, not a second pass this wrapper adds.
///
/// A joint whose accumulated `layers` weight falls below `threshold` (finite,
/// > 0) is taken from `rest_pose` instead, so `rest_pose` also sets the
/// joint count every buffer here is measured against.
pub const BlendingJob = struct {
    layers: []const Layer,
    additive_layers: []const Layer,
    rest_pose: SoaPose,
    threshold: f32,
    out: SoaPose,

    /// Runs the blending job.
    ///
    /// `gpa` backs a scratch conversion from `layers`/`additive_layers` into
    /// the flat C form the job actually takes; freed before this returns.
    pub fn run(self: BlendingJob, gpa: std.mem.Allocator) (std.mem.Allocator.Error || err.Error)!void {
        const c_layers = try gpa.alloc(c.BlendingLayer, self.layers.len);
        defer gpa.free(c_layers);
        for (self.layers, c_layers) |layer, *dst| dst.* = layer.toC();

        const c_additive = try gpa.alloc(c.BlendingLayer, self.additive_layers.len);
        defer gpa.free(c_additive);
        for (self.additive_layers, c_additive) |layer, *dst| dst.* = layer.toC();

        try err.check(c.zozzBlendingRun(
            c_layers.ptr,
            c_layers.len,
            c_additive.ptr,
            c_additive.len,
            self.rest_pose.handle,
            self.threshold,
            self.out.handle,
        ));
    }
};

/// Deprecated: call `BlendingJob.run` instead — `(job).run(gpa)`.
pub fn run(
    gpa: std.mem.Allocator,
    layers: []const Layer,
    additive_layers: []const Layer,
    rest_pose: SoaPose,
    threshold: f32,
    out: SoaPose,
) (std.mem.Allocator.Error || err.Error)!void {
    return (BlendingJob{
        .layers = layers,
        .additive_layers = additive_layers,
        .rest_pose = rest_pose,
        .threshold = threshold,
        .out = out,
    }).run(gpa);
}
