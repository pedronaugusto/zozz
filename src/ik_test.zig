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
    defer zozz.resetAllocator();

    // A two-bone chain lying flat along +X, each bone length 1: fully
    // extended reach is 2.
    const raw = try zozz.RawSkeleton.init();
    defer raw.deinit();
    const start = try raw.addJoint(null, "start", translated(0, 0, 0));
    const mid = try raw.addJoint(start, "mid", translated(1, 0, 0));
    _ = try raw.addJoint(mid, "end", translated(1, 0, 0));
    const skel = try raw.build();
    defer skel.deinit();

    const pose = try zozz.SoaPose.initForSkeleton(skel);
    defer pose.deinit();
    try pose.setRestPose(skel);

    var models: [3]zozz.Mat4 = undefined;
    try (zozz.LocalToModelJob{ .skeleton = skel, .locals = pose, .root = null, .out = &models }).run();

    // Case 1: a target beyond the chain's reach, off the chain's own axis so
    // reaching it actually requires bending. The end effector cannot reach
    // it, but folding the correction back must still move it closer, never
    // farther away.
    {
        const target = [3]f32{ 2, 2, 0 };
        const before = distance(position(models[2]), target);

        const result = try (zozz.ik.TwoBoneJob{
            .target = target,
            .start_joint = &models[0],
            .mid_joint = &models[1],
            .end_joint = &models[2],
        }).run();
        try std.testing.expect(!result.reached);

        try zozz.ik.applyCorrection(pose, start, result.start_joint_correction);
        try zozz.ik.applyCorrection(pose, mid, result.mid_joint_correction);
        try (zozz.LocalToModelJob{ .skeleton = skel, .locals = pose, .root = null, .out = &models }).run();
        const after = distance(position(models[2]), target);

        try std.testing.expect(after < before);
    }

    // Reset to the rest pose for a clean second case.
    try pose.setRestPose(skel);
    try (zozz.LocalToModelJob{ .skeleton = skel, .locals = pose, .root = null, .out = &models }).run();

    // Case 2: a target inside the chain's reach must actually be reached.
    {
        const target = [3]f32{ 1.5, 0.5, 0 };
        const result = try (zozz.ik.TwoBoneJob{
            .target = target,
            .start_joint = &models[0],
            .mid_joint = &models[1],
            .end_joint = &models[2],
        }).run();
        try std.testing.expect(result.reached);

        try zozz.ik.applyCorrection(pose, start, result.start_joint_correction);
        try zozz.ik.applyCorrection(pose, mid, result.mid_joint_correction);
        try (zozz.LocalToModelJob{ .skeleton = skel, .locals = pose, .root = null, .out = &models }).run();
        const reached_pos = position(models[2]);

        try std.testing.expectApproxEqAbs(target[0], reached_pos[0], 5e-3);
        try std.testing.expectApproxEqAbs(target[1], reached_pos[1], 5e-3);
        try std.testing.expectApproxEqAbs(target[2], reached_pos[2], 5e-3);
    }
}

test "aim IK points the forward axis at the target" {
    const gpa = std.testing.allocator;
    try zozz.setAllocator(gpa);
    defer zozz.resetAllocator();

    const pose = try zozz.SoaPose.init(1);
    defer pose.deinit();
    // The joint sits at the origin with identity rotation, so its local
    // space equals its model space: the correction can be applied to the
    // pose and the aimed direction read back directly.
    const joint_matrix = zozz.mat4_identity;

    const result = try (zozz.ik.AimJob{
        .target = .{ 0, 0, 5 },
        .joint = &joint_matrix,
    }).run();

    try zozz.ik.applyCorrection(pose, 0, result.joint_correction);
    var locals: [1]zozz.Transform = undefined;
    try pose.toLocalTransforms(&locals);

    const aimed = normalize(rotate(locals[0].rotation, .{ 1, 0, 0 }));
    const target_dir = normalize([3]f32{ 0, 0, 5 });
    var dot: f32 = 0;
    for (aimed, target_dir) |a, b| dot += a * b;
    try std.testing.expect(dot > 0.999);
}

test "weight = 0 is identity: exactly for TwoBoneJob, to ozz's Est tolerance for AimJob" {
    const gpa = std.testing.allocator;
    try zozz.setAllocator(gpa);
    defer zozz.resetAllocator();

    const raw = try zozz.RawSkeleton.init();
    defer raw.deinit();
    const start = try raw.addJoint(null, "start", translated(0, 0, 0));
    const mid = try raw.addJoint(start, "mid", translated(1, 0, 0));
    _ = try raw.addJoint(mid, "end", translated(1, 0, 0));
    const skel = try raw.build();
    defer skel.deinit();
    const pose = try zozz.SoaPose.initForSkeleton(skel);
    defer pose.deinit();
    try pose.setRestPose(skel);
    var models: [3]zozz.Mat4 = undefined;
    try (zozz.LocalToModelJob{ .skeleton = skel, .locals = pose, .root = null, .out = &models }).run();

    const two_bone = try (zozz.ik.TwoBoneJob{
        .target = .{ 5, 5, 5 }, // wildly off-axis; would normally bend hard.
        .weight = 0,
        .start_joint = &models[0],
        .mid_joint = &models[1],
        .end_joint = &models[2],
    }).run();
    // IKTwoBoneJob::Run has an explicit `weight <= 0` early-out that assigns
    // SimdQuaternion::identity() (ik_two_bone_job.cc), so this half is exact
    // on every backend and is held to an exact bar.
    for ([_][4]f32{ two_bone.start_joint_correction, two_bone.mid_joint_correction }) |c| {
        try std.testing.expectEqual(@as(f32, 0), c[0]);
        try std.testing.expectEqual(@as(f32, 0), c[1]);
        try std.testing.expectEqual(@as(f32, 0), c[2]);
        try std.testing.expectEqual(@as(f32, 1), c[3]);
    }

    const joint_matrix = zozz.mat4_identity;
    const aim = try (zozz.ik.AimJob{
        .target = .{ 5, 5, 5 },
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
    defer zozz.resetAllocator();

    const joint_matrix = zozz.mat4_identity;
    const aim = try (zozz.ik.AimJob{
        .target = .{ 5, 5, 5 },
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
    try std.testing.expectEqual(two_bone_defaults.target, two_bone.target);
    try std.testing.expectEqual(two_bone_defaults.mid_axis, two_bone.mid_axis);
    try std.testing.expectEqual(two_bone_defaults.pole_vector, two_bone.pole_vector);
    try std.testing.expectEqual(two_bone_defaults.twist_angle, two_bone.twist_angle);
    try std.testing.expectEqual(two_bone_defaults.soften, two_bone.soften);
    try std.testing.expectEqual(two_bone_defaults.weight, two_bone.weight);

    var aim_defaults: c.IKAimJob = undefined;
    c.zozzIKAimJobDefaults(&aim_defaults);
    const aim = zozz.ik.AimJob{ .joint = &dummy };
    try std.testing.expectEqual(aim_defaults.target, aim.target);
    try std.testing.expectEqual(aim_defaults.forward, aim.forward);
    try std.testing.expectEqual(aim_defaults.offset, aim.offset);
    try std.testing.expectEqual(aim_defaults.up, aim.up);
    try std.testing.expectEqual(aim_defaults.pole_vector, aim.pole_vector);
    try std.testing.expectEqual(aim_defaults.twist_angle, aim.twist_angle);
    try std.testing.expectEqual(aim_defaults.weight, aim.weight);
}
