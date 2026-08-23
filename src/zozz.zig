//! zozz — Zig bindings for the ozz-animation runtime.
//!
//! The package is a thin, allocation-transparent layer over ozz's sampling
//! pipeline. It owns no policy: no clock, no blend tree, no asset system. A
//! host drives it as `sample -> (its own blending) -> localToModel`.
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
//! try zozz.sample(clip, context, clip.ratioAt(time_seconds), pose);
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
pub const sample = sampling_mod.sample;
pub const localToModel = sampling_mod.localToModel;

pub const RawSkeleton = offline_mod.RawSkeleton;
pub const RawAnimation = offline_mod.RawAnimation;

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
    // Only reachable in a test build, where the fixture library is linked.
    _ = @import("integration_test.zig");
    _ = @import("offline.zig");
}

test "the C library agrees with the extern declarations in c.zig" {
    // This is the guard that makes hand-written externs safe. Every field the
    // Zig side believes in is checked against what the C++ translation unit
    // compiled to. A reordered field fails here rather than in production.
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
    try std.testing.expectEqual(@as(u8, 1), v.minor);

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
