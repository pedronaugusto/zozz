//! zozz — Zig bindings for the ozz-animation runtime.
//!
//! The package is a thin, allocation-transparent layer over ozz's sampling
//! pipeline. It owns no policy: no clock, no blend tree, no asset system. A
//! host drives it as `SamplingJob -> (its own blending) -> LocalToModelJob`.
//!
//! ```zig
//! try zozz.setAllocator(gpa);
//! defer zozz.resetAllocator();
//!
//! const skeleton = try zozz.Skeleton.initFromFile("skeleton.ozz");
//! defer skeleton.deinit();
//! const clip = try zozz.Animation.initFromFile("walk.ozz");
//! defer clip.deinit();
//!
//! const pose = try zozz.SoaPose.initForSkeleton(skeleton);
//! defer pose.deinit();
//! var context = try zozz.SamplingContext.initForSkeleton(skeleton);
//! defer context.deinit();
//!
//! try pose.setRestPose(skeleton);
//! try (zozz.SamplingJob{
//!     .animation = clip,
//!     .context = context,
//!     .ratio = clip.ratioAt(time_seconds),
//!     .out = pose,
//! }).run();
//! try pose.toLocalTransforms(locals);
//! ```

const std = @import("std");

pub const c = @import("c.zig");

const error_mod = @import("error.zig");
const math_mod = @import("math.zig");
const memory_mod = @import("memory.zig");
const skeleton_mod = @import("skeleton.zig");
const animation_mod = @import("animation.zig");
const pose_mod = @import("pose.zig");
const sampling_mod = @import("sampling.zig");
const offline_mod = @import("offline.zig");
const track_mod = @import("track.zig");
const utils_mod = @import("utils.zig");
const motion_mod = @import("motion.zig");
const blending_mod = @import("blending.zig");
const archive_mod = @import("archive.zig");
const ik_mod = @import("ik.zig");
const skinning_mod = @import("skinning.zig");
const optimizer_mod = @import("optimizer.zig");
const rawtrack_mod = @import("rawtrack.zig");

//=============================================================================
// Public surface
//=============================================================================

pub const Error = error_mod.Error;
pub const resultName = error_mod.name;

pub const Transform = math_mod.Transform;
pub const Mat4 = math_mod.Mat4;
pub const transform_identity = math_mod.transform_identity;
pub const mat4_identity = math_mod.mat4_identity;

pub const setAllocator = memory_mod.setAllocator;
pub const resetAllocator = memory_mod.resetAllocator;

pub const Skeleton = skeleton_mod.Skeleton;
pub const no_parent = skeleton_mod.no_parent;

pub const Animation = animation_mod.Animation;

pub const SoaPose = pose_mod.SoaPose;

pub const SamplingContext = sampling_mod.SamplingContext;
pub const SamplingJob = sampling_mod.SamplingJob;
pub const LocalToModelJob = sampling_mod.LocalToModelJob;

pub const RawSkeleton = offline_mod.RawSkeleton;
pub const RawAnimation = offline_mod.RawAnimation;
pub const ModelSpaceSample = offline_mod.ModelSpaceSample;

pub const FloatTrack = track_mod.FloatTrack;
pub const Float2Track = track_mod.Float2Track;
pub const Float3Track = track_mod.Float3Track;
pub const Float4Track = track_mod.Float4Track;
pub const QuaternionTrack = track_mod.QuaternionTrack;
pub const TrackEdge = track_mod.TrackEdge;
pub const TrackTriggering = track_mod.TrackTriggering;
pub const jointRestPoseLocal = utils_mod.jointRestPoseLocal;
pub const restPoseModelSpace = utils_mod.restPoseModelSpace;
pub const jointIsLeaf = utils_mod.jointIsLeaf;
pub const findJoint = utils_mod.findJoint;
pub const iterateJointsDepthFirst = utils_mod.iterateJointsDepthFirst;
pub const iterateJointsDepthFirstReverse = utils_mod.iterateJointsDepthFirstReverse;
pub const TrackSelector = utils_mod.TrackSelector;
pub const countTranslationKeys = utils_mod.countTranslationKeys;
pub const countRotationKeys = utils_mod.countRotationKeys;
pub const countScaleKeys = utils_mod.countScaleKeys;

pub const BlendLayer = motion_mod.BlendLayer;
pub const MotionBlendingJob = motion_mod.MotionBlendingJob;

pub const SoaWeights = blending_mod.SoaWeights;
pub const BlendingLayer = blending_mod.Layer;
pub const BlendingJob = blending_mod.BlendingJob;

