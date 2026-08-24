//! Hand-written declarations mirroring `ffi/zozz.h`.
//!
//! These are written by hand rather than produced by `@cImport` so the package
//! stays translate-c-free and every type is exactly the shape the rest of the
//! wrapper wants. The cost of hand-writing is drift: nothing in either
//! compiler notices when this file stops agreeing with the header.
//!
//! Two checks close that, on two different axes, and neither replaces the
//! other:
//!
//!   * `abi_check.zig` compares this file against the real header at comptime
//!     — every type, every function signature, every enumerator, every
//!     constant, discovered by reflection with no hand-kept list. It runs
//!     translate-c in a test only, so the shipped module never sees it.
//!   * `zozzAbiLayout`, asserted in the test at the bottom of `zozz.zig`,
//!     compares this file against the COMPILED LIBRARY. The header is a
//!     source file; the library is a binary, and the two can disagree when
//!     the library was compiled with different macros than the header is
//!     being read with.
//!
//! Names are load-bearing rather than cosmetic, because `abi_check.zig` pairs
//! the two sides by computing the C spelling from the Zig one:
//!
//!   * a type `Foo`                pairs with `ZozzFoo`
//!   * a function `zozzFoo`        pairs with itself
//!   * a constant `foo_bar`        pairs with `ZOZZ_FOO_BAR`
//!   * an enum `Foo`'s field `bar` pairs with `ZOZZ_FOO_BAR`
//!
//! A declaration that breaks the convention fails the build.

const std = @import("std");

//=============================================================================
// Results
//=============================================================================

pub const Result = enum(c_int) {
    ok = 0,
    file_not_found = 1,
    io = 2,
    bad_format = 3,
    out_of_memory = 4,
    invalid_argument = 5,
    job_invalid = 6,
    buffer_too_small = 7,
    skeleton_mismatch = 8,
    invalid_data = 9,
};

/// Step vs. linear interpolation for a raw-track keyframe. Mirrors
/// `ZozzTrackInterpolation` (ffi/zozz_rawtrack.h).
pub const TrackInterpolation = enum(c_int) {
    step = 0,
    linear = 1,
};

/// Which pose an extracted-motion component is measured against. Mirrors
/// `ZozzMotionReference` (ffi/zozz_optimizer.h).
pub const MotionReference = enum(c_int) {
    absolute = 0,
    skeleton = 1,
    animation = 2,
};

//=============================================================================
// Plain data
//=============================================================================

pub const Transform = extern struct {
    translation: [3]f32,
    rotation: [4]f32,
    scale: [3]f32,
};

pub const Float4x4 = extern struct {
    m: [16]f32 align(16),
};

pub const Allocator = extern struct {
    allocate: ?*const fn (user: ?*anyopaque, size: usize, alignment: usize) callconv(.c) ?*anyopaque,
    deallocate: ?*const fn (user: ?*anyopaque, block: ?*anyopaque) callconv(.c) void,
    user: ?*anyopaque,
};

pub const OptimizerSetting = extern struct {
    tolerance: f32,
    distance: f32,
};

pub const MotionSettings = extern struct {
    x: bool,
    y: bool,
    z: bool,
    reference: MotionReference,
    bake: bool,
    loop: bool,
};

pub const AbiLayout = extern struct {
    layout_size: u32,

    transform_size: u32,
    transform_align: u32,
    transform_offset_translation: u32,
    transform_offset_rotation: u32,
    transform_offset_scale: u32,

    float4x4_size: u32,
    float4x4_align: u32,

    allocator_size: u32,
    allocator_align: u32,
    allocator_offset_allocate: u32,
    allocator_offset_deallocate: u32,
    allocator_offset_user: u32,

    result_count: u32,
};

//=============================================================================
// Constants
//=============================================================================

/// The parent index a root joint reports, and the one to pass to
/// `zozzRawSkeletonAddJoint` for a root. Mirrors `ZOZZ_NO_PARENT`.
///
/// It lives here rather than beside the skeleton wrapper because this is the
/// file `abi_check.zig` sweeps: a constant declared anywhere else is a second
/// independent literal that nothing compares against the header. `i16` because
/// that is what `zozzSkeletonJointParent` returns.
pub const no_parent: i16 = -1;

//=============================================================================
// Opaque handles
//=============================================================================

pub const Skeleton = opaque {};
pub const Animation = opaque {};
pub const SamplingContext = opaque {};
pub const SoaPose = opaque {};
pub const RawSkeleton = opaque {};
pub const RawAnimation = opaque {};

pub const AnimationOptimizer = opaque {};
pub const FixedRateSamplingTime = opaque {};
pub const MotionExtractor = opaque {};

