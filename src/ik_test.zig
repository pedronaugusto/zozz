//! Behavioural tests for two-bone and aim IK, and folding a correction back
//! into a pose.
//!
//! The three-joint chain used below is built directly in code with
//! `RawSkeleton`, so `localToModel` gives the model-space matrices the IK
//! jobs expect without any asset file.

const std = @import("std");
const zozz = @import("zozz.zig");

fn translated(x: f32, y: f32, z: f32) zozz.Transform {
    var t = zozz.transform_identity;
    t.translation = .{ x, y, z };
    return t;
}

fn distance(a: [3]f32, b: [3]f32) f32 {
    var sum: f32 = 0;
    for (a, b) |x, y| sum += (x - y) * (x - y);
    return @sqrt(sum);
}

fn position(m: zozz.Mat4) [3]f32 {
    return .{ m.m[12], m.m[13], m.m[14] };
}

fn cross(a: [3]f32, b: [3]f32) [3]f32 {
    return .{
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    };
}

/// Rotates `v` by quaternion `q` (x, y, z, w — w LAST).
fn rotate(q: [4]f32, v: [3]f32) [3]f32 {
    const qv = [3]f32{ q[0], q[1], q[2] };
    const w = q[3];
    const uv = cross(qv, v);
    const uuv = cross(qv, uv);
    return .{
        v[0] + 2 * (w * uv[0] + uuv[0]),
        v[1] + 2 * (w * uv[1] + uuv[1]),
        v[2] + 2 * (w * uv[2] + uuv[2]),
    };
}

fn normalize(v: [3]f32) [3]f32 {
    const len = @sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
    return .{ v[0] / len, v[1] / len, v[2] / len };
}

test "two-bone IK moves the end effector toward the target, and reaches an in-range one" {
    const gpa = std.testing.allocator;
    try zozz.setAllocator(gpa);
    defer zozz.resetAllocator() catch unreachable;

    // A two-bone chain lying flat along +X, each bone length 1: fully
    // extended reach is 2.
    var raw = try zozz.RawSkeleton.init();
    defer raw.deinit();
    const start = try raw.addJoint(null, "start", translated(0, 0, 0));
    const mid = try raw.addJoint(start, "mid", translated(1, 0, 0));
    _ = try raw.addJoint(mid, "end", translated(1, 0, 0));
    var skel = try raw.build();
    defer skel.deinit();

    // Three joints fit in one SoA block.
    var pose: [1]zozz.SoaTransform = undefined;
    try skel.restPoseSoa(&pose);

    var models: [3]zozz.Mat4 = undefined;
    try (zozz.LocalToModelJob{ .skeleton = skel, .locals = &pose, .root = null, .out = &models }).run();

    // Case 1: a target beyond the chain's reach, off the chain's own axis so
    // reaching it actually requires bending. The end effector cannot reach
    // it, but folding the correction back must still move it closer, never
    // farther away.
    {
        const target = [3]f32{ 2, 2, 0 };
        const before = distance(position(models[2]), target);

        const result = try (zozz.ik.TwoBoneJob{
            .target = .{ target[0], target[1], target[2], 0 },
            .start_joint = &models[0],
            .mid_joint = &models[1],
            .end_joint = &models[2],
        }).run();
        try std.testing.expect(!result.reached);

        // Both joints of the chain in ONE crossing, which is what a batch is
        // for: they are in the same SoA block, so this is also one transpose.
        try zozz.ik.applyCorrections(&pose, &.{
            zozz.ik.correction(start, result.start_joint_correction),
            zozz.ik.correction(mid, result.mid_joint_correction),
        });
        try (zozz.LocalToModelJob{ .skeleton = skel, .locals = &pose, .root = null, .out = &models }).run();
        const after = distance(position(models[2]), target);

        try std.testing.expect(after < before);
    }

    // Reset to the rest pose for a clean second case.
    try skel.restPoseSoa(&pose);
    try (zozz.LocalToModelJob{ .skeleton = skel, .locals = &pose, .root = null, .out = &models }).run();

    // Case 2: a target inside the chain's reach must actually be reached.
    {
        const target = [3]f32{ 1.5, 0.5, 0 };
        const result = try (zozz.ik.TwoBoneJob{
            .target = .{ target[0], target[1], target[2], 0 },
            .start_joint = &models[0],
            .mid_joint = &models[1],
            .end_joint = &models[2],
        }).run();
        try std.testing.expect(result.reached);

        // The single-joint spelling, twice: the same entry point with a
        // one-element batch, and it must land the chain in the same place.
        try zozz.ik.applyCorrection(&pose, start, result.start_joint_correction);
        try zozz.ik.applyCorrection(&pose, mid, result.mid_joint_correction);
        try (zozz.LocalToModelJob{ .skeleton = skel, .locals = &pose, .root = null, .out = &models }).run();
        const reached_pos = position(models[2]);

        try std.testing.expectApproxEqAbs(target[0], reached_pos[0], 5e-3);
        try std.testing.expectApproxEqAbs(target[1], reached_pos[1], 5e-3);
        try std.testing.expectApproxEqAbs(target[2], reached_pos[2], 5e-3);
    }
}

