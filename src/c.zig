//! Hand-written declarations mirroring `ffi/zozz.h`, written by hand rather
//! than produced by `@cImport` so the package stays translate-c-free. Two
//! checks close the resulting drift risk, on different axes: `abi_check.zig`
//! compares this file against the real header at comptime (every type,
//! signature, enumerator, constant, via reflection, in a test only); and
//! `zozzAbiLayout` (asserted at the bottom of `zozz.zig`) compares this file
//! against the COMPILED LIBRARY instead, since header and library can disagree
//! when built with different macros. Names are load-bearing: `abi_check.zig`
//! pairs the two sides by computing the C spelling from the Zig one — type
//! `Foo` -> `ZozzFoo`; function `zozzFoo` -> itself; constant `foo_bar` ->
//! `ZOZZ_FOO_BAR`; enum `Foo` field `bar` -> `ZOZZ_FOO_BAR`. A declaration that
//! breaks the convention fails the build.

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
    /// The entry point exists but its build option is off (-Doptions,
    /// -Dgltf): the library was compiled without the code it needs.
    unsupported = 10,
    /// A different allocator was offered while blocks the installed one
    /// produced are still live.
    allocator_in_use = 11,
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

/// Matches `ZozzSeekOrigin` (ffi/zozz_archive.h) exactly, so a Zig-side `seek`
/// callback can hand these straight to whatever it wraps.
pub const SeekOrigin = enum(c_int) {
    current = 0,
    end = 1,
    set = 2,
};

/// Mirrors `ZozzEndianness` (ffi/zozz_archive.h) exactly.
pub const Endianness = enum(c_int) {
    big = 0,
    little = 1,
};

