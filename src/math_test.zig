//! Behavioural tests for the pure-Zig ozz::math port in math.zig.
//!
//! Expected values are computed by hand from ozz's C++ source formulas (see
//! math.zig's doc comments for which ozz function each one mirrors), not
//! from this file's own implementation.

const std = @import("std");
const zozz = @import("zozz.zig");
const math = zozz.math;

const tol: f32 = 1e-5;

fn expectVecApprox(expected: math.SimdFloat4, actual: math.SimdFloat4, tolerance: f32) !void {
    inline for (0..4) |i| {
        try std.testing.expectApproxEqAbs(expected[i], actual[i], tolerance);
    }
}

// Lane ops.

test "splatX/Y/Z/W broadcast a single lane" {
    const v: math.SimdFloat4 = .{ 1, 2, 3, 4 };
    try expectVecApprox(.{ 1, 1, 1, 1 }, math.simd_float4.splatX(v), tol);
    try expectVecApprox(.{ 2, 2, 2, 2 }, math.simd_float4.splatY(v), tol);
    try expectVecApprox(.{ 3, 3, 3, 3 }, math.simd_float4.splatZ(v), tol);
    try expectVecApprox(.{ 4, 4, 4, 4 }, math.simd_float4.splatW(v), tol);
}

test "x accessor, withY, withW" {
    const v: math.SimdFloat4 = .{ 1, 2, 3, 4 };
    try std.testing.expectEqual(@as(f32, 1), math.simd_float4.x(v));
    try expectVecApprox(.{ 1, 9, 3, 4 }, math.simd_float4.withY(v, .{ 9, 0, 0, 0 }), tol);
    try expectVecApprox(.{ 1, 2, 3, 9 }, math.simd_float4.withW(v, .{ 9, 0, 0, 0 }), tol);
}

test "cmpLt, cmpNe, select, and, xor" {
    const a: math.SimdFloat4 = .{ 1, 2, 3, 4 };
    const b: math.SimdFloat4 = .{ 4, 2, 1, 4 };
    try std.testing.expectEqual(math.SimdInt4{ -1, 0, 0, 0 }, math.simd_int4.cmpLt(a, b));
    try std.testing.expectEqual(math.SimdInt4{ -1, 0, -1, 0 }, math.simd_int4.cmpNe(a, b));

    const mask = math.simd_int4.cmpLt(a, b);
    try expectVecApprox(.{ 100, 0, 0, 0 }, math.simd_float4.select(mask, .{ 100, 200, 300, 400 }, .{ 0, 0, 0, 0 }), tol);

    try std.testing.expectEqual(math.SimdInt4{ -1, 0, 0, 0 }, math.simd_int4.@"and"(.{ -1, -1, 0, 0 }, .{ -1, 0, -1, 0 }));
    try std.testing.expectEqual(math.SimdInt4{ 0, -1, -1, 0 }, math.simd_int4.xor(.{ -1, -1, 0, 0 }, .{ -1, 0, -1, 0 }));
}

test "hAdd2/3/4" {
    const v: math.SimdFloat4 = .{ 1, 2, 3, 4 };
    try std.testing.expectApproxEqAbs(@as(f32, 3), math.simd_float4.hAdd2(v)[0], tol);
    try std.testing.expectApproxEqAbs(@as(f32, 6), math.simd_float4.hAdd3(v)[0], tol);
    try std.testing.expectApproxEqAbs(@as(f32, 10), math.simd_float4.hAdd4(v)[0], tol);
}

test "mAdd, nMAdd" {
    const a: math.SimdFloat4 = .{ 1, 2, 3, 4 };
    const b: math.SimdFloat4 = .{ 5, 6, 7, 8 };
    const c: math.SimdFloat4 = .{ 1, 1, 1, 1 };
    try expectVecApprox(.{ 6, 13, 22, 33 }, math.simd_float4.mAdd(a, b, c), tol);
    try expectVecApprox(.{ -4, -11, -20, -31 }, math.simd_float4.nMAdd(a, b, c), tol);
}

test "sqrt, sqrtX, rSqrtEstNR" {
    const v: math.SimdFloat4 = .{ 4, 9, 16, 25 };
    try expectVecApprox(.{ 2, 3, 4, 5 }, math.simd_float4.sqrt(v), tol);
    try expectVecApprox(.{ 2, 9, 16, 25 }, math.simd_float4.sqrtX(v), tol);
    try expectVecApprox(.{ 0.5, 1.0 / 3.0, 0.25, 0.2 }, math.simd_float4.rSqrtEstNR(v), 1e-4);
}

test "storePtrU, store3PtrU" {
    const v: math.SimdFloat4 = .{ 1, 2, 3, 4 };
    var out4: [4]f32 = undefined;
    math.simd_float4.storePtrU(v, &out4);
    try std.testing.expectEqualSlices(f32, &.{ 1, 2, 3, 4 }, &out4);

    var out3: [3]f32 = undefined;
    math.simd_float4.store3PtrU(v, &out3);
    try std.testing.expectEqualSlices(f32, &.{ 1, 2, 3 }, &out3);
}

test "cosX, sinX, aCosX forward to std.math, lane 0 only" {
    const v: math.SimdFloat4 = .{ std.math.pi / 3.0, 7, 8, 9 };
    try expectVecApprox(.{ 0.5, 7, 8, 9 }, math.simd_float4.cosX(v), 1e-5);
    try expectVecApprox(.{ 0.8660254, 7, 8, 9 }, math.simd_float4.sinX(v), 1e-5);
    try expectVecApprox(.{ std.math.pi / 3.0, 7, 8, 9 }, math.simd_float4.aCosX(.{ 0.5, 7, 8, 9 }), 1e-5);
}