test "aim IK points the forward axis at the target" {
    const gpa = std.testing.allocator;
    try zozz.setAllocator(gpa);
    defer zozz.resetAllocator() catch unreachable;

    var pose: [1]zozz.SoaTransform = undefined;
    try zozz.pose.setIdentity(&pose);
    // The joint sits at the origin with identity rotation, so its local
    // space equals its model space: the correction can be applied to the
    // pose and the aimed direction read back directly.
    const joint_matrix = zozz.mat4_identity;

    const result = try (zozz.ik.AimJob{
        .target = .{ 0, 0, 5, 0 },
        .joint = &joint_matrix,
    }).run();

    try zozz.ik.applyCorrection(&pose, 0, result.joint_correction);
    var locals: [1]zozz.Transform = undefined;
    try zozz.pose.toLocalTransforms(&pose, &locals);

    const aimed = normalize(rotate(locals[0].rotation, .{ 1, 0, 0 }));
    const target_dir = normalize([3]f32{ 0, 0, 5 });
    var dot: f32 = 0;
    for (aimed, target_dir) |a, b| dot += a * b;
    try std.testing.expect(dot > 0.999);
}

test "weight = 0 is identity: exactly for TwoBoneJob, to ozz's Est tolerance for AimJob" {
    const gpa = std.testing.allocator;
    try zozz.setAllocator(gpa);
    defer zozz.resetAllocator() catch unreachable;

    var raw = try zozz.RawSkeleton.init();
    defer raw.deinit();
    const start = try raw.addJoint(null, "start", translated(0, 0, 0));
    const mid = try raw.addJoint(start, "mid", translated(1, 0, 0));
    _ = try raw.addJoint(mid, "end", translated(1, 0, 0));
    var skel = try raw.build();
    defer skel.deinit();
    // Three joints fit in one SoA block.
    var pose: [1]zozz.SoaTransform = undefined;
    try skel.restPoseSoa(&pose);
    var models: [3]zozz.Mat4 = undefined;
    try (zozz.LocalToModelJob{ .skeleton = skel, .locals = &pose, .root = null, .out = &models }).run();

    const two_bone = try (zozz.ik.TwoBoneJob{
        .target = .{ 5, 5, 5, 0 }, // wildly off-axis; would normally bend hard.
        .weight = 0,
        .start_joint = &models[0],
        .mid_joint = &models[1],
        .end_joint = &models[2],
    }).run();
    // IKTwoBoneJob::Run has an explicit `weight <= 0` early-out that assigns
    // SimdQuaternion::identity() (ik_two_bone_job.cc), so this half is exact
    // on every backend and is held to an exact bar.
    for ([_]zozz.ik.Vec4{ two_bone.start_joint_correction, two_bone.mid_joint_correction }) |c| {
        try std.testing.expectEqual(@as(f32, 0), c[0]);
        try std.testing.expectEqual(@as(f32, 0), c[1]);
        try std.testing.expectEqual(@as(f32, 0), c[2]);
        try std.testing.expectEqual(@as(f32, 1), c[3]);
    }

    const joint_matrix = zozz.mat4_identity;
    const aim = try (zozz.ik.AimJob{
        .target = .{ 5, 5, 5, 0 },
        .weight = 0,
        .joint = &joint_matrix,
    }).run();
    try expectIdentityToEstTolerance(aim.joint_correction);
}

