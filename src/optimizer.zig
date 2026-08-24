//! Offline animation processing: key-frame reduction, additive delta
//! animations, root-motion extraction, and fixed-rate sample timing.
//!
//! Raw-animation sampling (`RawAnimation.sampleTrack`/`.sample`) and
//! re-timing (`.extractTimePoints`) live on `RawAnimation` itself, in
//! `offline.zig` — see there.

const std = @import("std");
const c = @import("c.zig");
const err = @import("error.zig");
const math = @import("math.zig");
const offline_mod = @import("offline.zig");
const skeleton_mod = @import("skeleton.zig");
const rawtrack_mod = @import("rawtrack.zig");

//=============================================================================
// Animation optimizer
//=============================================================================

/// Key-frame reduction tolerances. `tolerance` is the maximum model-space
/// error the optimizer may introduce on a whole joint hierarchy; `distance`
/// is how far past the joint's own hierarchy that error is still measured
/// (emulating the effect on skinned geometry). ozz's own defaults favor
/// quality: 1e-3 (1mm) and 1e-1 (10cm) at a 1-unit-per-meter scale.
pub const OptimizerSetting = struct {
    tolerance: f32 = 1e-3,
    distance: f32 = 1e-1,
};

fn settingToC(s: OptimizerSetting) c.OptimizerSetting {
    return .{ .tolerance = s.tolerance, .distance = s.distance };
}

fn settingFromC(s: c.OptimizerSetting) OptimizerSetting {
    return .{ .tolerance = s.tolerance, .distance = s.distance };
}

/// Decimates a `RawAnimation` within an error tolerance, evaluated
/// hierarchically: the error a joint's decimation would produce is measured
/// out past the joint, so an aggressive shoulder tolerance cannot silently
/// blow up at the fingers. The global `setting` applies to every joint not
/// otherwise overridden.
pub const AnimationOptimizer = struct {
    handle: *c.AnimationOptimizer,

    /// Allocates an optimizer with ozz's default setting and no per-joint
    /// overrides.
    pub fn init() err.Error!AnimationOptimizer {
        var handle: *c.AnimationOptimizer = undefined;
        try err.check(c.zozzAnimationOptimizerCreate(&handle));
        return .{ .handle = handle };
    }

    pub fn deinit(self: AnimationOptimizer) void {
        c.zozzAnimationOptimizerDestroy(self.handle);
    }

    /// Replaces the default setting applied to every joint not otherwise
    /// overridden.
    pub fn setSetting(self: AnimationOptimizer, setting: OptimizerSetting) err.Error!void {
        try err.check(c.zozzAnimationOptimizerSetSetting(self.handle, settingToC(setting)));
    }

    pub fn getSetting(self: AnimationOptimizer) err.Error!OptimizerSetting {
        var out: c.OptimizerSetting = undefined;
        try err.check(c.zozzAnimationOptimizerGetSetting(self.handle, &out));
        return settingFromC(out);
    }

    /// Overrides the setting for one joint's chain. `joint` is a
    /// built-skeleton index (see offline.zig for the depth-first mapping);
    /// it is not checked against any particular skeleton here — only
    /// whichever skeleton `run` is later called with can make it valid or
    /// not.
    pub fn setJointOverride(self: AnimationOptimizer, joint: u32, setting: OptimizerSetting) err.Error!void {
        try err.check(c.zozzAnimationOptimizerSetJointOverride(self.handle, @intCast(joint), settingToC(setting)));
    }

    /// Removes a joint's override, if any. Not an error if it had none.
    pub fn clearJointOverride(self: AnimationOptimizer, joint: u32) err.Error!void {
        try err.check(c.zozzAnimationOptimizerClearJointOverride(self.handle, @intCast(joint)));
    }

    /// Runs the optimizer over `input`, writing the decimated clip to
    /// `output`. `output` must be distinct from `input`; its previous
    /// contents are discarded even on failure. `skeleton` must describe the
    /// same joint count as `input` has tracks, else `error.SkeletonMismatch`.
    pub fn run(
        self: AnimationOptimizer,
        input: offline_mod.RawAnimation,
        skeleton: skeleton_mod.Skeleton,
        output: offline_mod.RawAnimation,
    ) err.Error!void {
        try err.check(c.zozzAnimationOptimizerRun(self.handle, input.handle, skeleton.handle, output.handle));
    }
};

//=============================================================================
// Fixed-rate sampling time
//=============================================================================

/// Fixed-period sample times over `[0, duration]`: `numKeys` keys spaced
/// `1/frequency` apart, with the last key clamped to `duration` exactly
/// rather than drifting past it from accumulated floating-point error.
pub const FixedRateSamplingTime = struct {
    handle: *c.FixedRateSamplingTime,

    /// `duration` must be finite and >= 0; `frequency` must be finite and
    /// > 0.
    pub fn init(duration: f32, frequency: f32) err.Error!FixedRateSamplingTime {
        var handle: *c.FixedRateSamplingTime = undefined;
        try err.check(c.zozzFixedRateSamplingTimeCreate(duration, frequency, &handle));
        return .{ .handle = handle };
    }

    pub fn deinit(self: FixedRateSamplingTime) void {
        c.zozzFixedRateSamplingTimeDestroy(self.handle);
    }

    pub fn numKeys(self: FixedRateSamplingTime) usize {
        return c.zozzFixedRateSamplingTimeNumKeys(self.handle);
    }

    /// Time of the `key`-th sample. `key` must be < `numKeys`.
    pub fn at(self: FixedRateSamplingTime, key: usize) err.Error!f32 {
        var out: f32 = undefined;
        try err.check(c.zozzFixedRateSamplingTimeAt(self.handle, key, &out));
        return out;
    }
};

