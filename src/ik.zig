//! Two-bone and single-joint inverse kinematics, and folding the result back
//! into a local pose.
//!
//! Neither job touches a pose directly: each one only computes a local-space
//! correction quaternion for the joint(s) it was pointed at. `applyCorrection`
//! is the other half — it is what a corrected chain actually needs before the
//! next model-space update.

const std = @import("std");
const c = @import("c.zig");
const err = @import("error.zig");
const math = @import("math.zig");
const SoaPose = @import("pose.zig").SoaPose;

/// Solves a three-joint chain (two bones) so its end reaches `target`.
///
/// `mid_axis`, `pole_vector`, `soften` and `weight` default to ozz's own
/// defaults. They are NOT zero-defaulted on purpose: `weight` is not checked
/// by the job's own validation, so a zeroed struct would run "successfully"
/// and silently produce an identity correction rather than erroring.
pub const TwoBoneJob = struct {
    target: [3]f32 = .{ 0, 0, 0 },
    mid_axis: [3]f32 = .{ 0, 0, 1 },
    pole_vector: [3]f32 = .{ 0, 1, 0 },
    twist_angle: f32 = 0,
    soften: f32 = 1,
    weight: f32 = 1,
    start_joint: *const math.Mat4,
    mid_joint: *const math.Mat4,
    end_joint: *const math.Mat4,

    /// Runs a two-bone IK solve.
    pub fn run(self: TwoBoneJob) err.Error!TwoBoneResult {
        var start_correction: [4]f32 = undefined;
        var mid_correction: [4]f32 = undefined;
        var reached: bool = false;
        var raw = c.IKTwoBoneJob{
            .target = self.target,
            .mid_axis = self.mid_axis,
            .pole_vector = self.pole_vector,
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
            .start_joint_correction = start_correction,
            .mid_joint_correction = mid_correction,
            .reached = reached,
        };
    }
};

pub const TwoBoneResult = struct {
    /// Local-space correction for `start_joint`/`mid_joint` (xyzw, w LAST).
    /// Left-multiply onto the joint's current local rotation — or hand it to
    /// `applyCorrection`.
    start_joint_correction: [4]f32,
    mid_joint_correction: [4]f32,
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
    target: [3]f32 = .{ 0, 0, 0 },
    forward: [3]f32 = .{ 1, 0, 0 },
    offset: [3]f32 = .{ 0, 0, 0 },
    up: [3]f32 = .{ 0, 1, 0 },
    pole_vector: [3]f32 = .{ 0, 1, 0 },
    twist_angle: f32 = 0,
    weight: f32 = 1,
    joint: *const math.Mat4,

    /// Runs an aim IK solve.
    pub fn run(self: AimJob) err.Error!AimResult {
        var correction: [4]f32 = undefined;
        var reached: bool = false;
        var raw = c.IKAimJob{
            .target = self.target,
            .forward = self.forward,
            .offset = self.offset,
            .up = self.up,
            .pole_vector = self.pole_vector,
            .twist_angle = self.twist_angle,
            .weight = self.weight,
            .joint = self.joint,
            .joint_correction = &correction,
            .reached = &reached,
        };
        try err.check(c.zozzIKAimJobRun(&raw));
        return .{ .joint_correction = correction, .reached = reached };
    }
};

pub const AimResult = struct {
    /// Local-space correction for `joint` (xyzw, w LAST).
    joint_correction: [4]f32,
    reached: bool,
};

/// Left-multiplies `correction` (xyzw, w LAST) onto `joint`'s current
/// local-space rotation in `pose`, in place. This is how a `TwoBoneResult`'s
/// or `AimResult`'s correction gets folded back before the pose is next
/// converted to model-space.
pub fn applyCorrection(pose: SoaPose, joint: u32, correction: [4]f32) err.Error!void {
    try err.check(c.zozzSoaPoseApplyLocalCorrection(pose.handle, @intCast(joint), &correction));
}
