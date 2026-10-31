//! Offline animation processing: key-frame reduction, additive delta
//! animations, root-motion extraction, and fixed-rate sample timing.
//!
//! Raw-animation sampling (`RawAnimation.sampleTrack`/`.sample`) and
//! re-timing (`.extractTimePoints`) live on `RawAnimation` itself, in
//! `offline.zig` — see there.

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
    handle: ?*c.AnimationOptimizer,

    /// Allocates an optimizer with ozz's default setting and no per-joint
    /// overrides.
    pub fn init(failure: *err.Failure) err.Error!AnimationOptimizer {
        var handle: *c.AnimationOptimizer = undefined;
        try err.check(failure, .animation_optimizer_create, c.zozzAnimationOptimizerCreate(&handle));
        return .{ .handle = handle };
    }

    pub fn deinit(self: *AnimationOptimizer) void {
        if (self.handle) |handle| c.zozzAnimationOptimizerDestroy(handle);
        self.handle = null;
    }

    /// Replaces the default setting applied to every joint not otherwise
    /// overridden.
    pub fn setSetting(self: AnimationOptimizer, setting: OptimizerSetting, failure: *err.Failure) err.Error!void {
        const raw = settingToC(setting);
        try err.check(failure, .animation_optimizer_set_setting, c.zozzAnimationOptimizerSetSetting(err.live(self.handle), &raw));
    }

    pub fn getSetting(self: AnimationOptimizer, failure: *err.Failure) err.Error!OptimizerSetting {
        var out: c.OptimizerSetting = undefined;
        try err.check(failure, .animation_optimizer_get_setting, c.zozzAnimationOptimizerGetSetting(err.live(self.handle), &out));
        return settingFromC(out);
    }

    /// Overrides the setting for one joint's chain. `joint` is a
    /// built-skeleton index (see offline.zig for the depth-first mapping);
    /// it is not checked against any particular skeleton here — only
    /// whichever skeleton `run` is later called with can make it valid or
    /// not.
    pub fn setJointOverride(self: AnimationOptimizer, joint: u32, setting: OptimizerSetting, failure: *err.Failure) err.Error!void {
        const raw = settingToC(setting);
        const joint_index = try err.narrow(failure, .animation_optimizer_set_joint_override, i32, joint);
        try err.check(failure, .animation_optimizer_set_joint_override, c.zozzAnimationOptimizerSetJointOverride(err.live(self.handle), joint_index, &raw));
    }

    /// Removes a joint's override, if any. Not an error if it had none.
    pub fn clearJointOverride(self: AnimationOptimizer, joint: u32, failure: *err.Failure) err.Error!void {
        const joint_index = try err.narrow(failure, .animation_optimizer_clear_joint_override, i32, joint);
        try err.check(failure, .animation_optimizer_clear_joint_override, c.zozzAnimationOptimizerClearJointOverride(err.live(self.handle), joint_index));
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
        failure: *err.Failure,
    ) err.Error!void {
        try err.check(failure, .animation_optimizer_run, c.zozzAnimationOptimizerRun(err.live(self.handle), err.live(input.handle), err.live(skeleton.handle), err.live(output.handle)));
    }
};

//=============================================================================
// Fixed-rate sampling time
//=============================================================================