pub const Stream = archive_mod.Stream;
pub const OArchive = archive_mod.OArchive;
pub const saveSkeletonToFile = archive_mod.saveSkeletonToFile;
pub const saveAnimationToFile = archive_mod.saveAnimationToFile;
pub const saveFloatTrackToFile = archive_mod.saveFloatTrackToFile;
pub const saveFloat2TrackToFile = archive_mod.saveFloat2TrackToFile;
pub const saveFloat3TrackToFile = archive_mod.saveFloat3TrackToFile;
pub const saveFloat4TrackToFile = archive_mod.saveFloat4TrackToFile;
pub const saveQuaternionTrackToFile = archive_mod.saveQuaternionTrackToFile;
pub const ik = ik_mod;
pub const skinning = skinning_mod;
pub const AnimationOptimizer = optimizer_mod.AnimationOptimizer;
pub const OptimizerSetting = optimizer_mod.OptimizerSetting;
pub const FixedRateSamplingTime = optimizer_mod.FixedRateSamplingTime;
pub const AdditiveAnimationBuilder = optimizer_mod.AdditiveAnimationBuilder;
pub const MotionExtractor = optimizer_mod.MotionExtractor;
pub const MotionReference = optimizer_mod.MotionReference;
pub const MotionSettings = optimizer_mod.MotionSettings;

pub const TrackInterpolation = rawtrack_mod.Interpolation;
pub const RawFloatTrack = rawtrack_mod.RawFloatTrack;
pub const RawFloat2Track = rawtrack_mod.RawFloat2Track;
pub const RawFloat3Track = rawtrack_mod.RawFloat3Track;
pub const RawFloat4Track = rawtrack_mod.RawFloat4Track;
pub const RawQuaternionTrack = rawtrack_mod.RawQuaternionTrack;
// The runtime track types are re-exported from track.zig above; rawtrack.zig
// names them too, for the builders that produce them.

/// Build options the C library was actually compiled with, so a consumer can
/// branch on them instead of assuming.
pub const options = @import("zozz_options");

//=============================================================================
// Versions
//=============================================================================

pub const Version = struct {
    major: u8,
    minor: u8,
    patch: u8,

    fn unpack(packed_value: u32) Version {
        return .{
            .major = @truncate(packed_value >> 16),
            .minor = @truncate(packed_value >> 8),
            .patch = @truncate(packed_value),
        };
    }

    pub fn format(self: Version, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("{d}.{d}.{d}", .{ self.major, self.minor, self.patch });
    }
};

/// Version of these bindings.
pub fn version() Version {
    return Version.unpack(c.zozzVersion());
}

/// Version of the vendored ozz-animation runtime.
pub fn ozzVersion() Version {
    return Version.unpack(c.zozzOzzVersion());
}

//=============================================================================
// Tests
//=============================================================================

test {
    // Pull every module in so its own tests are discovered and run.
    _ = error_mod;
    _ = math_mod;
    _ = memory_mod;
    _ = skeleton_mod;
    _ = animation_mod;
    _ = pose_mod;
    _ = sampling_mod;
    _ = track_mod;
    _ = utils_mod;
    _ = motion_mod;
    _ = blending_mod;
    _ = archive_mod;
    _ = ik_mod;
    _ = skinning_mod;

    // ik.zig and skinning.zig have no test blocks of their own, and nothing
    // above calls into them the way the other modules' functions get
    // exercised by the tests below. A function that nothing calls or takes
    // the address of is never analysed, pulled-in module or not — so without
    // this, a real error in one of these bodies would compile clean.
    comptime {
        _ = &ik_mod.TwoBoneJob.run;
        _ = &ik_mod.AimJob.run;
        _ = &ik_mod.applyCorrection;
        _ = &skinning_mod.Job.run;
    }

    // Only reachable in a test build, where the fixture library is linked.
    _ = @import("integration_test.zig");
    _ = @import("offline.zig");
    _ = @import("optimizer.zig");
    _ = @import("rawtrack.zig");

    // Behavioural tests, one file per area.
    _ = @import("blending_test.zig");
    _ = @import("ik_test.zig");
    _ = @import("archive_test.zig");
    _ = @import("track_test.zig");
    _ = @import("utils_test.zig");
    _ = @import("skinning_test.zig");
    _ = @import("optimizer_test.zig");
    _ = @import("motion_test.zig");

    // Test-only: this one @cImport-s the C header. Reached from a test block
    // and nowhere else, so a normal build never analyses it and the shipped
    // module stays translate-c-free.
    _ = @import("abi_check.zig");
}