test "simd_float4 constants" {
    try expectVecApprox(.{ 0, 0, 0, 0 }, math.simd_float4.zero(), tol);
    try expectVecApprox(.{ 1, 1, 1, 1 }, math.simd_float4.one(), tol);
    try expectVecApprox(.{ 1, 0, 0, 0 }, math.simd_float4.x_axis(), tol);
    try expectVecApprox(.{ 0, 1, 0, 0 }, math.simd_float4.y_axis(), tol);
    try expectVecApprox(.{ 0, 0, 1, 0 }, math.simd_float4.z_axis(), tol);
    try expectVecApprox(.{ 0, 0, 0, 1 }, math.simd_float4.w_axis(), tol);
}

// Vector ops.

test "dot3, dot4, cross3" {
    const a: math.SimdFloat4 = .{ 1, 2, 3, 4 };
    const b: math.SimdFloat4 = .{ 5, 6, 7, 8 };
    try std.testing.expectApproxEqAbs(@as(f32, 38), math.simd_float4.dot3(a, b)[0], tol);
    try std.testing.expectApproxEqAbs(@as(f32, 70), math.simd_float4.dot4(a, b)[0], tol);

    const cross = math.simd_float4.cross3(math.simd_float4.x_axis(), math.simd_float4.y_axis());
    try expectVecApprox(.{ 0, 0, 1, 0 }, cross, tol);
}

test "length3, length4, and their Sqr forms" {
    try std.testing.expectApproxEqAbs(@as(f32, 7), math.simd_float4.length3(.{ 2, 3, 6, 0 })[0], tol);
    try std.testing.expectApproxEqAbs(@as(f32, 49), math.simd_float4.length3Sqr(.{ 2, 3, 6, 0 })[0], tol);
    try std.testing.expectApproxEqAbs(@as(f32, 5), math.simd_float4.length4(.{ 1, 2, 2, 4 })[0], tol);
    try std.testing.expectApproxEqAbs(@as(f32, 25), math.simd_float4.length4Sqr(.{ 1, 2, 2, 4 })[0], tol);
}

test "normalize3 keeps w, normalize4 scales all four lanes" {
    try expectVecApprox(.{ 0.6, 0.8, 0, 99 }, math.simd_float4.normalize3(.{ 3, 4, 0, 99 }), tol);
    try expectVecApprox(.{ 0.2, 0.4, 0.4, 0.8 }, math.simd_float4.normalize4(.{ 1, 2, 2, 4 }), tol);
}

test "normalizeEst3/4 match the exact result (no rsqrt estimate in Zig)" {
    try expectVecApprox(.{ 0.6, 0.8, 0, 99 }, math.simd_float4.normalizeEst3(.{ 3, 4, 0, 99 }), tol);
    try expectVecApprox(.{ 0.2, 0.4, 0.4, 0.8 }, math.simd_float4.normalizeEst4(.{ 1, 2, 2, 4 }), tol);
}

test "normalize of a zero vector via the Safe variants" {
    const safe3: math.SimdFloat4 = .{ 1, 0, 0, 0 };
    // w passes through from the input, not from the fallback.
    try expectVecApprox(.{ 1, 0, 0, 7 }, math.simd_float4.normalizeSafe3(.{ 0, 0, 0, 7 }, safe3), tol);
    try expectVecApprox(.{ 1, 0, 0, 7 }, math.simd_float4.normalizeSafeEst3(.{ 0, 0, 0, 7 }, safe3), tol);

    const safe4: math.SimdFloat4 = .{ 0, 1, 0, 0 };
    try expectVecApprox(safe4, math.simd_float4.normalizeSafe4(.{ 0, 0, 0, 0 }, safe4), tol);
    try expectVecApprox(safe4, math.simd_float4.normalizeSafeEst4(.{ 0, 0, 0, 0 }, safe4), tol);

    // A non-zero vector is unaffected by the fallback.
    try expectVecApprox(.{ 0.6, 0.8, 0, 99 }, math.simd_float4.normalizeSafe3(.{ 3, 4, 0, 99 }, safe3), tol);
}

test "isNormalized3/4 and their Est forms" {
    try std.testing.expectEqual(@as(i32, -1), math.simd_float4.isNormalized3(.{ 0.6, 0.8, 0, 0 })[0]);
    try std.testing.expectEqual(@as(i32, 0), math.simd_float4.isNormalized3(.{ 1, 1, 0, 0 })[0]);
    try std.testing.expectEqual(@as(i32, -1), math.simd_float4.isNormalized4(.{ 0.2, 0.4, 0.4, 0.8 })[0]);
    try std.testing.expectEqual(@as(i32, -1), math.simd_float4.isNormalizedEst3(.{ 0.6, 0.8, 0, 0 })[0]);
    try std.testing.expectEqual(@as(i32, -1), math.simd_float4.isNormalizedEst4(.{ 0.2, 0.4, 0.4, 0.8 })[0]);
}

// Quaternions.

const q_identity: math.SimdFloat4 = .{ 0, 0, 0, 1 };
// 90 degree rotation about z: quaternion.fromAxisAngle(z_axis, pi/2) by hand.
const q_90z: math.SimdFloat4 = .{ 0, 0, 0.70710678, 0.70710678 };
// 180 degree rotation about z.
const q_180z: math.SimdFloat4 = .{ 0, 0, 1, 0 };

test "conjugate" {
    try expectVecApprox(.{ -0.1, -0.2, -0.3, 0.9 }, math.quaternion.conjugate(.{ 0.1, 0.2, 0.3, 0.9 }), tol);
}

test "quaternion.mul composes two 90 degree rotations into 180" {
    try expectVecApprox(q_180z, math.quaternion.mul(q_90z, q_90z), tol);
}

test "nlerp and nlerpEst agree, and normalize the lerp" {
    // lerp(q_identity, q_180z, 0.25) = (0,0,0.25,0.75), normalized.
    const expected: math.SimdFloat4 = .{ 0, 0, 0.31622777, 0.94868330 };
    try expectVecApprox(expected, math.quaternion.nlerp(q_identity, q_180z, 0.25), tol);
    try expectVecApprox(expected, math.quaternion.nlerpEst(q_identity, q_180z, 0.25), tol);
}