/// Fixed-period sample times over `[0, duration]`: `numKeys` keys spaced
/// `1/frequency` apart, with the last key clamped to `duration` exactly
/// rather than drifting past it from accumulated floating-point error.
pub const FixedRateSamplingTime = struct {
    handle: ?*c.FixedRateSamplingTime,

    /// `duration` must be finite and >= 0; `frequency` must be finite and
    /// > 0.
    pub fn init(duration: f32, frequency: f32, failure: *err.Failure) err.Error!FixedRateSamplingTime {
        var handle: *c.FixedRateSamplingTime = undefined;
        try err.check(failure, .fixed_rate_sampling_time_create, c.zozzFixedRateSamplingTimeCreate(duration, frequency, &handle));
        return .{ .handle = handle };
    }

    pub fn deinit(self: *FixedRateSamplingTime) void {
        if (self.handle) |handle| c.zozzFixedRateSamplingTimeDestroy(handle);
        self.handle = null;
    }

    pub fn numKeys(self: FixedRateSamplingTime) usize {
        return c.zozzFixedRateSamplingTimeNumKeys(err.live(self.handle));
    }

    /// Time of the `key`-th sample. `key` must be < `numKeys`.
    pub fn at(self: FixedRateSamplingTime, key: usize, failure: *err.Failure) err.Error!f32 {
        var out: f32 = undefined;
        try err.check(failure, .fixed_rate_sampling_time_at, c.zozzFixedRateSamplingTimeAt(err.live(self.handle), key, &out));
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
    pub fn run(input: offline_mod.RawAnimation, output: offline_mod.RawAnimation, failure: *err.Failure) err.Error!void {
        try err.check(failure, .additive_animation_builder_run, c.zozzAdditiveAnimationBuilderRun(err.live(input.handle), err.live(output.handle)));
    }

    /// As `run`, but the reference pose is supplied explicitly: one
    /// transform per track of `input`. `reference_pose` is read only for the
    /// duration of the call.
    pub fn runWithReference(
        input: offline_mod.RawAnimation,
        reference_pose: []const math.Transform,
        output: offline_mod.RawAnimation,
        failure: *err.Failure,
    ) err.Error!void {
        try err.check(failure, .additive_animation_builder_run_with_reference, c.zozzAdditiveAnimationBuilderRunWithReference(
            err.live(input.handle),
            if (reference_pose.len == 0) null else reference_pose.ptr,
            reference_pose.len,
            err.live(output.handle),
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
    handle: ?*c.MotionExtractor,

    /// Allocates an extractor with ozz's defaults: root joint 0; position
    /// extracts X/Z against the skeleton reference, baked, not looped;
    /// rotation extracts Y (yaw) against the skeleton reference, baked, not
    /// looped.
    pub fn init(failure: *err.Failure) err.Error!MotionExtractor {
        var handle: *c.MotionExtractor = undefined;
        try err.check(failure, .motion_extractor_create, c.zozzMotionExtractorCreate(&handle));
        return .{ .handle = handle };
    }

    pub fn deinit(self: *MotionExtractor) void {
        if (self.handle) |handle| c.zozzMotionExtractorDestroy(handle);
        self.handle = null;
    }

    /// Index of the joint root motion is extracted from. Whether it is in
    /// range for a particular skeleton is checked at `run`.
    pub fn setRootJoint(self: MotionExtractor, joint: u32, failure: *err.Failure) err.Error!void {
        const joint_index = try err.narrow(failure, .motion_extractor_set_root_joint, i32, joint);
        try err.check(failure, .motion_extractor_set_root_joint, c.zozzMotionExtractorSetRootJoint(err.live(self.handle), joint_index));
    }

    pub fn rootJoint(self: MotionExtractor) u32 {
        return err.reported(u32, c.zozzMotionExtractorGetRootJoint(err.live(self.handle)));
    }

    pub fn setPositionSettings(self: MotionExtractor, settings: MotionSettings, failure: *err.Failure) err.Error!void {
        const raw = motionSettingsToC(settings);
        try err.check(failure, .motion_extractor_set_position_settings, c.zozzMotionExtractorSetPositionSettings(err.live(self.handle), &raw));
    }

    pub fn positionSettings(self: MotionExtractor, failure: *err.Failure) err.Error!MotionSettings {
        var out: c.MotionSettings = undefined;
        try err.check(failure, .motion_extractor_get_position_settings, c.zozzMotionExtractorGetPositionSettings(err.live(self.handle), &out));
        return motionSettingsFromC(out);
    }

    pub fn setRotationSettings(self: MotionExtractor, settings: MotionSettings, failure: *err.Failure) err.Error!void {
        const raw = motionSettingsToC(settings);
        try err.check(failure, .motion_extractor_set_rotation_settings, c.zozzMotionExtractorSetRotationSettings(err.live(self.handle), &raw));
    }

    pub fn rotationSettings(self: MotionExtractor, failure: *err.Failure) err.Error!MotionSettings {
        var out: c.MotionSettings = undefined;
        try err.check(failure, .motion_extractor_get_rotation_settings, c.zozzMotionExtractorGetRotationSettings(err.live(self.handle), &out));
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
        failure: *err.Failure,
    ) err.Error!void {
        try err.check(failure, .motion_extractor_run, c.zozzMotionExtractorRun(
            err.live(self.handle),
            err.live(input.handle),
            err.live(skeleton.handle),
            err.live(motion_position.handle),
            err.live(motion_rotation.handle),
            err.live(output.handle),
        ));
    }
};