/// ozz's `IKAimJob` has no weight-0 early-out: at any weight < 1 it returns
/// `NormalizeEst4(Lerp(identity, q, weight))` (ik_aim_job.cc). `NormalizeEst4`
/// is `_mm_rsqrt_ps` on the SSE backend, whose 12-bit estimate makes
/// rsqrt(1.0) = 0.999755859375, so the "identity" it returns is identity only
/// to ozz's OWN estimated-normalisation tolerance. That constant is the only
/// correct bar here; a tighter one asserts something ozz does not promise.
fn expectIdentityToEstTolerance(q: [4]f32) !void {
    const tol = zozz.math.normalization_tolerance_est_sq;

    // Normalised to est precision — ozz's own IsNormalizedEst4 predicate.
    try std.testing.expect(zozz.math.simd_float4.isNormalizedEst4(q)[0] != 0);

    // And identity to est precision: the rotation angle is 2*acos(|w|), and
    // |w| >= 1 - tol bounds it. Comparing the components directly to (0,0,0,1)
    // at the same bar says the same thing for a normalised quaternion.
    try std.testing.expectApproxEqAbs(@as(f32, 0), q[0], tol);
    try std.testing.expectApproxEqAbs(@as(f32, 0), q[1], tol);
    try std.testing.expectApproxEqAbs(@as(f32, 0), q[2], tol);
    try std.testing.expectApproxEqAbs(@as(f32, 1), @abs(q[3]), tol);
}

test "AimJob's weight-0 identity is exact on a scalar ozz backend and estimated on SSE" {
    // The measured difference between the two backends ozz ships, pinned so it
    // cannot be mistaken for a binding defect again. ozz has `ref` (scalar) and
    // `sse` only -- no NEON -- so aarch64 runs `ref` and returns exactly 1.0,
    // while x86_64 runs `sse` and returns rsqrt(1.0) = 0.999755859375.
    const gpa = std.testing.allocator;
    try zozz.setAllocator(gpa);
    defer zozz.resetAllocator() catch unreachable;

    const joint_matrix = zozz.mat4_identity;
    const aim = try (zozz.ik.AimJob{
        .target = .{ 5, 5, 5, 0 },
        .weight = 0,
        .joint = &joint_matrix,
    }).run();

    try expectIdentityToEstTolerance(aim.joint_correction);

    // The estimate never OVER-shoots: rsqrt's estimate of 1/sqrt(1) is at or
    // below 1, so w is in (1 - tol, 1]. A w above 1 would mean the mechanism
    // recorded here is not the one running.
    try std.testing.expect(@abs(aim.joint_correction[3]) <= 1.0);
    try std.testing.expect(@abs(aim.joint_correction[3]) > 1.0 - zozz.math.normalization_tolerance_est_sq);
}

