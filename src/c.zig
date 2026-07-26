//! Hand-written declarations mirroring `ffi/zozz.h`.
//!
//! These are written by hand rather than produced by `@cImport` so the package
//! stays translate-c-free and every type is exactly the shape the rest of the
//! wrapper wants. The cost of hand-writing is drift: nothing in either
//! compiler checks that this file still agrees with the header. That gap is
//! closed by `zozzAbiLayout`, asserted in the test at the bottom of
//! `zozz.zig` — if a field moves on either side, the test fails loudly instead
//! of corrupting memory quietly.

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
// Opaque handles
//=============================================================================

pub const Skeleton = opaque {};
pub const Animation = opaque {};
pub const SamplingContext = opaque {};
pub const SoaPose = opaque {};

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