test "slerp halfway between a 0 and 180 degree rotation is 90 degrees" {
    try expectVecApprox(q_90z, math.quaternion.slerp(q_identity, q_180z, 0.5), 1e-5);
}

test "slerp past 180 degrees: the shorter-arc hemisphere check" {
    // b is -a: the same rotation as a, reached the long way around. The
    // abs(cos_half_theta) >= .999 check must snap this back to a exactly,
    // for any interpolation factor, instead of computing through the
    // ill-defined near-pi case.
    const a: math.SimdFloat4 = .{ 0.1825742, 0.3651484, 0.5477226, 0.7302967 }; // arbitrary normalized quat
    const b: math.SimdFloat4 = .{ -a[0], -a[1], -a[2], -a[3] };
    try expectVecApprox(a, math.quaternion.slerp(a, b, 0.5), tol);
    try expectVecApprox(a, math.quaternion.slerp(a, b, 0.1), tol);
}

test "fromAxisAngle and fromAxisCosAngle agree" {
    try expectVecApprox(q_90z, math.quaternion.fromAxisAngle(math.simd_float4.z_axis(), std.math.pi / 2.0), tol);
    try expectVecApprox(q_90z, math.quaternion.fromAxisCosAngle(math.simd_float4.z_axis(), 0.0), tol);
}

test "toAxisAngle inverts fromAxisAngle" {
    const axis_angle = math.quaternion.toAxisAngle(q_90z);
    try expectVecApprox(.{ 0, 0, 1, std.math.pi / 2.0 }, axis_angle, tol);

    // Below the axis threshold, angle collapses to 0 too (see math.zig).
    try expectVecApprox(.{ 1, 0, 0, 0 }, math.quaternion.toAxisAngle(q_identity), tol);
}

test "fromVectors rotates from onto to, including the antiparallel case" {
    const from = math.simd_float4.x_axis();
    const to = math.simd_float4.y_axis();
    try expectVecApprox(q_90z, math.quaternion.fromVectors(from, to), tol);

    const opposite = math.quaternion.fromVectors(from, .{ -1, 0, 0, 0 });
    try expectVecApprox(.{ 0, 1, 0, 0 }, opposite, tol);
}

test "fromUnitVectors matches fromVectors for already-unit inputs" {
    const from = math.simd_float4.x_axis();
    const to = math.simd_float4.y_axis();
    try expectVecApprox(q_90z, math.quaternion.fromUnitVectors(from, to), tol);

    const opposite = math.quaternion.fromUnitVectors(from, .{ -1, 0, 0, 0 });
    try expectVecApprox(.{ 0, 1, 0, 0 }, opposite, tol);
}

test "fromEuler: pure yaw is a rotation about y" {
    const q = math.quaternion.fromEuler(.{ std.math.pi / 2.0, 0, 0, 0 });
    try expectVecApprox(.{ 0, 0.70710678, 0, 0.70710678 }, q, tol);
}

test "euler round trip" {
    const ypr: math.SimdFloat4 = .{ 0.3, -0.2, 0.15, 0 };
    const q = math.quaternion.fromEuler(ypr);
    const back = math.quaternion.toEuler(q);
    try std.testing.expectApproxEqAbs(ypr[0], back[0], 1e-4);
    try std.testing.expectApproxEqAbs(ypr[1], back[1], 1e-4);
    try std.testing.expectApproxEqAbs(ypr[2], back[2], 1e-4);
}

// Matrices.

fn mat4(cols: [4][4]f32) math.Mat4 {
    return .{ .m = cols[0] ++ cols[1] ++ cols[2] ++ cols[3] };
}

test "mat4.transpose swaps rows and columns" {
    const m = mat4(.{ .{ 1, 2, 3, 4 }, .{ 5, 6, 7, 8 }, .{ 9, 10, 11, 12 }, .{ 13, 14, 15, 16 } });
    const t = math.mat4.transpose(m);
    try std.testing.expectEqualSlices(f32, &.{
        1, 5, 9,  13,
        2, 6, 10, 14,
        3, 7, 11, 15,
        4, 8, 12, 16,
    }, &t.m);
}

test "mat4.columnMultiply scales each column by v" {
    const result = math.mat4.columnMultiply(zozz.mat4_identity, .{ 2, 3, 4, 5 });
    try std.testing.expectEqualSlices(f32, &.{
        2, 0, 0, 0,
        0, 3, 0, 0,
        0, 0, 4, 0,
        0, 0, 0, 5,
    }, &result.m);
}

test "mat4.scaling builds a diagonal scale matrix" {
    const result = math.mat4.scaling(.{ 2, 3, 4, 0 });
    try std.testing.expectEqualSlices(f32, &.{
        2, 0, 0, 0,
        0, 3, 0, 0,
        0, 0, 4, 0,
        0, 0, 0, 1,
    }, &result.m);
}

test "mat4.translate moves the last column" {
    const result = math.mat4.translate(zozz.mat4_identity, .{ 5, 6, 7, 0 });
    try std.testing.expectEqualSlices(f32, &.{
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        5, 6, 7, 1,
    }, &result.m);
}

test "mat4.transformPoint applies translation, mat4.transformVector does not" {
    const m = math.mat4.translate(zozz.mat4_identity, .{ 5, 6, 7, 0 });
    try expectVecApprox(.{ 6, 7, 8, 1 }, math.mat4.transformPoint(m, .{ 1, 1, 1, 0 }), tol);
    try expectVecApprox(.{ 1, 1, 1, 0 }, math.mat4.transformVector(m, .{ 1, 1, 1, 0 }), tol);
}

test "mat4.isOrthogonal" {
    try std.testing.expectEqual(@as(i32, -1), math.mat4.isOrthogonal(zozz.mat4_identity)[0]);

    // col2 = (0,1,1,0) is not aligned with cross(col0, col1) = (0,0,1,0).
    const skewed = mat4(.{ .{ 1, 0, 0, 0 }, .{ 0, 1, 0, 0 }, .{ 0, 1, 1, 0 }, .{ 0, 0, 0, 1 } });
    try std.testing.expectEqual(@as(i32, 0), math.mat4.isOrthogonal(skewed)[0]);
}

