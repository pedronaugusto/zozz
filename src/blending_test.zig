//! Behavioural tests for pose blending (ozz::animation::BlendingJob): the
//! normal weighted blend, additive layers, and per-joint partial blending
//! through a packed SoA weight mask.
//!
//! Fixtures are built directly in code — plain arrays of `Transform` fed
//! through `pose.fromLocalTransforms` — so nothing here depends on a
//! skeleton or an asset file. Every pose is a stack array, which is what the
//! caller-owned SoA span makes possible.

const std = @import("std");
const zozz = @import("zozz.zig");

/// SoA blocks for `n` joints, at comptime, so a fixture can be a fixed-size
/// array. The test below pins it against the library's own answer.
fn blocks(comptime n: u32) u32 {
    return (n + 3) / 4;
}

fn poseOf(comptime n: u32, transforms: []const zozz.Transform) ![blocks(n)]zozz.SoaTransform {
    var out: [blocks(n)]zozz.SoaTransform = undefined;
    try zozz.pose.fromLocalTransforms(transforms, &out);
    return out;
}

fn identityPose(comptime n: u32) ![blocks(n)]zozz.SoaTransform {
    var out: [blocks(n)]zozz.SoaTransform = undefined;
    try zozz.pose.setIdentity(&out);
    return out;
}

fn translated(x: f32) zozz.Transform {
    var t = zozz.transform_identity;
    t.translation[0] = x;
    return t;
}

test "the comptime block count matches the library's" {
    inline for ([_]u32{ 1, 3, 4, 5, 8, 1024 }) |n| {
        try std.testing.expectEqual(@as(usize, blocks(n)), try zozz.soaBlocks(n));
    }
}

test "two layers blended at 0.5 land between them, per joint" {
    try zozz.setAllocator(std.testing.allocator);
    defer zozz.resetAllocator();

    const n = 5; // crosses the 4-wide SoA block boundary.
    var a_t: [n]zozz.Transform = undefined;
    var b_t: [n]zozz.Transform = undefined;
    for (0..n) |i| {
        const f: f32 = @floatFromInt(i);
        a_t[i] = translated(f);
        b_t[i] = translated(f + 10);
    }
    const pose_a = try poseOf(n, &a_t);
    const pose_b = try poseOf(n, &b_t);
    const rest = try identityPose(n);
    var out = try identityPose(n);

    try (zozz.BlendingJob{
        .layers = &.{
            zozz.blending.layer(0.5, &pose_a),
            zozz.blending.layer(0.5, &pose_b),
        },
        .rest_pose = &rest,
        .out = &out,
    }).run();

    var result: [n]zozz.Transform = undefined;
    try zozz.pose.toLocalTransforms(&out, &result);
    for (0..n) |i| {
        const f: f32 = @floatFromInt(i);
        try std.testing.expectApproxEqAbs(f + 5, result[i].translation[0], 1e-4);
    }
}

test "weight 0 on a layer yields exactly the other layer" {
    try zozz.setAllocator(std.testing.allocator);
    defer zozz.resetAllocator();

    const n = 4;
    var a_t: [n]zozz.Transform = undefined;
    var b_t: [n]zozz.Transform = undefined;
    for (0..n) |i| {
        const f: f32 = @floatFromInt(i + 1);
        a_t[i] = .{
            .translation = .{ f, f * 2, f * 3 },
            .rotation = blk: {
                const angle = f * 0.3;
                break :blk .{ @sin(angle), 0, 0, @cos(angle) };
            },
            .scale = .{ 1, 1, 1 },
        };
        b_t[i] = .{
            .translation = .{ -f, f * 5, 0 },
            .rotation = .{ 0, 0, 0, 1 },
            .scale = .{ 2, 2, 2 },
        };
    }
    const pose_a = try poseOf(n, &a_t);
    const pose_b = try poseOf(n, &b_t);
    const rest = try identityPose(n);
    var out = try identityPose(n);

    try (zozz.BlendingJob{
        .layers = &.{
            zozz.blending.layer(1, &pose_a),
            zozz.blending.layer(0, &pose_b),
        },
        .rest_pose = &rest,
        .out = &out,
    }).run();

    var result: [n]zozz.Transform = undefined;
    try zozz.pose.toLocalTransforms(&out, &result);
    for (a_t, result) |expected, actual| {
        for (expected.translation, actual.translation) |e, a| {
            try std.testing.expectApproxEqAbs(e, a, 1e-4);
        }
        for (expected.rotation, actual.rotation) |e, a| {
            try std.testing.expectApproxEqAbs(e, a, 1e-4);
        }
        for (expected.scale, actual.scale) |e, a| {
            try std.testing.expectApproxEqAbs(e, a, 1e-4);
        }
    }
}