pub const RawFloatTrack = opaque {};
pub const RawFloat2Track = opaque {};
pub const RawFloat3Track = opaque {};
pub const RawFloat4Track = opaque {};
pub const RawQuaternionTrack = opaque {};

pub const FloatTrack = opaque {};
pub const Float2Track = opaque {};
pub const Float3Track = opaque {};
pub const Float4Track = opaque {};
pub const QuaternionTrack = opaque {};

//=============================================================================
// Entry points
//=============================================================================

pub extern fn zozzVersion() u32;
pub extern fn zozzOzzVersion() u32;
pub extern fn zozzResultName(result: Result) [*:0]const u8;
pub extern fn zozzSetAllocator(alloc: ?*const Allocator) Result;
pub extern fn zozzAbiLayout(out: *AbiLayout) void;

pub extern fn zozzSkeletonLoadFile(path: [*:0]const u8, out: **Skeleton) Result;
pub extern fn zozzSkeletonLoadMemory(data: [*]const u8, size: usize, out: **Skeleton) Result;
pub extern fn zozzSkeletonDestroy(skeleton: ?*Skeleton) void;
pub extern fn zozzSkeletonNumJoints(skeleton: ?*const Skeleton) c_int;
pub extern fn zozzSkeletonNumSoaJoints(skeleton: ?*const Skeleton) c_int;
pub extern fn zozzSkeletonJointName(skeleton: ?*const Skeleton, joint: c_int) ?[*:0]const u8;
pub extern fn zozzSkeletonJointParent(skeleton: ?*const Skeleton, joint: c_int) i16;
pub extern fn zozzSkeletonRestPose(skeleton: ?*const Skeleton, out: [*]Transform, count: usize) Result;

pub extern fn zozzAnimationLoadFile(path: [*:0]const u8, out: **Animation) Result;
pub extern fn zozzAnimationLoadMemory(data: [*]const u8, size: usize, out: **Animation) Result;
pub extern fn zozzAnimationDestroy(animation: ?*Animation) void;
pub extern fn zozzAnimationDuration(animation: ?*const Animation) f32;
pub extern fn zozzAnimationNumTracks(animation: ?*const Animation) c_int;
pub extern fn zozzAnimationName(animation: ?*const Animation) [*:0]const u8;

pub extern fn zozzSoaPoseCreate(num_joints: c_int, out: **SoaPose) Result;
pub extern fn zozzSoaPoseDestroy(pose: ?*SoaPose) void;
pub extern fn zozzSoaPoseNumJoints(pose: ?*const SoaPose) c_int;
pub extern fn zozzSoaPoseSetIdentity(pose: *SoaPose) Result;
pub extern fn zozzSoaPoseSetRestPose(pose: *SoaPose, skeleton: *const Skeleton) Result;
pub extern fn zozzSoaPoseToLocalTransforms(pose: *const SoaPose, out: [*]Transform, count: usize) Result;
pub extern fn zozzSoaPoseFromLocalTransforms(pose: *SoaPose, in: [*]const Transform, count: usize) Result;

pub extern fn zozzRawSkeletonCreate(out: **RawSkeleton) Result;
pub extern fn zozzRawSkeletonDestroy(raw: ?*RawSkeleton) void;
pub extern fn zozzRawSkeletonAddJoint(raw: *RawSkeleton, parent: i32, name: [*:0]const u8, rest: *const Transform, out_index: ?*i32) Result;
pub extern fn zozzRawSkeletonNumJoints(raw: ?*const RawSkeleton) c_int;
pub extern fn zozzSkeletonBuild(raw: *const RawSkeleton, out: **Skeleton) Result;

pub extern fn zozzRawAnimationCreate(num_tracks: c_int, duration: f32, name: ?[*:0]const u8, out: **RawAnimation) Result;
pub extern fn zozzRawAnimationDestroy(raw: ?*RawAnimation) void;
pub extern fn zozzRawAnimationNumTracks(raw: ?*const RawAnimation) c_int;
pub extern fn zozzRawAnimationDuration(raw: ?*const RawAnimation) f32;
pub extern fn zozzRawAnimationPushTranslation(raw: *RawAnimation, track: c_int, time: f32, value: *const [3]f32) Result;
pub extern fn zozzRawAnimationPushRotation(raw: *RawAnimation, track: c_int, time: f32, value: *const [4]f32) Result;
pub extern fn zozzRawAnimationPushScale(raw: *RawAnimation, track: c_int, time: f32, value: *const [3]f32) Result;
pub extern fn zozzAnimationBuild(raw: *const RawAnimation, out: **Animation) Result;