test "mat4.invert of a non-orthogonal (sheared) matrix" {
    // col0=(1,0,0), col1=(3,1,0) (shear), col2=(0,0,2) (non-uniform scale),
    // col3=(5,6,7) (translation). Inverse hand-derived and cross-checked by
    // multiplying the two together (see the task's implementation notes).
    const m = mat4(.{ .{ 1, 0, 0, 0 }, .{ 3, 1, 0, 0 }, .{ 0, 0, 2, 0 }, .{ 5, 6, 7, 1 } });
    const inv = math.mat4.invert(m, null);
    try std.testing.expectEqualSlices(f32, &.{
        1,  0,  0,    0,
        -3, 1,  0,    0,
        0,  0,  0.5,  0,
        13, -6, -3.5, 1,
    }, &inv.m);
}

test "mat4.invert reports a singular matrix as not invertible instead of asserting" {
    const singular = mat4(.{ .{ 1, 0, 0, 0 }, .{ 0, 1, 0, 0 }, .{ 0, 0, 0, 0 }, .{ 0, 0, 0, 1 } });
    var invertible: math.SimdInt4 = undefined;
    const result = math.mat4.invert(singular, &invertible);
    try std.testing.expectEqual(@as(i32, 0), invertible[0]);
    for (result.m) |v| try std.testing.expectApproxEqAbs(@as(f32, 0), v, tol);
}

test "mat4.fromQuaternion / mat4.toQuaternion round trip" {
    const m = math.mat4.fromQuaternion(q_90z);
    try expectVecApprox(q_90z, math.mat4.toQuaternion(m), tol);
}

test "mat4.fromAffine / mat4.toAffine round trip" {
    const translation: math.SimdFloat4 = .{ 1, 2, 3, 1 };
    const scale: math.SimdFloat4 = .{ 2, 3, 4, 1 };
    const m = math.mat4.fromAffine(translation, q_90z, scale);

    var t2: math.SimdFloat4 = undefined;
    var q2: math.SimdFloat4 = undefined;
    var s2: math.SimdFloat4 = undefined;
    try std.testing.expect(math.mat4.toAffine(m, &t2, &q2, &s2));
    try expectVecApprox(translation, t2, 1e-4);
    try expectVecApprox(q_90z, q2, 1e-4);
    try expectVecApprox(scale, s2, 1e-4);
}

// Box.

test "Box.transform" {
    const box: math.Box = .{ .min = .{ -1, -1, -1 }, .max = .{ 1, 1, 1 } };
    const m = math.mat4.translate(zozz.mat4_identity, .{ 5, 0, 0, 0 });
    const result = box.transform(m);
    try std.testing.expectApproxEqAbs(@as(f32, 4), result.min[0], tol);
    try std.testing.expectApproxEqAbs(@as(f32, -1), result.min[1], tol);
    try std.testing.expectApproxEqAbs(@as(f32, -1), result.min[2], tol);
    try std.testing.expectApproxEqAbs(@as(f32, 6), result.max[0], tol);
    try std.testing.expectApproxEqAbs(@as(f32, 1), result.max[1], tol);
    try std.testing.expectApproxEqAbs(@as(f32, 1), result.max[2], tol);
}

// The rest of the SIMD surface.

test "simd_float4 loads" {
    var f4: [4]f32 align(16) = .{ 1, 2, 3, 4 };
    try expectVecApprox(.{ 1, 2, 3, 4 }, math.simd_float4.loadPtr(&f4), tol);
    try expectVecApprox(.{ 1, 2, 3, 4 }, math.simd_float4.loadPtrU(&f4), tol);
    try expectVecApprox(.{ 5, 0, 0, 0 }, math.simd_float4.loadX(5), tol);
    try expectVecApprox(.{ 5, 5, 5, 5 }, math.simd_float4.load1(5), tol);

    var one: f32 = 9;
    try expectVecApprox(.{ 9, 0, 0, 0 }, math.simd_float4.loadXPtrU(&one), tol);
    try expectVecApprox(.{ 9, 9, 9, 9 }, math.simd_float4.load1PtrU(&one), tol);

    var two: [2]f32 = .{ 1, 2 };
    try expectVecApprox(.{ 1, 2, 0, 0 }, math.simd_float4.load2PtrU(&two), tol);
    var three: [3]f32 = .{ 1, 2, 3 };
    try expectVecApprox(.{ 1, 2, 3, 0 }, math.simd_float4.load3PtrU(&three), tol);

    try expectVecApprox(.{ 1, -2, 3, 0 }, math.simd_float4.fromInt(.{ 1, -2, 3, 0 }), tol);
}

test "simd_int4 loads, all_true/all_false, and int<->float conversion" {
    var ints4: [4]i32 align(16) = .{ 1, 2, 3, 4 };
    try std.testing.expectEqual(math.SimdInt4{ 1, 2, 3, 4 }, math.simd_int4.loadPtr(&ints4));
    try std.testing.expectEqual(math.SimdInt4{ 1, 2, 3, 4 }, math.simd_int4.loadPtrU(&ints4));
    try std.testing.expectEqual(math.SimdInt4{ -1, 0, 0, 0 }, math.simd_int4.loadX(true));
    try std.testing.expectEqual(math.SimdInt4{ 0, 0, 0, 0 }, math.simd_int4.loadX(false));
    try std.testing.expectEqual(math.SimdInt4{ -1, -1, -1, -1 }, math.simd_int4.load1(true));

    var one: i32 align(16) = 7;
    try std.testing.expectEqual(math.SimdInt4{ 7, 0, 0, 0 }, math.simd_int4.loadXPtr(&one));
    try std.testing.expectEqual(math.SimdInt4{ 7, 7, 7, 7 }, math.simd_int4.load1Ptr(&one));
    var two: [2]i32 align(16) = .{ 5, 6 };
    try std.testing.expectEqual(math.SimdInt4{ 5, 6, 0, 0 }, math.simd_int4.load2Ptr(&two));
    var three: [3]i32 align(16) = .{ 5, 6, 7 };
    try std.testing.expectEqual(math.SimdInt4{ 5, 6, 7, 0 }, math.simd_int4.load3Ptr(&three));

    try std.testing.expectEqual(math.SimdInt4{ -1, -1, -1, -1 }, math.simd_int4.all_true());
    try std.testing.expectEqual(math.SimdInt4{ 0, 0, 0, 0 }, math.simd_int4.all_false());

    // Values away from an exact .5 boundary: @round's away-from-zero tie
    // break vs. SSE's default round-to-nearest-even only differs exactly at
    // the boundary, which this is deliberately not testing (see math.zig).
    try std.testing.expectEqual(math.SimdInt4{ 1, -2, 3, 4 }, math.simd_int4.fromFloatRound(.{ 1.4, -1.6, 3.2, 4.4 }));
    try std.testing.expectEqual(math.SimdInt4{ 1, -1, 3, 4 }, math.simd_int4.fromFloatTrunc(.{ 1.9, -1.9, 3.9, 4.1 }));
}