//=============================================================================
// Additive animation builder
//
// Stateless — a namespace for the two forms of the call rather than a handle
// type, matching the underlying ozz class (create/destroy would have nothing
// to hold).
//=============================================================================

pub const AdditiveAnimationBuilder = struct {
    /// Builds a delta animation from `input` using its own first frame as
    /// the reference pose, per joint. `output` must be distinct from
    /// `input`; its previous contents are discarded even on failure.
    pub fn run(input: offline_mod.RawAnimation, output: offline_mod.RawAnimation) err.Error!void {
        try err.check(c.zozzAdditiveAnimationBuilderRun(input.handle, output.handle));
    }

    /// As `run`, but the reference pose is supplied explicitly: one
    /// transform per track of `input`. `reference_pose` is read only for the
    /// duration of the call.
    pub fn runWithReference(
        input: offline_mod.RawAnimation,
        reference_pose: []const math.Transform,
        output: offline_mod.RawAnimation,
    ) err.Error!void {
        try err.check(c.zozzAdditiveAnimationBuilderRunWithReference(
            input.handle,
            if (reference_pose.len == 0) null else reference_pose.ptr,
            reference_pose.len,
            output.handle,
        ));
    }
};

//=============================================================================
// Motion extractor
//=============================================================================

/// Which pose an extracted motion component is measured against.
pub const MotionReference = c.MotionReference;

pub const MotionSettings = struct {
    /// Extract the X, Y, Z components respectively (translation: axes;
    /// rotation: decomposed pitch/yaw/roll about X/Y/Z).
    x: bool = false,
    y: bool = false,
    z: bool = false,
    reference: MotionReference = .skeleton,
    /// Bake the extracted (inverse) motion back into the output animation.
    bake: bool = true,
    /// Redistribute the first/last-key difference across the whole duration
    /// so the extracted track loops seamlessly.
    loop: bool = false,
};

fn motionSettingsToC(s: MotionSettings) c.MotionSettings {
    return .{ .x = s.x, .y = s.y, .z = s.z, .reference = s.reference, .bake = s.bake, .loop = s.loop };
}

fn motionSettingsFromC(s: c.MotionSettings) MotionSettings {
    return .{ .x = s.x, .y = s.y, .z = s.z, .reference = s.reference, .bake = s.bake, .loop = s.loop };
}

/// Pulls root motion (translation and/or rotation, axis by axis) out of the
/// root joint of a clip into separate tracks, optionally baking its inverse
/// back into the remaining animation so the two recombine to the original
/// motion at runtime.
pub const MotionExtractor = struct {
    handle: *c.MotionExtractor,

    /// Allocates an extractor with ozz's defaults: root joint 0; position
    /// extracts X/Z against the skeleton reference, baked, not looped;
    /// rotation extracts Y (yaw) against the skeleton reference, baked, not
    /// looped.
    pub fn init() err.Error!MotionExtractor {
        var handle: *c.MotionExtractor = undefined;
        try err.check(c.zozzMotionExtractorCreate(&handle));
        return .{ .handle = handle };
    }

    pub fn deinit(self: MotionExtractor) void {
        c.zozzMotionExtractorDestroy(self.handle);
    }

    /// Index of the joint root motion is extracted from. Whether it is in
    /// range for a particular skeleton is checked at `run`.
    pub fn setRootJoint(self: MotionExtractor, joint: u32) err.Error!void {
        try err.check(c.zozzMotionExtractorSetRootJoint(self.handle, @intCast(joint)));
    }

    pub fn rootJoint(self: MotionExtractor) u32 {
        return @intCast(c.zozzMotionExtractorGetRootJoint(self.handle));
    }

    pub fn setPositionSettings(self: MotionExtractor, settings: MotionSettings) err.Error!void {
        try err.check(c.zozzMotionExtractorSetPositionSettings(self.handle, motionSettingsToC(settings)));
    }

    pub fn positionSettings(self: MotionExtractor) err.Error!MotionSettings {
        var out: c.MotionSettings = undefined;
        try err.check(c.zozzMotionExtractorGetPositionSettings(self.handle, &out));
        return motionSettingsFromC(out);
    }

    pub fn setRotationSettings(self: MotionExtractor, settings: MotionSettings) err.Error!void {
        try err.check(c.zozzMotionExtractorSetRotationSettings(self.handle, motionSettingsToC(settings)));
    }

    pub fn rotationSettings(self: MotionExtractor) err.Error!MotionSettings {
        var out: c.MotionSettings = undefined;
        try err.check(c.zozzMotionExtractorGetRotationSettings(self.handle, &out));
        return motionSettingsFromC(out);
    }

    /// Extracts motion from `input`'s root joint into `motion_position` and
    /// `motion_rotation`, and writes the (optionally motion-baked) remainder
    /// to `output`. All three must be distinct from `input` and from each
    /// other, and their previous contents are discarded even on failure.
    /// `skeleton` must describe the same joint count as `input` has tracks,
    /// else `error.SkeletonMismatch`.
    pub fn run(
        self: MotionExtractor,
        input: offline_mod.RawAnimation,
        skeleton: skeleton_mod.Skeleton,
        motion_position: rawtrack_mod.RawFloat3Track,
        motion_rotation: rawtrack_mod.RawQuaternionTrack,
        output: offline_mod.RawAnimation,
    ) err.Error!void {
        try err.check(c.zozzMotionExtractorRun(
            self.handle,
            input.handle,
            skeleton.handle,
            motion_position.handle,
            motion_rotation.handle,
            output.handle,
        ));
    }
};