test "the C library agrees with the extern declarations in c.zig" {
    // What abi_check.zig cannot see, and the reason both checks exist.
    //
    // abi_check.zig compares c.zig against ffi/zozz.h — two SOURCE files, as
    // this build's preprocessor renders them. It says nothing about the
    // library actually linked here, which is a binary that was compiled at
    // some other time, possibly from a different header. This test asks the
    // compiled translation unit what it really laid out, and compares that.
    // Neither check replaces the other: one guards header-vs-declarations,
    // this one guards library-vs-declarations.
    var layout: c.AbiLayout = undefined;
    c.zozzAbiLayout(&layout);

    try std.testing.expectEqual(@as(u32, @sizeOf(c.AbiLayout)), layout.layout_size);

    try std.testing.expectEqual(@as(u32, @sizeOf(c.Transform)), layout.transform_size);
    try std.testing.expectEqual(@as(u32, @alignOf(c.Transform)), layout.transform_align);
    try std.testing.expectEqual(
        @as(u32, @offsetOf(c.Transform, "translation")),
        layout.transform_offset_translation,
    );
    try std.testing.expectEqual(
        @as(u32, @offsetOf(c.Transform, "rotation")),
        layout.transform_offset_rotation,
    );
    try std.testing.expectEqual(
        @as(u32, @offsetOf(c.Transform, "scale")),
        layout.transform_offset_scale,
    );

    try std.testing.expectEqual(@as(u32, @sizeOf(c.Float4x4)), layout.float4x4_size);
    try std.testing.expectEqual(@as(u32, @alignOf(c.Float4x4)), layout.float4x4_align);
    try std.testing.expectEqual(@as(u32, 16), layout.float4x4_align);

    try std.testing.expectEqual(@as(u32, @sizeOf(c.Allocator)), layout.allocator_size);
    try std.testing.expectEqual(@as(u32, @alignOf(c.Allocator)), layout.allocator_align);
    try std.testing.expectEqual(
        @as(u32, @offsetOf(c.Allocator, "allocate")),
        layout.allocator_offset_allocate,
    );
    try std.testing.expectEqual(
        @as(u32, @offsetOf(c.Allocator, "deallocate")),
        layout.allocator_offset_deallocate,
    );
    try std.testing.expectEqual(
        @as(u32, @offsetOf(c.Allocator, "user")),
        layout.allocator_offset_user,
    );

    // The Zig error mapping must cover every C result.
    const result_fields = @typeInfo(c.Result).@"enum".fields;
    try std.testing.expectEqual(@as(u32, result_fields.len), layout.result_count);
}

test "version reporting is wired up" {
    const v = version();
    try std.testing.expectEqual(@as(u8, 0), v.major);
    try std.testing.expectEqual(@as(u8, 3), v.minor);

    const ozz = ozzVersion();
    try std.testing.expectEqual(@as(u8, 17), ozz.minor);
}

test "result names are never null" {
    inline for (@typeInfo(c.Result).@"enum".fields) |field| {
        const name = resultName(@enumFromInt(field.value));
        try std.testing.expect(name.len > 0);
    }
}

test "loaders reject malformed input instead of parsing it" {
    const gpa = std.testing.allocator;
    try setAllocator(gpa);
    defer resetAllocator();

    // Not an ozz archive: the tag test must catch it.
    const garbage = "this is definitely not an ozz archive" ** 4;
    try std.testing.expectError(Error.BadFormat, Skeleton.initFromMemory(garbage));
    try std.testing.expectError(Error.BadFormat, Animation.initFromMemory(garbage));

    // Empty and absent inputs.
    try std.testing.expectError(Error.InvalidArgument, Skeleton.initFromMemory(""));
    try std.testing.expectError(
        Error.FileNotFound,
        Skeleton.initFromFile("/nonexistent/zozz/skeleton.ozz"),
    );
}

test "a pose round-trips through AoS without drifting" {
    const gpa = std.testing.allocator;
    try setAllocator(gpa);
    defer resetAllocator();

    // 7 joints exercises a partial trailing SoA block (4 + 3).
    const joint_count = 7;
    const pose = try SoaPose.init(joint_count);
    defer pose.deinit();

    var written: [joint_count]Transform = undefined;
    for (&written, 0..) |*t, i| {
        const f: f32 = @floatFromInt(i + 1);
        t.* = .{
            .translation = .{ f, f * 2, f * 3 },
            // A normalised, non-identity quaternion: rotation about X by an
            // angle that varies per joint.
            .rotation = blk: {
                const angle = f * 0.2;
                break :blk .{ @sin(angle), 0, 0, @cos(angle) };
            },
            .scale = .{ f * 0.5, f * 0.25, f },
        };
    }

    try pose.fromLocalTransforms(&written);

    var read_back: [joint_count]Transform = undefined;
    try pose.toLocalTransforms(&read_back);

    for (written, read_back) |expected, actual| {
        for (expected.translation, actual.translation) |e, a| {
            try std.testing.expectApproxEqAbs(e, a, 1e-6);
        }
        for (expected.rotation, actual.rotation) |e, a| {
            try std.testing.expectApproxEqAbs(e, a, 1e-6);
        }
        for (expected.scale, actual.scale) |e, a| {
            try std.testing.expectApproxEqAbs(e, a, 1e-6);
        }
    }
}

test "buffer size and joint count mismatches are refused" {
    const gpa = std.testing.allocator;
    try setAllocator(gpa);
    defer resetAllocator();

    const pose = try SoaPose.init(8);
    defer pose.deinit();

    var too_small: [4]Transform = undefined;
    try std.testing.expectError(Error.BufferTooSmall, pose.toLocalTransforms(&too_small));
    try std.testing.expectError(Error.BufferTooSmall, pose.fromLocalTransforms(&too_small));

    try std.testing.expectError(Error.InvalidArgument, SoaPose.init(0));
}