test "simd_int4 mask constants" {
    try std.testing.expectEqual(math.SimdInt4{ -1, -1, -1, 0 }, math.simd_int4.mask_fff0());
    try std.testing.expectEqual(math.SimdInt4{ -1, 0, 0, 0 }, math.simd_int4.mask_f000());
    try std.testing.expectEqual(math.SimdInt4{ 0, -1, 0, 0 }, math.simd_int4.mask_0f00());
    try std.testing.expectEqual(math.SimdInt4{ 0, 0, -1, 0 }, math.simd_int4.mask_00f0());
    try std.testing.expectEqual(math.SimdInt4{ 0, 0, 0, -1 }, math.simd_int4.mask_000f());
    try std.testing.expectEqual(math.SimdInt4{ -1, -1, -1, -1 }, math.simd_int4.mask_ffff());
    try std.testing.expectEqual(math.SimdInt4{ 0, 0, 0, 0 }, math.simd_int4.mask_0000());
    try std.testing.expectEqual(@as(i32, std.math.minInt(i32)), math.simd_int4.mask_sign()[0]);
    try std.testing.expectEqual(@as(i32, 0), math.simd_int4.mask_sign_xyz()[3]);
    try std.testing.expectEqual(@as(i32, std.math.minInt(i32)), math.simd_int4.mask_sign_xyz()[0]);
    try std.testing.expectEqual(@as(i32, std.math.minInt(i32)), math.simd_int4.mask_sign_w()[3]);
    try std.testing.expectEqual(@as(i32, 0), math.simd_int4.mask_sign_w()[0]);
    try std.testing.expectEqual(@as(i32, std.math.maxInt(i32)), math.simd_int4.mask_not_sign()[0]);
}

test "y/z/w accessors, withX/withZ/withI" {
    const v: math.SimdFloat4 = .{ 1, 2, 3, 4 };
    try std.testing.expectEqual(@as(f32, 2), math.simd_float4.y(v));
    try std.testing.expectEqual(@as(f32, 3), math.simd_float4.z(v));
    try std.testing.expectEqual(@as(f32, 4), math.simd_float4.w(v));
    try expectVecApprox(.{ 9, 2, 3, 4 }, math.simd_float4.withX(v, .{ 9, 0, 0, 0 }), tol);
    try expectVecApprox(.{ 1, 2, 9, 4 }, math.simd_float4.withZ(v, .{ 9, 0, 0, 0 }), tol);
    try expectVecApprox(.{ 1, 2, 9, 4 }, math.simd_float4.withI(v, .{ 9, 0, 0, 0 }, 2), tol);
    try expectVecApprox(.{ 1, 2, 3, 9 }, math.simd_float4.withI(v, .{ 9, 0, 0, 0 }, 3), tol);
}

test "storePtr family" {
    const v: math.SimdFloat4 = .{ 1, 2, 3, 4 };
    var out4: [4]f32 align(16) = undefined;
    math.simd_float4.storePtr(v, &out4);
    try std.testing.expectEqualSlices(f32, &.{ 1, 2, 3, 4 }, &out4);

    var one: f32 align(16) = undefined;
    math.simd_float4.store1Ptr(v, &one);
    try std.testing.expectEqual(@as(f32, 1), one);
    math.simd_float4.store1PtrU(v, &one);
    try std.testing.expectEqual(@as(f32, 1), one);

    var two: [2]f32 align(16) = undefined;
    math.simd_float4.store2Ptr(v, &two);
    try std.testing.expectEqualSlices(f32, &.{ 1, 2 }, &two);
    math.simd_float4.store2PtrU(v, &two);
    try std.testing.expectEqualSlices(f32, &.{ 1, 2 }, &two);

    var three: [3]f32 align(16) = undefined;
    math.simd_float4.store3Ptr(v, &three);
    try std.testing.expectEqualSlices(f32, &.{ 1, 2, 3 }, &three);
}

test "simd_float4.swizzle and simd_int4.swizzle permute lanes" {
    const v: math.SimdFloat4 = .{ 1, 2, 3, 4 };
    try expectVecApprox(.{ 4, 3, 2, 1 }, math.simd_float4.swizzle(3, 2, 1, 0, v), tol);
    try expectVecApprox(.{ 1, 1, 1, 1 }, math.simd_float4.swizzle(0, 0, 0, 0, v), tol);

    const iv: math.SimdInt4 = .{ 10, 20, 30, 40 };
    try std.testing.expectEqual(math.SimdInt4{ 40, 30, 20, 10 }, math.simd_int4.swizzle(3, 2, 1, 0, iv));
}