/// Mirrors `ZozzLogLevel` (ffi/zozz_core.h) exactly.
pub const LogLevel = enum(c_int) {
    silent = 0,
    standard = 1,
    verbose = 2,
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

/// One SIMD register of four floats, `ZozzSimdFloat4`. Distinct from
/// `math.SimdFloat4`, which is the `@Vector(4, f32)` every math function
/// takes: this is the struct the header declares, and `pose.zig` asserts the
/// two agree in size and alignment before casting between them.
pub const SimdFloat4 = extern struct {
    f: [4]f32 align(16),
};

/// Four joints' worth of one 3-component value. `x[i]` is joint i's x.
pub const SoaFloat3 = extern struct {
    x: [4]f32 align(16),
    y: [4]f32,
    z: [4]f32,
};

/// Four joints' worth of a quaternion, (x, y, z, w) like `Transform`'s.
pub const SoaQuaternion = extern struct {
    x: [4]f32 align(16),
    y: [4]f32,
    z: [4]f32,
    w: [4]f32,
};

/// Four joints' local-space transforms: `ozz::math::SoaTransform`, and the
/// currency of the job pipeline. A pose is an array of these, one per four
/// joints, owned by the caller.
pub const SoaTransform = extern struct {
    translation: SoaFloat3,
    rotation: SoaQuaternion,
    scale: SoaFloat3,
};

pub const Allocator = extern struct {
    allocate: ?*const fn (user: ?*anyopaque, size: usize, alignment: usize) callconv(.c) ?*anyopaque,
    deallocate: ?*const fn (user: ?*anyopaque, block: ?*anyopaque) callconv(.c) void,
    user: ?*anyopaque,
};

/// One weighted input to `zozzMotionBlend`.
pub const MotionBlendLayer = extern struct {
    weight: f32,
    /// Borrowed for the call only; not retained afterward.
    delta: *const Transform,
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

    simd_float4_size: u32,
    simd_float4_align: u32,

    soa_transform_size: u32,
    soa_transform_align: u32,
    soa_transform_offset_translation: u32,
    soa_transform_offset_rotation: u32,
    soa_transform_offset_scale: u32,

    blending_layer_size: u32,
    blending_layer_align: u32,
    blending_layer_offset_weight: u32,
    blending_layer_offset_transform: u32,
    blending_layer_offset_num_transform: u32,
    blending_layer_offset_joint_weights: u32,
    blending_layer_offset_num_joint_weights: u32,

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
/// `zozzRawSkeletonAddJoint` for a root. Mirrors `ZOZZ_NO_PARENT`. It lives
/// here, not beside the skeleton wrapper, because this is the file
/// `abi_check.zig` sweeps — a constant declared anywhere else is a second,
/// uncompared literal. `i16` because that is what
/// `zozzSkeletonJointParent` returns.
pub const no_parent: i16 = -1;

/// ozz's `Skeleton::kMaxJoints`, and the value ozz gives
/// `LocalToModelJob::to` by default -- "walk to the last joint". Mirrors
/// `ZOZZ_MAX_JOINTS`; `ffi/zozz_abi.cpp` static_asserts it against ozz.
pub const max_joints: c_int = 1024;

//=============================================================================
// Callback types
//=============================================================================

/// Visits one joint during `zozzSkeletonIterateJointsDepthFirst(Reverse)`.
pub const JointVisitor = *const fn (
    joint: c_int,
    parent: c_int,
    user: ?*anyopaque,
) callconv(.c) void;

//=============================================================================
// Opaque handles
//=============================================================================

pub const Skeleton = opaque {};
pub const Animation = opaque {};
pub const SamplingContext = opaque {};
pub const RawSkeleton = opaque {};
pub const RawAnimation = opaque {};
pub const FloatTrack = opaque {};
pub const Float2Track = opaque {};
pub const Float3Track = opaque {};
pub const Float4Track = opaque {};
pub const QuaternionTrack = opaque {};
pub const TrackTriggeringIterator = opaque {};

//=============================================================================
// Track plain data
//=============================================================================

pub const TrackEdge = extern struct {
    ratio: f32,
    rising: bool,
};

pub const AnimationOptimizer = opaque {};
pub const FixedRateSamplingTime = opaque {};
pub const MotionExtractor = opaque {};

pub const RawFloatTrack = opaque {};
pub const RawFloat2Track = opaque {};
pub const RawFloat3Track = opaque {};
pub const RawFloat4Track = opaque {};
pub const RawQuaternionTrack = opaque {};

//=============================================================================
// Entry points
//=============================================================================

pub extern fn zozzVersion() u32;
pub extern fn zozzOzzVersion() u32;
pub extern fn zozzResultName(result: Result) [*:0]const u8;
pub extern fn zozzSetAllocator(alloc: ?*const Allocator) Result;
pub extern fn zozzGetAllocator(out: *Allocator, installed: *bool) Result;
pub extern fn zozzAllocatorLiveBlocks() usize;
pub extern fn zozzAbiLayout(out: *AbiLayout) void;

pub extern fn zozzSetLogLevel(level: LogLevel) Result;
pub extern fn zozzGetLogLevel() LogLevel;

pub extern fn zozzSkeletonLoadFile(path: [*:0]const u8, out: **Skeleton) Result;
pub extern fn zozzSkeletonLoadMemory(data: [*]const u8, size: usize, out: **Skeleton) Result;
pub extern fn zozzSkeletonDestroy(skeleton: ?*Skeleton) void;
pub extern fn zozzSkeletonNumJoints(skeleton: ?*const Skeleton) c_int;
pub extern fn zozzSkeletonNumSoaJoints(skeleton: ?*const Skeleton) c_int;
pub extern fn zozzSkeletonJointName(skeleton: ?*const Skeleton, joint: c_int) ?[*:0]const u8;
pub extern fn zozzSkeletonJointParent(skeleton: ?*const Skeleton, joint: c_int) i16;
pub extern fn zozzSkeletonRestPose(skeleton: ?*const Skeleton, out: [*]Transform, count: usize) Result;
pub extern fn zozzSkeletonRestPoseSoa(skeleton: ?*const Skeleton, out: [*]SoaTransform, blocks: usize) Result;

pub extern fn zozzAnimationLoadFile(path: [*:0]const u8, out: **Animation) Result;
pub extern fn zozzAnimationLoadMemory(data: [*]const u8, size: usize, out: **Animation) Result;
pub extern fn zozzAnimationDestroy(animation: ?*Animation) void;
pub extern fn zozzAnimationDuration(animation: ?*const Animation) f32;
pub extern fn zozzAnimationNumTracks(animation: ?*const Animation) c_int;
pub extern fn zozzAnimationName(animation: ?*const Animation) [*:0]const u8;
pub extern fn zozzAnimationNumSoaTracks(animation: ?*const Animation) c_int;
pub extern fn zozzAnimationSize(animation: ?*const Animation) usize;
pub extern fn zozzAnimationNumTimepoints(animation: ?*const Animation) c_int;
pub extern fn zozzAnimationTimepoints(animation: ?*const Animation, out: [*]f32, count: usize) Result;

/// Non-exhaustive: a host can pass any integer, and the C side rejects one it
/// does not recognise rather than reading an out-of-range enum.
pub const KeyframeChannel = enum(c_int) { translation = 0, rotation = 1, scale = 2, _ };

pub const KeyframesCtrl = extern struct {
    num_ratio_bytes: usize,
    num_previouses: usize,
    num_iframe_entry_bytes: usize,
    num_iframe_desc: usize,
    iframe_interval: f32,
};

pub extern fn zozzAnimationKeyframesCtrl(animation: ?*const Animation, channel: KeyframeChannel, out: ?*KeyframesCtrl) Result;
pub extern fn zozzAnimationKeyframeRatios(animation: ?*const Animation, channel: KeyframeChannel, out: [*]u8, count: usize) Result;
pub extern fn zozzAnimationKeyframePreviouses(animation: ?*const Animation, channel: KeyframeChannel, out: [*]u16, count: usize) Result;
pub extern fn zozzAnimationKeyframeIframeEntries(animation: ?*const Animation, channel: KeyframeChannel, out: [*]u8, count: usize) Result;
pub extern fn zozzAnimationKeyframeIframeDesc(animation: ?*const Animation, channel: KeyframeChannel, out: [*]u32, count: usize) Result;

pub extern fn zozzSoaBlocks(num_joints: c_int) usize;
pub extern fn zozzSoaPoseSetIdentity(pose: [*]SoaTransform, blocks: usize) Result;
pub extern fn zozzSoaPoseToLocalTransforms(pose: [*]const SoaTransform, blocks: usize, out: [*]Transform, num_joints: usize) Result;
pub extern fn zozzSoaPoseFromLocalTransforms(in: [*]const Transform, num_joints: usize, pose: [*]SoaTransform, blocks: usize) Result;
pub extern fn zozzSoaWeightsPack(in: [*]const f32, num_joints: usize, out: [*]SimdFloat4, blocks: usize) Result;

pub extern fn zozzRawSkeletonCreate(out: **RawSkeleton) Result;
pub extern fn zozzRawSkeletonDestroy(raw: ?*RawSkeleton) void;
pub extern fn zozzRawSkeletonAddJoint(raw: *RawSkeleton, parent: i32, name: [*:0]const u8, rest: *const Transform, out_index: ?*i32) Result;
pub extern fn zozzRawSkeletonNumJoints(raw: ?*const RawSkeleton) c_int;
pub extern fn zozzRawSkeletonJointName(raw: ?*const RawSkeleton, joint: i32) ?[*:0]const u8;
pub extern fn zozzRawSkeletonJointParent(raw: ?*const RawSkeleton, joint: i32) i32;
pub extern fn zozzRawSkeletonJointRest(raw: ?*const RawSkeleton, joint: i32, out: *Transform) Result;
pub extern fn zozzRawSkeletonIterateJointsBreadthFirst(raw: ?*const RawSkeleton, visitor: JointVisitor, user: ?*anyopaque) Result;
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
pub extern fn zozzAnimationOptimizerSetSetting(optimizer: *AnimationOptimizer, setting: *const OptimizerSetting) Result;
pub extern fn zozzAnimationOptimizerGetSetting(optimizer: ?*const AnimationOptimizer, out: *OptimizerSetting) Result;
pub extern fn zozzAnimationOptimizerSetJointOverride(optimizer: *AnimationOptimizer, joint: i32, setting: *const OptimizerSetting) Result;
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

pub const ModelSpaceSample = extern struct {
    time: f32,
    transform: Float4x4,
};

pub extern fn zozzRawAnimationSampleTrackModelSpace(
    raw: *const RawAnimation,
    skeleton: *const Skeleton,
    joint: i32,
    out: ?[*]ModelSpaceSample,
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
pub extern fn zozzMotionExtractorSetPositionSettings(extractor: *MotionExtractor, settings: *const MotionSettings) Result;
pub extern fn zozzMotionExtractorGetPositionSettings(extractor: ?*const MotionExtractor, out: *MotionSettings) Result;
pub extern fn zozzMotionExtractorSetRotationSettings(extractor: *MotionExtractor, settings: *const MotionSettings) Result;
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
pub extern fn zozzSamplingContextResize(context: ?*SamplingContext, max_tracks: c_int) Result;
pub extern fn zozzSamplingContextInvalidate(context: ?*SamplingContext) void;
pub extern fn zozzSamplingContextMaxTracks(context: ?*const SamplingContext) c_int;
pub extern fn zozzSample(animation: *const Animation, context: *SamplingContext, ratio: f32, out: [*]SoaTransform, blocks: usize) Result;

pub extern fn zozzLocalToModel(
    skeleton: *const Skeleton,
    locals: [*]const SoaTransform,
    blocks: usize,
    root: ?*const Float4x4,
    from: c_int,
    to: c_int,
    from_excluded: c_int,
    out: [*]Float4x4,
    count: usize,
) Result;

pub extern fn zozzFloatTrackLoadFile(path: [*:0]const u8, out: **FloatTrack) Result;
pub extern fn zozzFloatTrackLoadMemory(data: [*]const u8, size: usize, out: **FloatTrack) Result;
pub extern fn zozzFloatTrackDestroy(track: ?*FloatTrack) void;
pub extern fn zozzFloatTrackName(track: ?*const FloatTrack) [*:0]const u8;
pub extern fn zozzFloatTrackSample(track: *const FloatTrack, ratio: f32, out: *f32) Result;
pub extern fn zozzFloatTrackNumKeyframes(track: ?*const FloatTrack) c_int;
pub extern fn zozzFloatTrackRatios(track: ?*const FloatTrack, out: [*]f32, count: usize) Result;
pub extern fn zozzFloatTrackValues(track: ?*const FloatTrack, out: [*]f32, count: usize) Result;
pub extern fn zozzFloatTrackSteps(track: ?*const FloatTrack, out: [*]TrackInterpolation, count: usize) Result;

pub extern fn zozzFloat2TrackLoadFile(path: [*:0]const u8, out: **Float2Track) Result;
pub extern fn zozzFloat2TrackLoadMemory(data: [*]const u8, size: usize, out: **Float2Track) Result;
pub extern fn zozzFloat2TrackDestroy(track: ?*Float2Track) void;
pub extern fn zozzFloat2TrackName(track: ?*const Float2Track) [*:0]const u8;
pub extern fn zozzFloat2TrackSample(track: *const Float2Track, ratio: f32, out: *[2]f32) Result;
pub extern fn zozzFloat2TrackNumKeyframes(track: ?*const Float2Track) c_int;
pub extern fn zozzFloat2TrackRatios(track: ?*const Float2Track, out: [*]f32, count: usize) Result;
pub extern fn zozzFloat2TrackValues(track: ?*const Float2Track, out: [*][2]f32, count: usize) Result;
pub extern fn zozzFloat2TrackSteps(track: ?*const Float2Track, out: [*]TrackInterpolation, count: usize) Result;

pub extern fn zozzFloat3TrackLoadFile(path: [*:0]const u8, out: **Float3Track) Result;
pub extern fn zozzFloat3TrackLoadMemory(data: [*]const u8, size: usize, out: **Float3Track) Result;
pub extern fn zozzFloat3TrackDestroy(track: ?*Float3Track) void;
pub extern fn zozzFloat3TrackName(track: ?*const Float3Track) [*:0]const u8;
pub extern fn zozzFloat3TrackSample(track: *const Float3Track, ratio: f32, out: *[3]f32) Result;
pub extern fn zozzFloat3TrackNumKeyframes(track: ?*const Float3Track) c_int;
pub extern fn zozzFloat3TrackRatios(track: ?*const Float3Track, out: [*]f32, count: usize) Result;
pub extern fn zozzFloat3TrackValues(track: ?*const Float3Track, out: [*][3]f32, count: usize) Result;
pub extern fn zozzFloat3TrackSteps(track: ?*const Float3Track, out: [*]TrackInterpolation, count: usize) Result;

pub extern fn zozzFloat4TrackLoadFile(path: [*:0]const u8, out: **Float4Track) Result;
pub extern fn zozzFloat4TrackLoadMemory(data: [*]const u8, size: usize, out: **Float4Track) Result;
pub extern fn zozzFloat4TrackDestroy(track: ?*Float4Track) void;
pub extern fn zozzFloat4TrackName(track: ?*const Float4Track) [*:0]const u8;
pub extern fn zozzFloat4TrackSample(track: *const Float4Track, ratio: f32, out: *[4]f32) Result;
pub extern fn zozzFloat4TrackNumKeyframes(track: ?*const Float4Track) c_int;
pub extern fn zozzFloat4TrackRatios(track: ?*const Float4Track, out: [*]f32, count: usize) Result;
pub extern fn zozzFloat4TrackValues(track: ?*const Float4Track, out: [*][4]f32, count: usize) Result;
pub extern fn zozzFloat4TrackSteps(track: ?*const Float4Track, out: [*]TrackInterpolation, count: usize) Result;

pub extern fn zozzQuaternionTrackLoadFile(path: [*:0]const u8, out: **QuaternionTrack) Result;
pub extern fn zozzQuaternionTrackLoadMemory(data: [*]const u8, size: usize, out: **QuaternionTrack) Result;
pub extern fn zozzQuaternionTrackDestroy(track: ?*QuaternionTrack) void;
pub extern fn zozzQuaternionTrackName(track: ?*const QuaternionTrack) [*:0]const u8;
pub extern fn zozzQuaternionTrackSample(track: *const QuaternionTrack, ratio: f32, out: *[4]f32) Result;
pub extern fn zozzQuaternionTrackNumKeyframes(track: ?*const QuaternionTrack) c_int;
pub extern fn zozzQuaternionTrackRatios(track: ?*const QuaternionTrack, out: [*]f32, count: usize) Result;
pub extern fn zozzQuaternionTrackValues(track: ?*const QuaternionTrack, out: [*][4]f32, count: usize) Result;
pub extern fn zozzQuaternionTrackSteps(track: ?*const QuaternionTrack, out: [*]TrackInterpolation, count: usize) Result;

pub extern fn zozzFloatTrackTriggeringJobRun(
    track: *const FloatTrack,
    from: f32,
    to: f32,
    threshold: f32,
    out: **TrackTriggeringIterator,
) Result;
pub extern fn zozzTrackTriggeringIteratorDestroy(iterator: ?*TrackTriggeringIterator) void;
pub extern fn zozzTrackTriggeringIteratorValid(iterator: ?*const TrackTriggeringIterator) bool;
pub extern fn zozzTrackTriggeringIteratorNext(iterator: *TrackTriggeringIterator) Result;
pub extern fn zozzTrackTriggeringIteratorGet(iterator: *const TrackTriggeringIterator, out: *TrackEdge) Result;

//=============================================================================
// Blending
//=============================================================================

/// `ozz::animation::BlendingJob::Layer` field for field: a float, then two
/// {pointer, count} pairs where ozz has two `ozz::span`. `zozz_abi.cpp`
/// asserts every offset against ozz's own type.
pub const BlendingLayer = extern struct {
    weight: f32,
    transform: ?[*]const SoaTransform,
    num_transform: usize,
    joint_weights: ?[*]const SimdFloat4,
    num_joint_weights: usize,
};

pub extern fn zozzBlendingRun(
    layers: ?[*]const BlendingLayer,
    num_layers: usize,
    additive_layers: ?[*]const BlendingLayer,
    num_additive_layers: usize,
    rest_pose: [*]const SoaTransform,
    threshold: f32,
    out: [*]SoaTransform,
    blocks: usize,
) Result;

//=============================================================================
// Archive
//=============================================================================

pub const Stream = extern struct {
    opened: ?*const fn (user: ?*anyopaque) callconv(.c) c_int,
    write: ?*const fn (user: ?*anyopaque, data: ?*const anyopaque, size: usize) callconv(.c) usize,
    read: ?*const fn (user: ?*anyopaque, buffer: ?*anyopaque, size: usize) callconv(.c) usize,
    seek: ?*const fn (user: ?*anyopaque, offset: c_int, origin: SeekOrigin) callconv(.c) c_int,
    tell: ?*const fn (user: ?*anyopaque) callconv(.c) c_int,
    user: ?*anyopaque,
};

pub const OArchive = opaque {};
pub const IArchive = opaque {};

pub extern fn zozzOArchiveCreate(stream: ?*const Stream, endianness: Endianness, out: **OArchive) Result;
pub extern fn zozzOArchiveDestroy(archive: ?*OArchive) void;
pub extern fn zozzOArchiveSaveBinary(archive: ?*OArchive, data: ?*const anyopaque, size: usize) Result;
pub extern fn zozzOArchiveSaveInt32(archive: ?*OArchive, value: i32) Result;
pub extern fn zozzOArchiveSaveFloat(archive: ?*OArchive, value: f32) Result;
pub extern fn zozzOArchiveSaveSkeleton(archive: ?*OArchive, skeleton: ?*const Skeleton) Result;
pub extern fn zozzOArchiveSaveAnimation(archive: ?*OArchive, animation: ?*const Animation) Result;
pub extern fn zozzOArchiveSaveFloatTrack(archive: ?*OArchive, track: ?*const FloatTrack) Result;
pub extern fn zozzOArchiveSaveFloat2Track(archive: ?*OArchive, track: ?*const Float2Track) Result;
pub extern fn zozzOArchiveSaveFloat3Track(archive: ?*OArchive, track: ?*const Float3Track) Result;
pub extern fn zozzOArchiveSaveFloat4Track(archive: ?*OArchive, track: ?*const Float4Track) Result;
pub extern fn zozzOArchiveSaveQuaternionTrack(archive: ?*OArchive, track: ?*const QuaternionTrack) Result;

pub extern fn zozzIArchiveCreate(stream: ?*const Stream, out: **IArchive) Result;
pub extern fn zozzIArchiveDestroy(archive: ?*IArchive) void;
pub extern fn zozzIArchiveEndianSwap(archive: ?*const IArchive) bool;
pub extern fn zozzIArchiveLoadBinary(archive: ?*IArchive, data: ?*anyopaque, size: usize) Result;
pub extern fn zozzIArchiveLoadInt32(archive: ?*IArchive, out: *i32) Result;
pub extern fn zozzIArchiveLoadFloat(archive: ?*IArchive, out: *f32) Result;
pub extern fn zozzIArchiveLoadSkeleton(archive: ?*IArchive, out: **Skeleton) Result;
pub extern fn zozzIArchiveLoadAnimation(archive: ?*IArchive, out: **Animation) Result;
pub extern fn zozzIArchiveLoadFloatTrack(archive: ?*IArchive, out: **FloatTrack) Result;
pub extern fn zozzIArchiveLoadFloat2Track(archive: ?*IArchive, out: **Float2Track) Result;
pub extern fn zozzIArchiveLoadFloat3Track(archive: ?*IArchive, out: **Float3Track) Result;
pub extern fn zozzIArchiveLoadFloat4Track(archive: ?*IArchive, out: **Float4Track) Result;
pub extern fn zozzIArchiveLoadQuaternionTrack(archive: ?*IArchive, out: **QuaternionTrack) Result;
pub extern fn zozzIArchiveTestSkeleton(archive: ?*IArchive) bool;
pub extern fn zozzIArchiveTestAnimation(archive: ?*IArchive) bool;
pub extern fn zozzIArchiveTestFloatTrack(archive: ?*IArchive) bool;
pub extern fn zozzIArchiveTestFloat2Track(archive: ?*IArchive) bool;
pub extern fn zozzIArchiveTestFloat3Track(archive: ?*IArchive) bool;
pub extern fn zozzIArchiveTestFloat4Track(archive: ?*IArchive) bool;
pub extern fn zozzIArchiveTestQuaternionTrack(archive: ?*IArchive) bool;

pub extern fn zozzSkeletonSaveFile(skeleton: ?*const Skeleton, path: [*:0]const u8) Result;
pub extern fn zozzAnimationSaveFile(animation: ?*const Animation, path: [*:0]const u8) Result;
pub extern fn zozzFloatTrackSaveFile(track: ?*const FloatTrack, path: [*:0]const u8) Result;
pub extern fn zozzFloat2TrackSaveFile(track: ?*const Float2Track, path: [*:0]const u8) Result;
pub extern fn zozzFloat3TrackSaveFile(track: ?*const Float3Track, path: [*:0]const u8) Result;
pub extern fn zozzFloat4TrackSaveFile(track: ?*const Float4Track, path: [*:0]const u8) Result;
pub extern fn zozzQuaternionTrackSaveFile(track: ?*const QuaternionTrack, path: [*:0]const u8) Result;
pub extern fn zozzSkeletonJointRestPoseLocal(skeleton: ?*const Skeleton, joint: c_int, out: *Transform) Result;
pub extern fn zozzSkeletonRestPoseModelSpace(skeleton: ?*const Skeleton, out: [*]Float4x4, count: usize) Result;
pub extern fn zozzSkeletonJointIsLeaf(skeleton: ?*const Skeleton, joint: c_int, out: *bool) Result;
pub extern fn zozzSkeletonFindJoint(skeleton: ?*const Skeleton, name: ?[*:0]const u8) c_int;
pub extern fn zozzSkeletonIterateJointsDepthFirst(skeleton: ?*const Skeleton, from: c_int, visitor: JointVisitor, user: ?*anyopaque) Result;
pub extern fn zozzSkeletonIterateJointsDepthFirstReverse(skeleton: ?*const Skeleton, visitor: JointVisitor, user: ?*anyopaque) Result;

pub extern fn zozzAnimationCountTranslationKeys(animation: ?*const Animation, track: c_int, out: *c_int) Result;
pub extern fn zozzAnimationCountRotationKeys(animation: ?*const Animation, track: c_int, out: *c_int) Result;
pub extern fn zozzAnimationCountScaleKeys(animation: ?*const Animation, track: c_int, out: *c_int) Result;

pub extern fn zozzMotionBlend(layers: ?[*]const MotionBlendLayer, count: usize, out: *Transform) Result;

//=============================================================================
// Inverse kinematics
//=============================================================================

pub const IKTwoBoneJob = extern struct {
    target: [3]f32,
    mid_axis: [3]f32,
    pole_vector: [3]f32,
    twist_angle: f32,
    soften: f32,
    weight: f32,
    start_joint: *const Float4x4,
    mid_joint: *const Float4x4,
    end_joint: *const Float4x4,
    start_joint_correction: *[4]f32,
    mid_joint_correction: *[4]f32,
    reached: ?*bool,
};

pub extern fn zozzIKTwoBoneJobDefaults(out: *IKTwoBoneJob) void;
pub extern fn zozzIKTwoBoneJobRun(job: *const IKTwoBoneJob) Result;

pub const IKAimJob = extern struct {
    target: [3]f32,
    forward: [3]f32,
    offset: [3]f32,
    up: [3]f32,
    pole_vector: [3]f32,
    twist_angle: f32,
    weight: f32,
    joint: *const Float4x4,
    joint_correction: *[4]f32,
    reached: ?*bool,
};

pub extern fn zozzIKAimJobDefaults(out: *IKAimJob) void;
pub extern fn zozzIKAimJobRun(job: *const IKAimJob) Result;

pub extern fn zozzSoaPoseApplyLocalCorrection(
    pose: [*]SoaTransform,
    blocks: usize,
    joint: c_int,
    correction: *const [4]f32,
) Result;

//=============================================================================
// Skinning
//=============================================================================

pub const SkinningJob = extern struct {
    vertex_count: c_int,
    influences_count: c_int,

    joint_matrices: [*]const Float4x4,
    joint_matrices_count: usize,

    joint_inverse_transpose_matrices: ?[*]const Float4x4,
    joint_inverse_transpose_matrices_count: usize,

    joint_indices: [*]const u16,
    joint_indices_count: usize,
    joint_indices_stride: usize,

    joint_weights: ?[*]const f32,
    joint_weights_count: usize,
    joint_weights_stride: usize,

    in_positions: [*]const f32,
    in_positions_count: usize,
    in_positions_stride: usize,

    in_normals: ?[*]const f32,
    in_normals_count: usize,
    in_normals_stride: usize,

    in_tangents: ?[*]const f32,
    in_tangents_count: usize,
    in_tangents_stride: usize,

    out_positions: [*]f32,
    out_positions_count: usize,
    out_positions_stride: usize,

    out_normals: ?[*]f32,
    out_normals_count: usize,
    out_normals_stride: usize,

    out_tangents: ?[*]f32,
    out_tangents_count: usize,
    out_tangents_stride: usize,
};

pub extern fn zozzSkinningJobRun(job: *const SkinningJob) Result;

//=============================================================================
// GV4 group-varint codec (ffi/zozz_encode.h)
//=============================================================================

pub extern fn zozzEncodeGV4(values: *const [4]u32, out: [*]u8, out_capacity: usize, out_size: *usize) Result;
pub extern fn zozzDecodeGV4(buffer: [*]const u8, buffer_size: usize, out: *[4]u32, bytes_read: *usize) Result;
pub extern fn zozzComputeGV4WorstBufferSize(values_count: usize, out: *usize) Result;
pub extern fn zozzEncodeGV4Stream(values: [*]const u32, values_count: usize, out: [*]u8, out_capacity: usize, out_size: *usize) Result;
pub extern fn zozzDecodeGV4Stream(buffer: [*]const u8, buffer_size: usize, values: [*]u32, values_count: usize, bytes_read: *usize) Result;

//=============================================================================
// ozz's command-line option parser (ffi/zozz_options.h), behind -Doptions.
//=============================================================================

pub const OptionsParser = opaque {};
pub const Option = opaque {};

pub const OptionsParseResult = enum(c_int) {
    success = 0,
    exit_success = 1,
    exit_failure = 2,
};

pub extern fn zozzOptionsParserCreate(out: **OptionsParser) Result;
pub extern fn zozzOptionsParserDestroy(parser: ?*OptionsParser) void;
pub extern fn zozzOptionsParserParseCommandLine(
    parser: ?*OptionsParser,
    argc: c_int,
    argv: [*]const [*:0]const u8,
    version: ?[*:0]const u8,
    usage: ?[*:0]const u8,
    out: *OptionsParseResult,
) Result;
pub extern fn zozzOptionsParserHelp(parser: ?*OptionsParser) Result;
pub extern fn zozzOptionsParserRegister(parser: ?*OptionsParser, option: ?*Option) Result;
pub extern fn zozzOptionsParserUnregister(parser: ?*OptionsParser, option: ?*Option) Result;
pub extern fn zozzOptionsParserSetUsage(parser: ?*OptionsParser, usage: ?[*:0]const u8) Result;
pub extern fn zozzOptionsParserUsage(parser: ?*const OptionsParser) [*:0]const u8;
pub extern fn zozzOptionsParserSetVersion(parser: ?*OptionsParser, version: ?[*:0]const u8) Result;
pub extern fn zozzOptionsParserMaxOptions(parser: ?*const OptionsParser) c_int;
pub extern fn zozzOptionsParserExecutableName(parser: ?*const OptionsParser) [*:0]const u8;
pub extern fn zozzOptionsParserExecutablePath(parser: ?*const OptionsParser) [*:0]const u8;

pub extern fn zozzIntOptionCreate(name: [*:0]const u8, help: ?[*:0]const u8, default_value: i32, required: bool, out: **Option) Result;
pub extern fn zozzFloatOptionCreate(name: [*:0]const u8, help: ?[*:0]const u8, default_value: f32, required: bool, out: **Option) Result;
pub extern fn zozzBoolOptionCreate(name: [*:0]const u8, help: ?[*:0]const u8, default_value: bool, required: bool, out: **Option) Result;
pub extern fn zozzStringOptionCreate(name: [*:0]const u8, help: ?[*:0]const u8, default_value: ?[*:0]const u8, required: bool, out: **Option) Result;
pub extern fn zozzOptionDestroy(option: ?*Option) void;

pub extern fn zozzIntOptionValue(option: ?*const Option, out: *i32) Result;
pub extern fn zozzFloatOptionValue(option: ?*const Option, out: *f32) Result;
pub extern fn zozzBoolOptionValue(option: ?*const Option, out: *bool) Result;
pub extern fn zozzStringOptionValue(option: ?*const Option, out: *[*:0]const u8) Result;
pub extern fn zozzIntOptionDefault(option: ?*const Option, out: *i32) Result;
pub extern fn zozzFloatOptionDefault(option: ?*const Option, out: *f32) Result;
pub extern fn zozzBoolOptionDefault(option: ?*const Option, out: *bool) Result;
pub extern fn zozzStringOptionDefault(option: ?*const Option, out: *[*:0]const u8) Result;

pub extern fn zozzOptionName(option: ?*const Option) [*:0]const u8;
pub extern fn zozzOptionHelp(option: ?*const Option) [*:0]const u8;
pub extern fn zozzOptionRequired(option: ?*const Option) bool;
pub extern fn zozzOptionStatisfied(option: ?*const Option) bool;
pub extern fn zozzOptionRestoreDefault(option: ?*Option) Result;

//=============================================================================
// OzzImporter (ffi/zozz_gltf.h): the concrete glTF backend (-Dgltf), the
// host-implementable interface and the CLI driver (-Doptions), and the
// generic accessors that drive either one.
//=============================================================================

pub const Importer = opaque {};

pub const ImportNodeType = extern struct {
    skeleton: bool,
    marker: bool,
    camera: bool,
    geometry: bool,
    light: bool,
    null: bool,
    any: bool,
};

pub const NodePropertyType = enum(c_int) {
    float1 = 0,
    float2 = 1,
    float3 = 2,
    float4 = 3,
    point = 4,
    vector = 5,
};

pub const NodeProperty = extern struct {
    name: [*:0]const u8,
    type: NodePropertyType,
};

pub const StringVisitor = *const fn (value: [*:0]const u8, user: ?*anyopaque) callconv(.c) void;
pub const NodePropertyVisitor = *const fn (property: *const NodeProperty, user: ?*anyopaque) callconv(.c) void;

pub const ImporterInterface = extern struct {
    load: ?*const fn (user: ?*anyopaque, filename: [*:0]const u8) callconv(.c) c_int,
    import_skeleton: ?*const fn (user: ?*anyopaque, types: ImportNodeType, out: *RawSkeleton) callconv(.c) c_int,
    get_animation_names: ?*const fn (user: ?*anyopaque, visitor: StringVisitor, visitor_user: ?*anyopaque) callconv(.c) void,
    import_animation: ?*const fn (
        user: ?*anyopaque,
        animation_name: [*:0]const u8,
        skeleton: ?*const Skeleton,
        sampling_rate: f32,
        out: **RawAnimation,
    ) callconv(.c) c_int,
    get_node_properties: ?*const fn (
        user: ?*anyopaque,
        node_name: [*:0]const u8,
        visitor: NodePropertyVisitor,
        visitor_user: ?*anyopaque,
    ) callconv(.c) void,
    import_float_track: ?*const fn (
        user: ?*anyopaque,
        animation_name: [*:0]const u8,
        node_name: [*:0]const u8,
        track_name: [*:0]const u8,
        track_type: NodePropertyType,
        sampling_rate: f32,
        out: **RawFloatTrack,
    ) callconv(.c) c_int,
    import_float2_track: ?*const fn (
        user: ?*anyopaque,
        animation_name: [*:0]const u8,
        node_name: [*:0]const u8,
        track_name: [*:0]const u8,
        track_type: NodePropertyType,
        sampling_rate: f32,
        out: **RawFloat2Track,
    ) callconv(.c) c_int,
    import_float3_track: ?*const fn (
        user: ?*anyopaque,
        animation_name: [*:0]const u8,
        node_name: [*:0]const u8,
        track_name: [*:0]const u8,
        track_type: NodePropertyType,
        sampling_rate: f32,
        out: **RawFloat3Track,
    ) callconv(.c) c_int,
    import_float4_track: ?*const fn (
        user: ?*anyopaque,
        animation_name: [*:0]const u8,
        node_name: [*:0]const u8,
        track_name: [*:0]const u8,
        track_type: NodePropertyType,
        sampling_rate: f32,
        out: **RawFloat4Track,
    ) callconv(.c) c_int,
    user: ?*anyopaque,
};

pub extern fn zozzImporterCreate(interface: ?*const ImporterInterface, out: **Importer) Result;
pub extern fn zozzGltfImporterCreate(path: [*:0]const u8, out: **Importer) Result;
pub extern fn zozzImporterDestroy(importer: ?*Importer) void;
pub extern fn zozzImporterLoad(importer: ?*Importer, filename: [*:0]const u8) Result;
pub extern fn zozzImporterImportSkeleton(importer: ?*Importer, types: ImportNodeType, out: **RawSkeleton) Result;
pub extern fn zozzImporterIterateAnimationNames(importer: ?*Importer, visitor: StringVisitor, user: ?*anyopaque) Result;
pub extern fn zozzImporterImportAnimation(
    importer: ?*Importer,
    animation_name: [*:0]const u8,
    skeleton: ?*const Skeleton,
    sampling_rate: f32,
    out: **RawAnimation,
) Result;
pub extern fn zozzImporterIterateNodeProperties(
    importer: ?*Importer,
    node_name: [*:0]const u8,
    visitor: NodePropertyVisitor,
    user: ?*anyopaque,
) Result;
pub extern fn zozzImporterImportFloatTrack(
    importer: ?*Importer,
    animation_name: [*:0]const u8,
    node_name: [*:0]const u8,
    track_name: [*:0]const u8,
    track_type: NodePropertyType,
    sampling_rate: f32,
    out: **RawFloatTrack,
) Result;
pub extern fn zozzImporterImportFloat2Track(
    importer: ?*Importer,
    animation_name: [*:0]const u8,
    node_name: [*:0]const u8,
    track_name: [*:0]const u8,
    track_type: NodePropertyType,
    sampling_rate: f32,
    out: **RawFloat2Track,
) Result;
pub extern fn zozzImporterImportFloat3Track(
    importer: ?*Importer,
    animation_name: [*:0]const u8,
    node_name: [*:0]const u8,
    track_name: [*:0]const u8,
    track_type: NodePropertyType,
    sampling_rate: f32,
    out: **RawFloat3Track,
) Result;
pub extern fn zozzImporterImportFloat4Track(
    importer: ?*Importer,
    animation_name: [*:0]const u8,
    node_name: [*:0]const u8,
    track_name: [*:0]const u8,
    track_type: NodePropertyType,
    sampling_rate: f32,
    out: **RawFloat4Track,
) Result;
pub extern fn zozzImporterRun(importer: ?*Importer, argc: c_int, argv: [*]const [*:0]const u8) Result;