test "an additive layer at weight 0 changes nothing, and at weight 1 applies fully" {
    try zozz.setAllocator(std.testing.allocator);
    defer zozz.resetAllocator();

    const n = 4;
    const base_transform: zozz.Transform = .{
        .translation = .{ 1, 2, 3 },
        .rotation = .{ 0, 0, 0, 1 },
        .scale = .{ 1, 1, 1 },
    };
    const base = [_]zozz.Transform{base_transform} ** n;
    const rest = try poseOf(n, &base);

    // A delta pose: translate, a 90-degree turn about Z, and double scale.
    const half_angle: f32 = std.math.pi / 4.0;
    const delta_transform: zozz.Transform = .{
        .translation = .{ 5, 0, 0 },
        .rotation = .{ 0, 0, @sin(half_angle), @cos(half_angle) },
        .scale = .{ 2, 2, 2 },
    };
    const delta = [_]zozz.Transform{delta_transform} ** n;
    const delta_pose = try poseOf(n, &delta);

    var out = try identityPose(n);

    // Empty `layers`: every joint's accumulated weight is 0, below any
    // positive threshold, so the base comes from `rest_pose` alone — the
    // documented fallback, used here to isolate the additive pass.
    try (zozz.BlendingJob{
        .layers = &.{},
        .additive_layers = &.{zozz.blending.layer(0, &delta_pose)},
        .rest_pose = &rest,
        .out = &out,
    }).run();
    var result: [n]zozz.Transform = undefined;
    try zozz.pose.toLocalTransforms(&out, &result);
    for (result) |t| {
        try std.testing.expectApproxEqAbs(@as(f32, 1), t.translation[0], 1e-4);
        try std.testing.expectApproxEqAbs(@as(f32, 2), t.translation[1], 1e-4);
        try std.testing.expectApproxEqAbs(@as(f32, 3), t.translation[2], 1e-4);
        try std.testing.expectApproxEqAbs(@as(f32, 1), t.scale[0], 1e-4);
        try std.testing.expectApproxEqAbs(@as(f32, 1), t.rotation[3], 1e-4);
    }

    try (zozz.BlendingJob{
        .layers = &.{},
        .additive_layers = &.{zozz.blending.layer(1, &delta_pose)},
        .rest_pose = &rest,
        .out = &out,
    }).run();
    try zozz.pose.toLocalTransforms(&out, &result);
    for (result) |t| {
        // Translation adds.
        try std.testing.expectApproxEqAbs(@as(f32, 6), t.translation[0], 1e-4);
        try std.testing.expectApproxEqAbs(@as(f32, 2), t.translation[1], 1e-4);
        try std.testing.expectApproxEqAbs(@as(f32, 3), t.translation[2], 1e-4);
        // Scale multiplies.
        try std.testing.expectApproxEqAbs(@as(f32, 2), t.scale[0], 1e-4);
        try std.testing.expectApproxEqAbs(@as(f32, 2), t.scale[1], 1e-4);
        try std.testing.expectApproxEqAbs(@as(f32, 2), t.scale[2], 1e-4);
        // Base rotation is identity, so the composed rotation must equal the
        // delta's exactly, up to the quaternion's double cover (q ~ -q).
        var dot: f32 = 0;
        for (t.rotation, delta_transform.rotation) |a, b| dot += a * b;
        try std.testing.expect(@abs(dot) > 0.999);
    }
}

test "a partial blend with per-joint weights affects only the weighted joints" {
    try zozz.setAllocator(std.testing.allocator);
    defer zozz.resetAllocator();

    const n = 8; // two SoA blocks, with the mask interleaved within each.
    var a_t: [n]zozz.Transform = undefined;
    var b_t: [n]zozz.Transform = undefined;
    var joint_weights: [n]f32 = undefined;
    for (0..n) |i| {
        a_t[i] = translated(0);
        b_t[i] = translated(10);
        joint_weights[i] = if (i % 2 == 0) 1 else 0;
    }
    const pose_a = try poseOf(n, &a_t);
    const pose_b = try poseOf(n, &b_t);
    const rest = try identityPose(n);
    var out = try identityPose(n);

    var mask: [blocks(n)]zozz.math.SimdFloat4 = undefined;
    try zozz.pose.packJointWeights(&joint_weights, &mask);

    // Layer A always contributes at weight 1; layer B contributes at weight
    // 1 only where the mask says so. Where the mask is 0, layer B's combined
    // weight for that joint is 0 and normalisation leaves A as the whole
    // answer — the joint must come out exactly unchanged.
    try (zozz.BlendingJob{
        .layers = &.{
            zozz.blending.layer(1, &pose_a),
            zozz.blending.maskedLayer(1, &pose_b, &mask),
        },
        .rest_pose = &rest,
        .out = &out,
    }).run();

    var result: [n]zozz.Transform = undefined;
    try zozz.pose.toLocalTransforms(&out, &result);
    for (0..n) |i| {
        const expected: f32 = if (i % 2 == 0) 5 else 0;
        try std.testing.expectApproxEqAbs(expected, result[i].translation[0], 1e-4);
    }
}

test "packJointWeights fills the lanes past the joint count with 1.0" {
    try zozz.setAllocator(std.testing.allocator);
    defer zozz.resetAllocator();

    // 5 joints: the second block holds one real lane and three padding ones,
    // and ozz reads whole blocks, so the padding must mean "fully weighted".
    const weights = [_]f32{ 0, 0.25, 0.5, 0.75, 1 };
    var mask: [blocks(5)]zozz.math.SimdFloat4 = undefined;
    try zozz.pose.packJointWeights(&weights, &mask);

    for (weights, 0..) |expected, i| {
        const lanes: [4]f32 = mask[i / 4];
        try std.testing.expectEqual(expected, lanes[i % 4]);
    }
    const tail: [4]f32 = mask[1];
    for (1..4) |lane| try std.testing.expectEqual(@as(f32, 1), tail[lane]);

    // A buffer too small for the joints, and a non-finite weight, are refused.
    var one: [1]zozz.math.SimdFloat4 = undefined;
    try std.testing.expectError(
        zozz.Error.BufferTooSmall,
        zozz.pose.packJointWeights(&weights, &one),
    );
    const nan = [_]f32{ 1, std.math.nan(f32), 1, 1 };
    try std.testing.expectError(
        zozz.Error.InvalidArgument,
        zozz.pose.packJointWeights(&nan, &one),
    );
}