test "IK job defaults match ozz's own" {
    // `TwoBoneJob` and `AimJob` document their field defaults as ozz's
    // defaults, written out as literals — the ergonomic Zig spelling, and the
    // one that rots. ozz ships the values through `zozzIKTwoBoneJobDefaults`
    // and `zozzIKAimJobDefaults` so a binding need not copy them; this test
    // makes that copy an assertion rather than a hope, failing the next time
    // a re-vendor retunes one.
    const c = @import("c.zig");
    const dummy = zozz.mat4_identity;

    var two_bone_defaults: c.IKTwoBoneJob = undefined;
    c.zozzIKTwoBoneJobDefaults(&two_bone_defaults);
    const two_bone = zozz.ik.TwoBoneJob{
        .start_joint = &dummy,
        .mid_joint = &dummy,
        .end_joint = &dummy,
    };
    try std.testing.expectEqual(two_bone_defaults.target, @as(c.SimdFloat4, @bitCast(two_bone.target)));
    try std.testing.expectEqual(two_bone_defaults.mid_axis, @as(c.SimdFloat4, @bitCast(two_bone.mid_axis)));
    try std.testing.expectEqual(two_bone_defaults.pole_vector, @as(c.SimdFloat4, @bitCast(two_bone.pole_vector)));
    try std.testing.expectEqual(two_bone_defaults.twist_angle, two_bone.twist_angle);
    try std.testing.expectEqual(two_bone_defaults.soften, two_bone.soften);
    try std.testing.expectEqual(two_bone_defaults.weight, two_bone.weight);

    var aim_defaults: c.IKAimJob = undefined;
    c.zozzIKAimJobDefaults(&aim_defaults);
    const aim = zozz.ik.AimJob{ .joint = &dummy };
    try std.testing.expectEqual(aim_defaults.target, @as(c.SimdFloat4, @bitCast(aim.target)));
    try std.testing.expectEqual(aim_defaults.forward, @as(c.SimdFloat4, @bitCast(aim.forward)));
    try std.testing.expectEqual(aim_defaults.offset, @as(c.SimdFloat4, @bitCast(aim.offset)));
    try std.testing.expectEqual(aim_defaults.up, @as(c.SimdFloat4, @bitCast(aim.up)));
    try std.testing.expectEqual(aim_defaults.pole_vector, @as(c.SimdFloat4, @bitCast(aim.pole_vector)));
    try std.testing.expectEqual(aim_defaults.twist_angle, aim.twist_angle);
    try std.testing.expectEqual(aim_defaults.weight, aim.weight);
}

test "a batch of corrections is the same as applying them one at a time" {
    const gpa = std.testing.allocator;
    try zozz.setAllocator(gpa);
    defer zozz.resetAllocator() catch unreachable;

    const h = @sqrt(0.5);
    const q_z: zozz.ik.Vec4 = .{ 0, 0, h, h };
    const q_x: zozz.ik.Vec4 = .{ h, 0, 0, h };
    const q_y: zozz.ik.Vec4 = .{ 0, h, 0, h };

    // Eight joints, so two SoA blocks: the batch below spans the block
    // boundary AND has two corrections inside block 0, which is the run the
    // implementation hoists a single transpose over.
    var batched: [2]zozz.SoaTransform = undefined;
    var one_by_one: [2]zozz.SoaTransform = undefined;
    try zozz.pose.setIdentity(&batched);
    try zozz.pose.setIdentity(&one_by_one);

    try zozz.ik.applyCorrections(&batched, &.{
        zozz.ik.correction(0, q_z),
        zozz.ik.correction(2, q_x),
        zozz.ik.correction(5, q_y),
    });
    try zozz.ik.applyCorrection(&one_by_one, 0, q_z);
    try zozz.ik.applyCorrection(&one_by_one, 2, q_x);
    try zozz.ik.applyCorrection(&one_by_one, 5, q_y);

    var from_batch: [8]zozz.Transform = undefined;
    var from_singles: [8]zozz.Transform = undefined;
    try zozz.pose.toLocalTransforms(&batched, &from_batch);
    try zozz.pose.toLocalTransforms(&one_by_one, &from_singles);
    try std.testing.expectEqualSlices(zozz.Transform, &from_singles, &from_batch);

    // An out-of-range joint anywhere in the batch is refused BEFORE anything
    // is written: half an IK pass is worse than none of it.
    try std.testing.expectError(error.InvalidArgument, zozz.ik.applyCorrections(&batched, &.{
        zozz.ik.correction(1, q_z),
        zozz.ik.correction(99, q_z),
    }));
    var after_failure: [8]zozz.Transform = undefined;
    try zozz.pose.toLocalTransforms(&batched, &after_failure);
    try std.testing.expectEqualSlices(zozz.Transform, &from_batch, &after_failure);

    // An empty batch is a no-op, not an error: a pass that found nothing to
    // correct should not have to special-case the call.
    try zozz.ik.applyCorrections(&batched, &.{});
    try zozz.pose.toLocalTransforms(&batched, &after_failure);
    try std.testing.expectEqualSlices(zozz.Transform, &from_batch, &after_failure);
}