test "moveMask reads the sign bit of every lane" {
    try std.testing.expectEqual(@as(i32, 0), math.simd_int4.moveMask(.{ 0, 0, 0, 0 }));
    try std.testing.expectEqual(@as(i32, 0b1111), math.simd_int4.moveMask(.{ -1, -1, -1, -1 }));
    try std.testing.expectEqual(@as(i32, 0b0101), math.simd_int4.moveMask(.{ -1, 0, -1, 0 }));
    try std.testing.expectEqual(@as(i32, 0b1000), math.simd_int4.moveMask(math.simd_int4.mask_sign_w()));
}

test "areAllTrue/False and their partial-lane forms" {
    const all: math.SimdInt4 = .{ -1, -1, -1, -1 };
    const some: math.SimdInt4 = .{ -1, -1, 0, 0 };
    const none: math.SimdInt4 = .{ 0, 0, 0, 0 };

    try std.testing.expect(math.simd_int4.areAllTrue(all));
    try std.testing.expect(!math.simd_int4.areAllTrue(some));
    try std.testing.expect(math.simd_int4.areAllTrue2(some));
    try std.testing.expect(!math.simd_int4.areAllTrue3(some));
    try std.testing.expect(math.simd_int4.areAllTrue1(some));

    try std.testing.expect(math.simd_int4.areAllFalse(none));
    try std.testing.expect(!math.simd_int4.areAllFalse(some));
    try std.testing.expect(math.simd_int4.areAllFalse2(.{ 0, 0, -1, -1 }));
    try std.testing.expect(!math.simd_int4.areAllFalse3(some));
    try std.testing.expect(math.simd_int4.areAllFalse1(none));
}

test "simd_float4.transpose4x4 is its own inverse" {
    const in: [4]math.SimdFloat4 = .{
        .{ 1, 2, 3, 4 },
        .{ 5, 6, 7, 8 },
        .{ 9, 10, 11, 12 },
        .{ 13, 14, 15, 16 },
    };
    const t = math.simd_float4.transpose4x4(in);
    try expectVecApprox(.{ 1, 5, 9, 13 }, t[0], tol);
    try expectVecApprox(.{ 2, 6, 10, 14 }, t[1], tol);
    try expectVecApprox(.{ 4, 8, 12, 16 }, t[3], tol);

    const back = math.simd_float4.transpose4x4(t);
    for (in, back) |a, b| try expectVecApprox(a, b, tol);
}

test "transpose4x1/1x4, 4x2/2x4, 4x3/3x4 round trip their populated lanes" {
    const in4: [4]math.SimdFloat4 = .{ .{ 1, 0, 0, 0 }, .{ 2, 0, 0, 0 }, .{ 3, 0, 0, 0 }, .{ 4, 0, 0, 0 } };
    const one = math.simd_float4.transpose4x1(in4);
    try expectVecApprox(.{ 1, 2, 3, 4 }, one[0], tol);
    const back4 = math.simd_float4.transpose1x4(one);
    for (in4, back4) |a, b| try expectVecApprox(a, b, tol);

    const in4b: [4]math.SimdFloat4 = .{ .{ 1, 10, 0, 0 }, .{ 2, 20, 0, 0 }, .{ 3, 30, 0, 0 }, .{ 4, 40, 0, 0 } };
    const two = math.simd_float4.transpose4x2(in4b);
    try expectVecApprox(.{ 1, 2, 3, 4 }, two[0], tol);
    try expectVecApprox(.{ 10, 20, 30, 40 }, two[1], tol);
    const back4b = math.simd_float4.transpose2x4(two);
    for (in4b, back4b) |a, b| try expectVecApprox(a, b, tol);

    const in4c: [4]math.SimdFloat4 = .{ .{ 1, 10, 100, 0 }, .{ 2, 20, 200, 0 }, .{ 3, 30, 300, 0 }, .{ 4, 40, 400, 0 } };
    const three = math.simd_float4.transpose4x3(in4c);
    try expectVecApprox(.{ 100, 200, 300, 400 }, three[2], tol);
    const back4c = math.simd_float4.transpose3x4(three);
    for (in4c, back4c) |a, b| try expectVecApprox(a, b, tol);
}

test "transpose16x16 is four scattered transpose4x4 calls" {
    var in: [16]math.SimdFloat4 = undefined;
    for (0..16) |i| {
        const base: f32 = @floatFromInt(i * 4);
        in[i] = .{ base, base + 1, base + 2, base + 3 };
    }
    const out = math.simd_float4.transpose16x16(in);

    // Per simd_math_sse-inl.h: group g (in[4g..4g+4)) transposed via
    // transpose4x4 lands at out[g], out[g+4], out[g+8], out[g+12].
    inline for (0..4) |g| {
        const block = math.simd_float4.transpose4x4(.{ in[g * 4 + 0], in[g * 4 + 1], in[g * 4 + 2], in[g * 4 + 3] });
        inline for (0..4) |k| try expectVecApprox(block[k], out[g + k * 4], tol);
    }

    // A couple of hand-computed spot checks, independent of the formula above.
    try expectVecApprox(.{ 0, 4, 8, 12 }, out[0], tol);
    try expectVecApprox(.{ 51, 55, 59, 63 }, out[15], tol);
}

test "cmpEq, cmpGe, cmpGt, cmpLe" {
    const a: math.SimdFloat4 = .{ 1, 2, 3, 4 };
    const b: math.SimdFloat4 = .{ 4, 2, 1, 4 };
    try std.testing.expectEqual(math.SimdInt4{ 0, -1, 0, -1 }, math.simd_int4.cmpEq(a, b));
    try std.testing.expectEqual(math.SimdInt4{ 0, -1, -1, -1 }, math.simd_int4.cmpGe(a, b));
    try std.testing.expectEqual(math.SimdInt4{ 0, 0, -1, 0 }, math.simd_int4.cmpGt(a, b));
    try std.testing.expectEqual(math.SimdInt4{ -1, -1, 0, -1 }, math.simd_int4.cmpLe(a, b));
}

test "not, andNot" {
    try std.testing.expectEqual(math.SimdInt4{ 0, -1, 0, -1 }, math.simd_int4.not(.{ -1, 0, -1, 0 }));
    try std.testing.expectEqual(
        math.SimdInt4{ -1, 0, 0, 0 },
        math.simd_int4.andNot(.{ -1, -1, 0, 0 }, .{ 0, -1, -1, 0 }),
    );
}