//=============================================================================
// Animation optimizer (ffi/zozz_optimizer.h)
//=============================================================================

pub extern fn zozzAnimationOptimizerCreate(out: **AnimationOptimizer) Result;
pub extern fn zozzAnimationOptimizerDestroy(optimizer: ?*AnimationOptimizer) void;
pub extern fn zozzAnimationOptimizerSetSetting(optimizer: *AnimationOptimizer, setting: OptimizerSetting) Result;
pub extern fn zozzAnimationOptimizerGetSetting(optimizer: ?*const AnimationOptimizer, out: *OptimizerSetting) Result;
pub extern fn zozzAnimationOptimizerSetJointOverride(optimizer: *AnimationOptimizer, joint: i32, setting: OptimizerSetting) Result;
pub extern fn zozzAnimationOptimizerClearJointOverride(optimizer: *AnimationOptimizer, joint: i32) Result;
pub extern fn zozzAnimationOptimizerRun(
    optimizer: *const AnimationOptimizer,
    input: *const RawAnimation,
    skeleton: *const Skeleton,
    output: *RawAnimation,
) Result;

//=============================================================================
// Raw-animation sampling and re-timing utilities (ffi/zozz_optimizer.h)
//=============================================================================

pub extern fn zozzRawAnimationSampleTrack(raw: *const RawAnimation, track: i32, time: f32, out: *Transform) Result;
pub extern fn zozzRawAnimationSample(raw: *const RawAnimation, time: f32, out: [*]Transform, count: usize) Result;
pub extern fn zozzRawAnimationExtractTimePoints(
    raw: *const RawAnimation,
    out: ?[*]f32,
    count: usize,
    out_count: *usize,
) Result;

pub extern fn zozzFixedRateSamplingTimeCreate(duration: f32, frequency: f32, out: **FixedRateSamplingTime) Result;
pub extern fn zozzFixedRateSamplingTimeDestroy(self: ?*FixedRateSamplingTime) void;
pub extern fn zozzFixedRateSamplingTimeNumKeys(self: ?*const FixedRateSamplingTime) usize;
pub extern fn zozzFixedRateSamplingTimeAt(self: *const FixedRateSamplingTime, key: usize, out: *f32) Result;

//=============================================================================
// Additive animation builder (ffi/zozz_optimizer.h)
//=============================================================================

pub extern fn zozzAdditiveAnimationBuilderRun(input: *const RawAnimation, output: *RawAnimation) Result;
pub extern fn zozzAdditiveAnimationBuilderRunWithReference(
    input: *const RawAnimation,
    reference_pose: ?[*]const Transform,
    reference_pose_count: usize,
    output: *RawAnimation,
) Result;

//=============================================================================
// Motion extractor (ffi/zozz_optimizer.h)
//=============================================================================

pub extern fn zozzMotionExtractorCreate(out: **MotionExtractor) Result;
pub extern fn zozzMotionExtractorDestroy(extractor: ?*MotionExtractor) void;
pub extern fn zozzMotionExtractorSetRootJoint(extractor: *MotionExtractor, joint: i32) Result;
pub extern fn zozzMotionExtractorGetRootJoint(extractor: ?*const MotionExtractor) i32;
pub extern fn zozzMotionExtractorSetPositionSettings(extractor: *MotionExtractor, settings: MotionSettings) Result;
pub extern fn zozzMotionExtractorGetPositionSettings(extractor: ?*const MotionExtractor, out: *MotionSettings) Result;
pub extern fn zozzMotionExtractorSetRotationSettings(extractor: *MotionExtractor, settings: MotionSettings) Result;
pub extern fn zozzMotionExtractorGetRotationSettings(extractor: ?*const MotionExtractor, out: *MotionSettings) Result;
pub extern fn zozzMotionExtractorRun(
    extractor: *const MotionExtractor,
    input: *const RawAnimation,
    skeleton: *const Skeleton,
    motion_position: *RawFloat3Track,
    motion_rotation: *RawQuaternionTrack,
    output: *RawAnimation,
) Result;

//=============================================================================
// Raw tracks, TrackBuilder, TrackOptimizer (ffi/zozz_rawtrack.h)
//=============================================================================

pub extern fn zozzFloatTrackDestroy(track: ?*FloatTrack) void;
pub extern fn zozzFloat2TrackDestroy(track: ?*Float2Track) void;
pub extern fn zozzFloat3TrackDestroy(track: ?*Float3Track) void;
pub extern fn zozzFloat4TrackDestroy(track: ?*Float4Track) void;
pub extern fn zozzQuaternionTrackDestroy(track: ?*QuaternionTrack) void;

