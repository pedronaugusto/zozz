//! zozz — Zig bindings for the ozz-animation runtime.
//!
//! The package is a thin, allocation-transparent layer over ozz's sampling
//! pipeline. It owns no policy: no clock, no blend tree, no asset system. A
//! host drives it as `SamplingJob -> (its own blending) -> LocalToModelJob`;
//! see `integration_test.zig` for a complete load -> sample -> convert example.

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
const encode_mod = @import("encode.zig");
const optimizer_mod = @import("optimizer.zig");
const rawtrack_mod = @import("rawtrack.zig");
const options_mod = @import("options.zig");
const importer_mod = @import("importer.zig");

//=============================================================================
// Public surface
//=============================================================================

pub const Error = error_mod.Error;
pub const resultName = error_mod.name;

pub const Transform = math_mod.Transform;
pub const Mat4 = math_mod.Mat4;
pub const SoaTransform = math_mod.SoaTransform;
pub const transform_identity = math_mod.transform_identity;
pub const mat4_identity = math_mod.mat4_identity;

/// ozz::math: SimdFloat4/SimdInt4 lane ops, vector ops, quaternions, 4x4
/// matrix operations, and Box — the operations that go with `Transform` and
/// `Mat4` above.
pub const math = math_mod;

pub const setAllocator = memory_mod.setAllocator;
pub const resetAllocator = memory_mod.resetAllocator;
pub const getAllocator = memory_mod.getAllocator;
pub const allocatorLiveBlocks = memory_mod.liveBlocks;

pub const Skeleton = skeleton_mod.Skeleton;
pub const no_parent = skeleton_mod.no_parent;
pub const max_joints = skeleton_mod.max_joints;

pub const Animation = animation_mod.Animation;

/// Operations over a caller-owned SoA pose: `soaBlocks` to size the array,
/// identity, the AoS conversions, and the per-joint weight packer. The pose
/// itself is a `[]SoaTransform` the caller owns.
pub const pose = pose_mod;
pub const soaBlocks = pose_mod.soaBlocks;

pub const SamplingContext = sampling_mod.SamplingContext;
pub const SamplingJob = sampling_mod.SamplingJob;
pub const LocalToModelJob = sampling_mod.LocalToModelJob;

pub const RawSkeleton = offline_mod.RawSkeleton;
pub const RawAnimation = offline_mod.RawAnimation;
pub const ModelSpaceSample = offline_mod.ModelSpaceSample;
pub const TranslationKey = offline_mod.TranslationKey;
pub const RotationKey = offline_mod.RotationKey;
pub const ScaleKey = offline_mod.ScaleKey;

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

/// Blending: `layer` and `maskedLayer` build a `BlendingLayer`, and
/// `default_threshold` is ozz's own.
pub const blending = blending_mod;
pub const BlendingLayer = blending_mod.Layer;
pub const BlendingJob = blending_mod.BlendingJob;

pub const Stream = archive_mod.Stream;
pub const SeekOrigin = archive_mod.SeekOrigin;
pub const Endianness = archive_mod.Endianness;
pub const nativeEndianness = archive_mod.nativeEndianness;
pub const OArchive = archive_mod.OArchive;
pub const IArchive = archive_mod.IArchive;
pub const saveSkeletonToFile = archive_mod.saveSkeletonToFile;
pub const saveAnimationToFile = archive_mod.saveAnimationToFile;
pub const saveFloatTrackToFile = archive_mod.saveFloatTrackToFile;
pub const saveFloat2TrackToFile = archive_mod.saveFloat2TrackToFile;
pub const saveFloat3TrackToFile = archive_mod.saveFloat3TrackToFile;
pub const saveFloat4TrackToFile = archive_mod.saveFloat4TrackToFile;
pub const saveQuaternionTrackToFile = archive_mod.saveQuaternionTrackToFile;
pub const saveRawSkeletonToFile = archive_mod.saveRawSkeletonToFile;
pub const saveRawAnimationToFile = archive_mod.saveRawAnimationToFile;
pub const saveRawFloatTrackToFile = archive_mod.saveRawFloatTrackToFile;
pub const saveRawFloat2TrackToFile = archive_mod.saveRawFloat2TrackToFile;
pub const saveRawFloat3TrackToFile = archive_mod.saveRawFloat3TrackToFile;
pub const saveRawFloat4TrackToFile = archive_mod.saveRawFloat4TrackToFile;
pub const saveRawQuaternionTrackToFile = archive_mod.saveRawQuaternionTrackToFile;
pub const ik = ik_mod;
pub const skinning = skinning_mod;

