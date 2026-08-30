//! Two-bone and single-joint inverse kinematics, and folding the result back
//! into a local pose.
//!
//! Neither job touches a pose directly: each one only computes a local-space
//! correction quaternion for the joint(s) it was pointed at. `applyCorrection`
//! is the other half — it is what a corrected chain actually needs before the
//! next model-space update.
//!
//! Precision: `TwoBoneJob` early-outs at `weight <= 0` and returns an exact
//! identity. `AimJob` does not, and at any `weight < 1` ends in ozz's
//! `NormalizeEst4`, so its correction is normalised — and at weight 0
//! identity — only to `math.normalization_tolerance_est_sq`. Skip the job at
//! weight 0 rather than running it for an identity, as ozz's own samples do.

const std = @import("std");
const c = @import("c.zig");
const err = @import("error.zig");
const math = @import("math.zig");
const SoaTransform = @import("math.zig").SoaTransform;

/// A vector or quaternion as ozz's own job fields hold it. Positions and axes
/// ignore w; a scalar caller writes `.{ x, y, z, 0 }`.
pub const Vec4 = math.SimdFloat4;

// `math.SimdFloat4` is the `@Vector(4, f32)` this module's callers use;
// `c.SimdFloat4` is the struct the header declares. The bitcasts below are
// free, and these are what make them sound rather than assumed.
comptime {
    std.debug.assert(@sizeOf(Vec4) == @sizeOf(c.SimdFloat4));
    std.debug.assert(@alignOf(Vec4) == @alignOf(c.SimdFloat4));
}

/// Solves a three-joint chain (two bones) so its end reaches `target`.
///
/// `mid_axis`, `pole_vector`, `soften` and `weight` default to ozz's own
/// defaults. They are NOT zero-defaulted on purpose: `weight` is not checked
/// by the job's own validation, so a zeroed struct would run "successfully"
/// and silently produce an identity correction rather than erroring.
pub const TwoBoneJob = struct {
    target: Vec4 = .{ 0, 0, 0, 0 },
    mid_axis: Vec4 = .{ 0, 0, 1, 0 },
    pole_vector: Vec4 = .{ 0, 1, 0, 0 },
    twist_angle: f32 = 0,
    soften: f32 = 1,
    weight: f32 = 1,
    start_joint: *const math.Mat4,
    mid_joint: *const math.Mat4,
    end_joint: *const math.Mat4,

    /// Runs a two-bone IK solve.
    pub fn run(self: TwoBoneJob) err.Error!TwoBoneResult {
        var start_correction: c.SimdFloat4 = undefined;
        var mid_correction: c.SimdFloat4 = undefined;
        var reached: bool = false;
        var raw = c.IKTwoBoneJob{
            .target = @bitCast(self.target),
            .mid_axis = @bitCast(self.mid_axis),
            .pole_vector = @bitCast(self.pole_vector),
            .twist_angle = self.twist_angle,
            .soften = self.soften,
            .weight = self.weight,
            .start_joint = self.start_joint,
            .mid_joint = self.mid_joint,
            .end_joint = self.end_joint,
            .start_joint_correction = &start_correction,
            .mid_joint_correction = &mid_correction,
            .reached = &reached,
        };
        try err.check(c.zozzIKTwoBoneJobRun(&raw));
        return .{
            .start_joint_correction = @bitCast(start_correction),
            .mid_joint_correction = @bitCast(mid_correction),
            .reached = reached,
        };
    }
};

pub const TwoBoneResult = struct {
    /// Local-space correction for `start_joint`/`mid_joint` (xyzw, w LAST).
    /// Left-multiply onto the joint's current local rotation — or hand it to
    /// `applyCorrections`.
    start_joint_correction: Vec4,
    mid_joint_correction: Vec4,
    /// False if the chain's length, softening, or weight kept the target out
    /// of reach.
    reached: bool,
};

/// Rotates a single joint so `forward` (in the joint's local-space) aims at
/// `target` (in model-space).
///
/// `forward`, `up`, `pole_vector` and `weight` default to ozz's own defaults,
/// for the same reason as `TwoBoneJob`: `weight` is unchecked, so it is not
/// zero-defaulted.
pub const AimJob = struct {
    target: Vec4 = .{ 0, 0, 0, 0 },
    forward: Vec4 = .{ 1, 0, 0, 0 },
    offset: Vec4 = .{ 0, 0, 0, 0 },
    up: Vec4 = .{ 0, 1, 0, 0 },
    pole_vector: Vec4 = .{ 0, 1, 0, 0 },
    twist_angle: f32 = 0,
    weight: f32 = 1,
    joint: *const math.Mat4,

    /// Runs an aim IK solve.
    pub fn run(self: AimJob) err.Error!AimResult {
        var joint_correction: c.SimdFloat4 = undefined;
        var reached: bool = false;
        var raw = c.IKAimJob{
            .target = @bitCast(self.target),
            .forward = @bitCast(self.forward),
            .offset = @bitCast(self.offset),
            .up = @bitCast(self.up),
            .pole_vector = @bitCast(self.pole_vector),
            .twist_angle = self.twist_angle,
            .weight = self.weight,
            .joint = self.joint,
            .joint_correction = &joint_correction,
            .reached = &reached,
        };
        try err.check(c.zozzIKAimJobRun(&raw));
        return .{ .joint_correction = @bitCast(joint_correction), .reached = reached };
    }
};

pub const AimResult = struct {
    /// Local-space correction for `joint` (xyzw, w LAST).
    joint_correction: Vec4,
    reached: bool,
};

/// One joint's local-space rotation correction, as an IK job produces it.
/// The layout is `c.JointCorrection`'s, which is what `abi_check.zig`
/// compares against the header; `correction` below is how one is built.
pub const JointCorrection = c.JointCorrection;

/// Pairs a joint index with the rotation an IK job produced for it.
pub fn correction(joint: u32, rotation: Vec4) JointCorrection {
    return .{ .rotation = @bitCast(rotation), .joint = @intCast(joint) };
}

/// Left-multiplies each correction onto its joint's current local-space
/// rotation in `pose`, in place: how an IK pass gets folded back before the
/// pose is next converted to model-space. One call for the whole pass, not
/// one per joint, and corrections in the same SoA block share one transpose.
/// Nothing is written unless every index is in range.
pub fn applyCorrections(pose: []SoaTransform, corrections: []const JointCorrection) err.Error!void {
    try err.check(c.zozzSoaPoseApplyLocalCorrections(
        pose.ptr,
        pose.len,
        corrections.ptr,
        corrections.len,
    ));
}

/// `applyCorrections` for a single joint. Same call, one-element batch.
pub fn applyCorrection(pose: []SoaTransform, joint: u32, rotation: Vec4) err.Error!void {
    const one = [_]JointCorrection{correction(joint, rotation)};
    try applyCorrections(pose, &one);
}