pub extern fn zozzRawFloatTrackCreate(out: **RawFloatTrack) Result;
pub extern fn zozzRawFloatTrackDestroy(raw: ?*RawFloatTrack) void;
pub extern fn zozzRawFloatTrackNumKeyframes(raw: ?*const RawFloatTrack) c_int;
pub extern fn zozzRawFloatTrackPushKeyframe(raw: *RawFloatTrack, interpolation: TrackInterpolation, ratio: f32, value: f32) Result;
pub extern fn zozzFloatTrackBuild(raw: *const RawFloatTrack, out: **FloatTrack) Result;
pub extern fn zozzRawFloatTrackOptimize(input: *const RawFloatTrack, tolerance: f32, output: *RawFloatTrack) Result;

pub extern fn zozzRawFloat2TrackCreate(out: **RawFloat2Track) Result;
pub extern fn zozzRawFloat2TrackDestroy(raw: ?*RawFloat2Track) void;
pub extern fn zozzRawFloat2TrackNumKeyframes(raw: ?*const RawFloat2Track) c_int;
pub extern fn zozzRawFloat2TrackPushKeyframe(raw: *RawFloat2Track, interpolation: TrackInterpolation, ratio: f32, value: *const [2]f32) Result;
pub extern fn zozzFloat2TrackBuild(raw: *const RawFloat2Track, out: **Float2Track) Result;
pub extern fn zozzRawFloat2TrackOptimize(input: *const RawFloat2Track, tolerance: f32, output: *RawFloat2Track) Result;

pub extern fn zozzRawFloat3TrackCreate(out: **RawFloat3Track) Result;
pub extern fn zozzRawFloat3TrackDestroy(raw: ?*RawFloat3Track) void;
pub extern fn zozzRawFloat3TrackNumKeyframes(raw: ?*const RawFloat3Track) c_int;
pub extern fn zozzRawFloat3TrackPushKeyframe(raw: *RawFloat3Track, interpolation: TrackInterpolation, ratio: f32, value: *const [3]f32) Result;
pub extern fn zozzFloat3TrackBuild(raw: *const RawFloat3Track, out: **Float3Track) Result;
pub extern fn zozzRawFloat3TrackOptimize(input: *const RawFloat3Track, tolerance: f32, output: *RawFloat3Track) Result;

pub extern fn zozzRawFloat4TrackCreate(out: **RawFloat4Track) Result;
pub extern fn zozzRawFloat4TrackDestroy(raw: ?*RawFloat4Track) void;
pub extern fn zozzRawFloat4TrackNumKeyframes(raw: ?*const RawFloat4Track) c_int;
pub extern fn zozzRawFloat4TrackPushKeyframe(raw: *RawFloat4Track, interpolation: TrackInterpolation, ratio: f32, value: *const [4]f32) Result;
pub extern fn zozzFloat4TrackBuild(raw: *const RawFloat4Track, out: **Float4Track) Result;
pub extern fn zozzRawFloat4TrackOptimize(input: *const RawFloat4Track, tolerance: f32, output: *RawFloat4Track) Result;

pub extern fn zozzRawQuaternionTrackCreate(out: **RawQuaternionTrack) Result;
pub extern fn zozzRawQuaternionTrackDestroy(raw: ?*RawQuaternionTrack) void;
pub extern fn zozzRawQuaternionTrackNumKeyframes(raw: ?*const RawQuaternionTrack) c_int;
pub extern fn zozzRawQuaternionTrackPushKeyframe(raw: *RawQuaternionTrack, interpolation: TrackInterpolation, ratio: f32, value: *const [4]f32) Result;
pub extern fn zozzQuaternionTrackBuild(raw: *const RawQuaternionTrack, out: **QuaternionTrack) Result;
pub extern fn zozzRawQuaternionTrackOptimize(input: *const RawQuaternionTrack, tolerance: f32, output: *RawQuaternionTrack) Result;

pub extern fn zozzSamplingContextCreate(max_tracks: c_int, out: **SamplingContext) Result;
pub extern fn zozzSamplingContextDestroy(context: ?*SamplingContext) void;
pub extern fn zozzSamplingContextInvalidate(context: ?*SamplingContext) void;
pub extern fn zozzSamplingContextMaxTracks(context: ?*const SamplingContext) c_int;
pub extern fn zozzSample(animation: *const Animation, context: *SamplingContext, ratio: f32, out: *SoaPose) Result;

pub extern fn zozzLocalToModel(
    skeleton: *const Skeleton,
    locals: *const SoaPose,
    root: ?*const Float4x4,
    out: [*]Float4x4,
    count: usize,
) Result;