/// GV4 group-varint codec (ffi/zozz_encode.h) -- the wire format
/// `zozzAnimationKeyframeIframeEntries`'s buffer is encoded with.
pub const encode = encode_mod;
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
pub const FloatKeyframe = rawtrack_mod.FloatKeyframe;
pub const Float2Keyframe = rawtrack_mod.Float2Keyframe;
pub const Float3Keyframe = rawtrack_mod.Float3Keyframe;
pub const Float4Keyframe = rawtrack_mod.Float4Keyframe;
pub const QuaternionKeyframe = rawtrack_mod.QuaternionKeyframe;
// The runtime track types are re-exported from track.zig above; rawtrack.zig
// names them too, for the builders that produce them.

/// ozz's command-line option parser (ffi/zozz_options.h), behind
/// `-Doptions`. See options.zig's module comment.
pub const OptionsParser = options_mod.OptionsParser;
pub const OptionsParseResult = options_mod.ParseResult;
pub const IntOption = options_mod.IntOption;
pub const FloatOption = options_mod.FloatOption;
pub const BoolOption = options_mod.BoolOption;
pub const StringOption = options_mod.StringOption;

/// OzzImporter (ffi/zozz_gltf.h): the concrete glTF backend (-Dgltf), the
/// host-implementable interface and CLI driver (-Doptions). See importer.zig's
/// module comment.
pub const Importer = importer_mod.Importer;
pub const ImporterInterface = importer_mod.ImporterInterface;
pub const ImportNodeType = importer_mod.ImportNodeType;
pub const NodePropertyType = importer_mod.NodePropertyType;
pub const NodeProperty = importer_mod.NodeProperty;

/// The build options THIS build graph was configured with. Available at
/// comptime, which is what a consumer wants for `if (zozz.options.gltf)`.
/// Only meaningful for a zozz built from source in the same graph — a
/// prebuilt library is described by `buildFeatures()` below, and the test
/// "the build options and the compiled library agree" holds the two together.
pub const options = @import("zozz_options");

/// What the LINKED library was compiled with, asked of the library itself.
/// The entry points behind an option that is off answer `error.Unsupported`,
/// and that error alone cannot say whether the feature is absent from this
/// build or the call failed: check this once at start-up instead.
pub fn buildFeatures() c.BuildFeatures {
    var features: c.BuildFeatures = undefined;
    c.zozzBuildFeatures(&features);
    return features;
}

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
// Log verbosity
//=============================================================================

pub const LogLevel = c.LogLevel;

/// Sets ozz's global logging verbosity — process-wide, like the allocator
/// seam. Silencing it is the only lever offered: ozz's diagnostic streams
/// cannot cross this boundary (see zozz_core.h), so there is no way to
/// redirect them, only to turn them down.
pub fn setLogLevel(level: LogLevel) Error!void {
    try error_mod.check(c.zozzSetLogLevel(level));
}

