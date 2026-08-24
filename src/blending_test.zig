//! Behavioural tests for pose blending (ozz::animation::BlendingJob): the
//! normal weighted blend, additive layers, and per-joint partial blending
//! through the SoA weight buffer.
//!
//! Fixtures are built directly in code — plain arrays of `Transform` fed
//! through `SoaPose.fromLocalTransforms` — so nothing here depends on a
//! skeleton or an asset file.

const std = @import("std");
const zozz = @import("zozz.zig");

fn poseOf(n: u32, transforms: []const zozz.Transform) !zozz.SoaPose {
    const pose = try zozz.SoaPose.init(n);
    errdefer pose.deinit();
    try pose.fromLocalTransforms(transforms);
    return pose;
}

fn translated(x: f32) zozz.Transform {
    var t = zozz.transform_identity;
    t.translation[0] = x;
    return t;
}

test "two layers blended at 0.5 land between them, per joint" {
    const gpa = std.testing.allocator;
    try zozz.setAllocator(gpa);
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
    defer pose_a.deinit();
    const pose_b = try poseOf(n, &b_t);
    defer pose_b.deinit();
    const rest = try zozz.SoaPose.init(n);
    defer rest.deinit();
    const out = try zozz.SoaPose.init(n);
    defer out.deinit();

    try (zozz.BlendingJob{
        .layers = &[_]zozz.BlendingLayer{
            .{ .weight = 0.5, .transform = pose_a },
            .{ .weight = 0.5, .transform = pose_b },
        },
        .additive_layers = &[_]zozz.BlendingLayer{},
        .rest_pose = rest,
        .threshold = 0.1,
        .out = out,
    }).run(gpa);

    var result: [n]zozz.Transform = undefined;
    try out.toLocalTransforms(&result);
    for (0..n) |i| {
        const f: f32 = @floatFromInt(i);
        try std.testing.expectApproxEqAbs(f + 5, result[i].translation[0], 1e-4);
    }
}

test "weight 0 on a layer yields exactly the other layer" {
    const gpa = std.testing.allocator;
    try zozz.setAllocator(gpa);
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
    defer pose_a.deinit();
    const pose_b = try poseOf(n, &b_t);
    defer pose_b.deinit();
    const rest = try zozz.SoaPose.init(n);
    defer rest.deinit();
    const out = try zozz.SoaPose.init(n);
    defer out.deinit();

    try (zozz.BlendingJob{
        .layers = &[_]zozz.BlendingLayer{
            .{ .weight = 1, .transform = pose_a },
            .{ .weight = 0, .transform = pose_b },
        },
        .additive_layers = &[_]zozz.BlendingLayer{},
        .rest_pose = rest,
        .threshold = 0.1,
        .out = out,
    }).run(gpa);

    var result: [n]zozz.Transform = undefined;
    try out.toLocalTransforms(&result);
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
    const gpa = std.testing.allocator;
    try zozz.setAllocator(gpa);
    defer zozz.resetAllocator();

    const n = 4;
    const base_transform: zozz.Transform = .{
        .translation = .{ 1, 2, 3 },
        .rotation = .{ 0, 0, 0, 1 },
        .scale = .{ 1, 1, 1 },
    };
    const base = [_]zozz.Transform{base_transform} ** n;
    const rest = try poseOf(n, &base);
    defer rest.deinit();

    // A delta pose: translate, a 90-degree turn about Z, and double scale.
    const half_angle: f32 = std.math.pi / 4.0;
    const delta_transform: zozz.Transform = .{
        .translation = .{ 5, 0, 0 },
        .rotation = .{ 0, 0, @sin(half_angle), @cos(half_angle) },
        .scale = .{ 2, 2, 2 },
    };
    const delta = [_]zozz.Transform{delta_transform} ** n;
    const delta_pose = try poseOf(n, &delta);
    defer delta_pose.deinit();

    const out = try zozz.SoaPose.init(n);
    defer out.deinit();

    // Empty `layers`: every joint's accumulated weight is 0, below any
    // positive threshold, so the base comes from `rest_pose` alone — this is
    // the documented fallback, used here to isolate the additive pass.
    try (zozz.BlendingJob{
        .layers = &[_]zozz.BlendingLayer{},
        .additive_layers = &[_]zozz.BlendingLayer{
            .{ .weight = 0, .transform = delta_pose },
        },
        .rest_pose = rest,
        .threshold = 0.1,
        .out = out,
    }).run(gpa);
    var result: [n]zozz.Transform = undefined;
    try out.toLocalTransforms(&result);
    for (result) |t| {
        try std.testing.expectApproxEqAbs(@as(f32, 1), t.translation[0], 1e-4);
        try std.testing.expectApproxEqAbs(@as(f32, 2), t.translation[1], 1e-4);
        try std.testing.expectApproxEqAbs(@as(f32, 3), t.translation[2], 1e-4);
        try std.testing.expectApproxEqAbs(@as(f32, 1), t.scale[0], 1e-4);
        try std.testing.expectApproxEqAbs(@as(f32, 1), t.rotation[3], 1e-4);
    }

    try (zozz.BlendingJob{
        .layers = &[_]zozz.BlendingLayer{},
        .additive_layers = &[_]zozz.BlendingLayer{
            .{ .weight = 1, .transform = delta_pose },
        },
        .rest_pose = rest,
        .threshold = 0.1,
        .out = out,
    }).run(gpa);
    try out.toLocalTransforms(&result);
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
    const gpa = std.testing.allocator;
    try zozz.setAllocator(gpa);
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
    defer pose_a.deinit();
    const pose_b = try poseOf(n, &b_t);
    defer pose_b.deinit();
    const rest = try zozz.SoaPose.init(n);
    defer rest.deinit();
    const out = try zozz.SoaPose.init(n);
    defer out.deinit();

    const weights = try zozz.SoaWeights.init(n);
    defer weights.deinit();
    try weights.fromArray(&joint_weights);

    // Layer A always contributes at weight 1; layer B contributes at weight
    // 1 only where the mask says so. Where the mask is 0, layer B's combined
    // weight for that joint is 0 and normalisation leaves A as the whole
    // answer — the joint must come out exactly unchanged.
    try (zozz.BlendingJob{
        .layers = &[_]zozz.BlendingLayer{
            .{ .weight = 1, .transform = pose_a },
            .{ .weight = 1, .transform = pose_b, .joint_weights = weights },
        },
        .additive_layers = &[_]zozz.BlendingLayer{},
        .rest_pose = rest,
        .threshold = 0.1,
        .out = out,
    }).run(gpa);

    var result: [n]zozz.Transform = undefined;
    try out.toLocalTransforms(&result);
    for (0..n) |i| {
        const expected: f32 = if (i % 2 == 0) 5 else 0;
        try std.testing.expectApproxEqAbs(expected, result[i].translation[0], 1e-4);
    }
}