test "sign and abs" {
    try std.testing.expectEqual(@as(i32, std.math.minInt(i32)), math.simd_int4.sign(.{ -1, 1, -0.0, 0 })[0]);
    try std.testing.expectEqual(@as(i32, 0), math.simd_int4.sign(.{ -1, 1, -0.0, 0 })[1]);
    try expectVecApprox(.{ 1, 1, 0, 2.5 }, math.simd_float4.abs(.{ -1, 1, 0, -2.5 }), tol);
}

test "min0, max0" {
    try expectVecApprox(.{ -1, 0, -3, 0 }, math.simd_float4.min0(.{ -1, 2, -3, 4 }), tol);
    try expectVecApprox(.{ 0, 2, 0, 4 }, math.simd_float4.max0(.{ -1, 2, -3, 4 }), tol);
}

test "mSub, nMSub, divX, dot2" {
    const a: math.SimdFloat4 = .{ 1, 2, 3, 4 };
    const b: math.SimdFloat4 = .{ 5, 6, 7, 8 };
    const c: math.SimdFloat4 = .{ 1, 1, 1, 1 };
    try expectVecApprox(.{ 4, 11, 20, 31 }, math.simd_float4.mSub(a, b, c), tol);
    try expectVecApprox(.{ -6, -13, -22, -33 }, math.simd_float4.nMSub(a, b, c), tol);
    try expectVecApprox(.{ 0.2, 2, 3, 4 }, math.simd_float4.divX(a, b), tol);
    try std.testing.expectApproxEqAbs(@as(f32, 17), math.simd_float4.dot2(a, b)[0], tol);
}

test "rcpEst family and rSqrtEst family are exact" {
    const v: math.SimdFloat4 = .{ 2, 4, 5, 8 };
    try expectVecApprox(.{ 0.5, 0.25, 0.2, 0.125 }, math.simd_float4.rcpEst(v), tol);
    try expectVecApprox(.{ 0.5, 0.25, 0.2, 0.125 }, math.simd_float4.rcpEstNR(v), tol);
    try expectVecApprox(.{ 0.5, 4, 5, 8 }, math.simd_float4.rcpEstX(v), tol);
    try expectVecApprox(.{ 0.5, 4, 5, 8 }, math.simd_float4.rcpEstXNR(v), tol);

    const sq: math.SimdFloat4 = .{ 4, 9, 16, 25 };
    try expectVecApprox(.{ 0.5, 1.0 / 3.0, 0.25, 0.2 }, math.simd_float4.rSqrtEst(sq), 1e-4);
    try expectVecApprox(.{ 0.5, 9, 16, 25 }, math.simd_float4.rSqrtEstX(sq), 1e-4);
    try expectVecApprox(.{ 0.5, 9, 16, 25 }, math.simd_float4.rSqrtEstXNR(sq), 1e-4);
}

test "length2, length2Sqr, normalize2 keeps z/w" {
    try std.testing.expectApproxEqAbs(@as(f32, 5), math.simd_float4.length2(.{ 3, 4, 99, 0 })[0], tol);
    try std.testing.expectApproxEqAbs(@as(f32, 25), math.simd_float4.length2Sqr(.{ 3, 4, 99, 0 })[0], tol);
    try expectVecApprox(.{ 0.6, 0.8, 99, 7 }, math.simd_float4.normalize2(.{ 3, 4, 99, 7 }), tol);
    try expectVecApprox(.{ 0.6, 0.8, 99, 7 }, math.simd_float4.normalizeEst2(.{ 3, 4, 99, 7 }), tol);
}

test "normalizeSafe2/Est2: z, w always come from v" {
    const safe: math.SimdFloat4 = .{ 1, 0, 0, 0 };
    try expectVecApprox(.{ 1, 0, 5, 6 }, math.simd_float4.normalizeSafe2(.{ 0, 0, 5, 6 }, safe), tol);
    try expectVecApprox(.{ 1, 0, 5, 6 }, math.simd_float4.normalizeSafeEst2(.{ 0, 0, 5, 6 }, safe), tol);
    try expectVecApprox(.{ 0.6, 0.8, 99, 7 }, math.simd_float4.normalizeSafe2(.{ 3, 4, 99, 7 }, safe), tol);
}

test "isNormalized2/Est2" {
    try std.testing.expectEqual(@as(i32, -1), math.simd_float4.isNormalized2(.{ 0.6, 0.8, 0, 0 })[0]);
    try std.testing.expectEqual(@as(i32, 0), math.simd_float4.isNormalized2(.{ 1, 1, 0, 0 })[0]);
    try std.testing.expectEqual(@as(i32, -1), math.simd_float4.isNormalizedEst2(.{ 0.6, 0.8, 0, 0 })[0]);
}

test "sin, cos, aSin, aCos forward to std.math per component" {
    const v: math.SimdFloat4 = .{ 0, std.math.pi / 6.0, std.math.pi / 4.0, std.math.pi / 3.0 };
    try expectVecApprox(.{ 0, 0.5, 0.70710678, 0.8660254 }, math.simd_float4.sin(v), tol);
    try expectVecApprox(.{ 1, 0.8660254, 0.70710678, 0.5 }, math.simd_float4.cos(v), tol);
    try expectVecApprox(v, math.simd_float4.aSin(.{ 0, 0.5, 0.70710678, 0.8660254 }), 1e-4);
    try expectVecApprox(
        .{ std.math.pi / 2.0, std.math.pi / 3.0, std.math.pi / 4.0, std.math.pi / 6.0 },
        math.simd_float4.aCos(.{ 0, 0.5, 0.70710678, 0.8660254 }),
        1e-4,
    );
}