/// Reads back ozz's current logging verbosity. Never fails: there is always
/// a current level, `.standard` until something changes it.
pub fn logLevel() LogLevel {
    return c.zozzGetLogLevel();
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
    _ = encode_mod;

    // ik.zig and skinning.zig have no test blocks of their own, and nothing
    // above calls into them the way the other modules' functions get
    // exercised by the tests below. A function that nothing calls or takes
    // the address of is never analysed, pulled-in module or not — so without
    // this, a real error in one of these bodies would compile clean.
    comptime {
        _ = &ik_mod.TwoBoneJob.run;
        _ = &ik_mod.AimJob.run;
        _ = &ik_mod.applyCorrection;
        _ = &ik_mod.applyCorrections;
        _ = &ik_mod.correction;
        _ = &skinning_mod.Job.run;
    }

    // Only reachable in a test build, where the fixture library is linked.
    _ = @import("integration_test.zig");
    _ = @import("offline.zig");
    _ = @import("optimizer.zig");
    _ = @import("rawtrack.zig");
    _ = @import("log_test.zig");

    // Behavioural tests, one file per area.
    _ = @import("math_test.zig");
    _ = @import("mathref_test.zig");
    _ = @import("sampling_test.zig");
    _ = @import("blending_test.zig");
    _ = @import("ik_test.zig");
    _ = @import("archive_test.zig");
    _ = @import("track_test.zig");
    _ = @import("utils_test.zig");
    _ = @import("skinning_test.zig");
    _ = @import("optimizer_test.zig");
    _ = @import("motion_test.zig");
    _ = @import("encode_test.zig");
    _ = @import("options_test.zig");
    _ = @import("gltf_test.zig");
    _ = @import("concurrency_test.zig");

    // Test-only: this one @cImport-s the C header. Reached from a test block
    // and nowhere else, so a normal build never analyses it and the shipped
    // module stays translate-c-free.
    _ = @import("abi_check.zig");
}

/// The type each `ZozzAbiLayout` field group describes. A field whose name
/// matches no prefix here, or that is neither a size, an alignment nor an
/// offset, fails to compile in `abiLayoutExpected` below.
const abi_layout_types = .{
    .{ "transform", c.Transform },
    .{ "float4x4", c.Float4x4 },
    .{ "simd_float4", c.SimdFloat4 },
    .{ "soa_transform", c.SoaTransform },
    .{ "blending_layer", c.BlendingLayer },
    .{ "track_triggering", c.TrackTriggeringIterator },
    .{ "allocator", c.Allocator },
};

/// What one `ZozzAbiLayout` field must hold, derived from its own name:
/// `<type>_size`, `<type>_align` or `<type>_offset_<member>`.
fn abiLayoutExpected(comptime field: []const u8) u32 {
    @setEvalBranchQuota(4000);
    inline for (abi_layout_types) |entry| {
        const prefix = entry[0] ++ "_";
        if (comptime std.mem.startsWith(u8, field, prefix)) {
            const T = entry[1];
            const rest = field[prefix.len..];
            if (comptime std.mem.eql(u8, rest, "size")) return @sizeOf(T);
            if (comptime std.mem.eql(u8, rest, "align")) return @alignOf(T);
            if (comptime std.mem.startsWith(u8, rest, "offset_")) {
                return @offsetOf(T, rest["offset_".len..]);
            }
            @compileError("ZozzAbiLayout." ++ field ++
                " is neither a size, an alignment nor an offset");
        }
    }
    @compileError("ZozzAbiLayout." ++ field ++ " describes no type in abi_layout_types");
}

test "the C library agrees with the extern declarations in c.zig" {
    // What abi_check.zig cannot see, and why both checks exist: abi_check.zig
    // compares c.zig against ffi/zozz.h -- two SOURCE files -- saying nothing
    // about the library actually linked, a binary compiled at some other time,
    // possibly from a different header. This test asks the compiled translation
    // unit what it really laid out. Neither check replaces the other: one
    // guards header-vs-declarations, this one guards library-vs-declarations.
    var layout: c.AbiLayout = undefined;
    c.zozzAbiLayout(&layout);

    try std.testing.expectEqual(@as(u32, @sizeOf(c.AbiLayout)), layout.layout_size);

    // Every remaining field is checked, by its own name, against the type it
    // describes -- not against a hand-written list that a new field can be
    // added beside without anyone noticing.
    inline for (@typeInfo(c.AbiLayout).@"struct".fields) |field| {
        if (comptime std.mem.eql(u8, field.name, "layout_size")) continue;
        if (comptime std.mem.eql(u8, field.name, "result_count")) continue;
        try std.testing.expectEqual(
            comptime abiLayoutExpected(field.name),
            @field(layout, field.name),
        );
    }

    // Two alignments ozz depends on, stated rather than merely agreed on: the
    // SIMD types are loaded and stored with aligned instructions.
    try std.testing.expectEqual(@as(u32, 16), layout.float4x4_align);
    try std.testing.expectEqual(@as(u32, 16), layout.soa_transform_align);

    // The Zig error mapping must cover every C result.
    const result_fields = @typeInfo(c.Result).@"enum".fields;
    try std.testing.expectEqual(@as(u32, result_fields.len), layout.result_count);
}