test "tan, aTan, and their X-only forms" {
    try expectVecApprox(.{ 0, 1, -1, 0.5773503 }, math.simd_float4.tan(.{ 0, std.math.pi / 4.0, -std.math.pi / 4.0, std.math.pi / 6.0 }), 1e-4);
    try expectVecApprox(.{ 1, 7, 8, 9 }, math.simd_float4.tanX(.{ std.math.pi / 4.0, 7, 8, 9 }), 1e-4);

    try expectVecApprox(.{ 0, std.math.pi / 4.0, -std.math.pi / 4.0, std.math.pi / 6.0 }, math.simd_float4.aTan(.{ 0, 1, -1, 0.5773503 }), 1e-4);
    try expectVecApprox(.{ std.math.pi / 4.0, 7, 8, 9 }, math.simd_float4.aTanX(.{ 1, 7, 8, 9 }), 1e-4);
    try expectVecApprox(.{ std.math.pi / 6.0, 7, 8, 9 }, math.simd_float4.aSinX(.{ 0.5, 7, 8, 9 }), 1e-4);
}

test "shiftL, shiftR (arithmetic), shiftRu (logical)" {
    try std.testing.expectEqual(math.SimdInt4{ 4, 8, -4, 0 }, math.simd_int4.shiftL(.{ 1, 2, -1, 0 }, 2));
    try std.testing.expectEqual(math.SimdInt4{ 1, -1, 0, 0 }, math.simd_int4.shiftR(.{ 4, -4, 1, 0 }, 2));
    // Logical shift of -4 (0xFFFFFFFC) right by 2 zero-fills into a large positive value.
    try std.testing.expectEqual(@as(i32, 1), math.simd_int4.shiftRu(.{ 4, -4, 0, 0 }, 2)[0]);
    try std.testing.expect(math.simd_int4.shiftRu(.{ 4, -4, 0, 0 }, 2)[1] > 0);
}

test "simdImplementationName is non-empty and not ozz's own SSE string" {
    const name = math.simdImplementationName();
    try std.testing.expect(name.len > 0);
    try std.testing.expect(!std.mem.eql(u8, name, "SSE2"));
}

// raw_animation_utils.h interpolation.

test "lerpTranslation and lerpScale are plain per-component lerps" {
    try std.testing.expectEqualSlices(f32, &.{ 5, 10, 15 }, &math.lerpTranslation(.{ 0, 0, 0 }, .{ 10, 20, 30 }, 0.5));
    try std.testing.expectEqualSlices(f32, &.{ 2, 4, 6 }, &math.lerpScale(.{ 1, 2, 3 }, .{ 3, 6, 9 }, 0.5));
}

test "lerpRotation matches plain nlerp when inputs are on the same hemisphere" {
    try expectVecApprox(math.quaternion.nlerp(q_identity, q_90z, 0.5), math.lerpRotation(q_identity, q_90z, 0.5), tol);
}

test "lerpRotation takes the short arc when inputs are more than 180 degrees apart" {
    // b is a 270 degree rotation about z: the "long way" spelling of what is
    // really a -90 degree (short way) rotation. dot(a, b) < 0 is exactly the
    // condition lerpRotation's hemisphere check is supposed to catch.
    const a = q_identity;
    const b = math.quaternion.fromAxisAngle(math.simd_float4.z_axis(), 3.0 * std.math.pi / 2.0);
    const dot = a[0] * b[0] + a[1] * b[1] + a[2] * b[2] + a[3] * b[3];
    try std.testing.expect(dot < 0.0);

    const result = math.lerpRotation(a, b, 0.5);
    // Short arc (halfway to a -90 degree rotation, i.e. -45 degrees about z):
    // z negative, w large and positive. A plain nlerp(a, b, 0.5) with no
    // hemisphere check would instead give z positive (~0.9239) and w small
    // (~0.3827) -- the long way around.
    try expectVecApprox(.{ 0, 0, -0.38268343, 0.92387953 }, result, tol);
}

// platform.h.

test "pointerStride offsets by bytes, not elements" {
    var buf: [8]u32 align(4) = .{ 0, 1, 2, 3, 4, 5, 6, 7 };
    const p: *u32 = &buf[0];
    const strided = math.pointerStride(p, @sizeOf(u32) * 3);
    try std.testing.expectEqual(@as(u32, 3), strided.*);
}

test "strmatch: exact, ?, and * per platform.h's contract" {
    try std.testing.expect(math.strmatch("", ""));
    try std.testing.expect(!math.strmatch("a", ""));
    try std.testing.expect(!math.strmatch("", "a"));
    try std.testing.expect(math.strmatch("abc", "abc"));
    try std.testing.expect(!math.strmatch("abc", "abd"));
    try std.testing.expect(!math.strmatch("ab", "abc"));

    // ? matches exactly one character, never an empty string.
    try std.testing.expect(math.strmatch("a", "?"));
    try std.testing.expect(!math.strmatch("", "?"));
    try std.testing.expect(math.strmatch("abc", "a?c"));
    try std.testing.expect(!math.strmatch("ac", "a?c"));

    // * matches any string, including an empty one.
    try std.testing.expect(math.strmatch("", "*"));
    try std.testing.expect(math.strmatch("anything", "*"));
    try std.testing.expect(math.strmatch("abc", "*c"));
    try std.testing.expect(math.strmatch("abc", "a*"));
    try std.testing.expect(math.strmatch("abc", "*"));
    try std.testing.expect(math.strmatch("abcabc", "a*c"));
    try std.testing.expect(math.strmatch("skeleton.ozz", "*.ozz"));
    try std.testing.expect(!math.strmatch("skeleton.ozza", "*.ozz"));

    // Backtracking: greedy * followed by a literal that also appears earlier.
    try std.testing.expect(math.strmatch("aXbXc", "a*Xc"));
    try std.testing.expect(!math.strmatch("aXbXd", "a*Xc"));

    // Multiple wildcards.
    try std.testing.expect(math.strmatch("hello_world.ozz", "*_*.ozz"));
    try std.testing.expect(math.strmatch("abc", "?*?"));
    try std.testing.expect(!math.strmatch("a", "?*?"));
}