test "the build options and the compiled library agree" {
    // Two homes for the same fact, unavoidably: build.zig adds a C macro for
    // each option AND mirrors it into the `zozz_options` module. Nothing made
    // them agree, so defining one and forgetting the other compiled cleanly
    // and left `zozz.options.gltf` true over a library with no glTF backend.
    const features = buildFeatures();
    try std.testing.expectEqual(@as(u32, @sizeOf(c.BuildFeatures)), features.features_size);
    try std.testing.expectEqual(options.options, features.options);
    try std.testing.expectEqual(options.gltf, features.gltf);
    try std.testing.expectEqual(options.enable_asserts, features.asserts);
}

test "version reporting is wired up" {
    const v = version();
    try std.testing.expectEqual(@as(u8, 0), v.major);
    try std.testing.expectEqual(@as(u8, 4), v.minor);

    const ozz = ozzVersion();
    try std.testing.expectEqual(@as(u8, 17), ozz.minor);
}

test "result names are never null" {
    inline for (@typeInfo(c.Result).@"enum".fields) |field| {
        const name = resultName(@enumFromInt(field.value));
        try std.testing.expect(name.len > 0);
    }
}

test "a handle destroyed twice is freed once" {
    const gpa = std.testing.allocator;
    try setAllocator(gpa);
    defer resetAllocator() catch unreachable;

    // `deinit` takes a pointer and nulls the handle, so the second call has
    // nothing to free. Under the testing allocator a second free is a failure
    // rather than an opinion, and the live-block count says the first one
    // happened at all.
    var context = try SamplingContext.init(8);
    try std.testing.expect(allocatorLiveBlocks() > 0);
    context.deinit();
    try std.testing.expectEqual(@as(usize, 0), allocatorLiveBlocks());
    context.deinit();
    try std.testing.expectEqual(@as(usize, 0), allocatorLiveBlocks());
    try std.testing.expect(context.handle == null);
}

test "loaders reject malformed input instead of parsing it" {
    const gpa = std.testing.allocator;
    try setAllocator(gpa);
    defer resetAllocator() catch unreachable;

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
    defer resetAllocator() catch unreachable;

    // 7 joints exercises a partial trailing SoA block (4 + 3).
    const joint_count = 7;
    var blocks: [2]SoaTransform = undefined;
    try std.testing.expectEqual(blocks.len, try soaBlocks(joint_count));
    try pose.setIdentity(&blocks);

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

    try pose.fromLocalTransforms(&written, &blocks);

    var read_back: [joint_count]Transform = undefined;
    try pose.toLocalTransforms(&blocks, &read_back);

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
    defer resetAllocator() catch unreachable;

    // One block holds four joints; eight transforms do not fit in it.
    var one_block: [1]SoaTransform = undefined;
    var eight: [8]Transform = undefined;
    try std.testing.expectError(Error.BufferTooSmall, pose.toLocalTransforms(&one_block, &eight));
    try std.testing.expectError(Error.BufferTooSmall, pose.fromLocalTransforms(&eight, &one_block));

    try std.testing.expectError(Error.InvalidArgument, soaBlocks(0));
    try std.testing.expectError(Error.InvalidArgument, soaBlocks(@as(u32, @intCast(max_joints)) + 1));
}
