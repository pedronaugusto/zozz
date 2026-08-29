//! The plain-data types that cross the boundary, plus a pure-Zig port of
//! ozz's public math API: SimdFloat4/SimdInt4 lane ops, vector ops,
//! quaternions, 4x4 matrices, axis-aligned boxes, the raw-animation
//! interpolation helpers, and the platform.h pointer/wildcard utilities.
//!
//! `Transform` and `Mat4` are the C types re-exported, not copies: a wrapper
//! struct would mean a conversion on every joint of every frame for no
//! benefit. Everything below operates on them, or on bare SimdFloat4/SimdInt4
//! vectors, directly — matching ozz::math function-for-function so this
//! never costs a foreign call per arithmetic op.

const std = @import("std");
const c = @import("c.zig");

/// One joint's local-space transform.
///
/// `rotation` is a quaternion in (x, y, z, w) order — w LAST. Consumers whose
/// own quaternion type is w-first must reorder; there is no silent conversion
/// here to get wrong.
pub const Transform = c.Transform;

/// A column-major 4x4 matrix: `m[0..4]` is the first column.
///
/// 16-byte aligned to match ozz's SIMD stores. Arrays of these must start on a
/// 16-byte boundary — `localToModel` rejects a misaligned destination.
pub const Mat4 = c.Float4x4;

pub const transform_identity: Transform = .{
    .translation = .{ 0, 0, 0 },
    .rotation = .{ 0, 0, 0, 1 },
    .scale = .{ 1, 1, 1 },
};

pub const mat4_identity: Mat4 = .{ .m = .{
    1, 0, 0, 0,
    0, 1, 0, 0,
    0, 0, 1, 0,
    0, 0, 0, 1,
} };

test "identity constants are what their names claim" {
    try std.testing.expectEqual(@as(f32, 1), transform_identity.rotation[3]);
    try std.testing.expectEqual(@as(f32, 1), transform_identity.scale[0]);
    try std.testing.expectEqual(@as(f32, 1), mat4_identity.m[0]);
    try std.testing.expectEqual(@as(f32, 0), mat4_identity.m[1]);
    try std.testing.expectEqual(@as(f32, 1), mat4_identity.m[15]);
}

// ozz::math port. Lanes are (x, y, z, w); a quaternion is a SimdFloat4 in
// that same order, matching `Transform.rotation`.

/// Mirrors `ozz::math::SimdFloat4`.
pub const SimdFloat4 = @Vector(4, f32);

/// Mirrors `ozz::math::SimdInt4`. Boolean results use ozz's convention:
/// all bits set (-1) for true, all clear (0) for false.
pub const SimdInt4 = @Vector(4, i32);

const k_normalization_tolerance_sq: f32 = 1e-6;
const k_normalization_tolerance_est_sq: f32 = 2e-3;
const k_orthogonalisation_tolerance_sq: f32 = 1e-16;
const k_pi_2: f32 = 1.5707963267948966192313216916398;

/// Mirrors ozz's `simd_float4::` constant functions, plus the lane, compare,
/// load/store, swizzle, transpose, vector, and trig operations ozz keeps at
/// `ozz::math::` scope — grouped here by the type they operate on instead.
pub const simd_float4 = struct {
    pub fn zero() SimdFloat4 {
        return .{ 0, 0, 0, 0 };
    }
    pub fn one() SimdFloat4 {
        return .{ 1, 1, 1, 1 };
    }
    pub fn x_axis() SimdFloat4 {
        return .{ 1, 0, 0, 0 };
    }
    pub fn y_axis() SimdFloat4 {
        return .{ 0, 1, 0, 0 };
    }
    pub fn z_axis() SimdFloat4 {
        return .{ 0, 0, 1, 0 };
    }
    pub fn w_axis() SimdFloat4 {
        return .{ 0, 0, 0, 1 };
    }

    pub fn loadX(val: f32) SimdFloat4 {
        return .{ val, 0, 0, 0 };
    }
    pub fn load1(val: f32) SimdFloat4 {
        return .{ val, val, val, val };
    }
    /// 16-byte aligned load of 4 floats.
    pub fn loadPtr(f: *align(16) const [4]f32) SimdFloat4 {
        return f.*;
    }
    pub fn loadPtrU(f: *const [4]f32) SimdFloat4 {
        return f.*;
    }
    pub fn loadXPtrU(f: *const f32) SimdFloat4 {
        return .{ f.*, 0, 0, 0 };
    }
    pub fn load1PtrU(f: *const f32) SimdFloat4 {
        return .{ f.*, f.*, f.*, f.* };
    }
    pub fn load2PtrU(f: *const [2]f32) SimdFloat4 {
        return .{ f[0], f[1], 0, 0 };
    }
    pub fn load3PtrU(f: *const [3]f32) SimdFloat4 {
        return .{ f[0], f[1], f[2], 0 };
    }

    pub fn fromInt(i: SimdInt4) SimdFloat4 {
        return .{
            @floatFromInt(i[0]),
            @floatFromInt(i[1]),
            @floatFromInt(i[2]),
            @floatFromInt(i[3]),
        };
    }

    // Lane ops.

    /// Per-lane: `mask[i] != 0 ? t[i] : f[i]`.
    pub fn select(mask: SimdInt4, t: SimdFloat4, f: SimdFloat4) SimdFloat4 {
        return @select(f32, mask != @as(SimdInt4, @splat(0)), t, f);
    }

    pub fn splatX(v: SimdFloat4) SimdFloat4 {
        return @splat(v[0]);
    }
    pub fn splatY(v: SimdFloat4) SimdFloat4 {
        return @splat(v[1]);
    }
    pub fn splatZ(v: SimdFloat4) SimdFloat4 {
        return @splat(v[2]);
    }
    pub fn splatW(v: SimdFloat4) SimdFloat4 {
        return @splat(v[3]);
    }

    pub fn x(v: SimdFloat4) f32 {
        return v[0];
    }
    pub fn y(v: SimdFloat4) f32 {
        return v[1];
    }
    pub fn z(v: SimdFloat4) f32 {
        return v[2];
    }
    pub fn w(v: SimdFloat4) f32 {
        return v[3];
    }

    /// Replaces lane x with `f`'s lane x; other lanes pass through from `v`.
    pub fn withX(v: SimdFloat4, f: SimdFloat4) SimdFloat4 {
        return .{ f[0], v[1], v[2], v[3] };
    }
    /// Replaces lane y with `f`'s lane x; other lanes pass through from `v`.
    pub fn withY(v: SimdFloat4, f: SimdFloat4) SimdFloat4 {
        return .{ v[0], f[0], v[2], v[3] };
    }
    /// Replaces lane z with `f`'s lane x; other lanes pass through from `v`.
    pub fn withZ(v: SimdFloat4, f: SimdFloat4) SimdFloat4 {
        return .{ v[0], v[1], f[0], v[3] };
    }
    /// Replaces lane w with `f`'s lane x; other lanes pass through from `v`.
    pub fn withW(v: SimdFloat4, f: SimdFloat4) SimdFloat4 {
        return .{ v[0], v[1], v[2], f[0] };
    }
    /// Replaces lane `i` (0-3) with `f`'s lane x; other lanes pass through.
    pub fn withI(v: SimdFloat4, f: SimdFloat4, i: i32) SimdFloat4 {
        std.debug.assert(i >= 0 and i <= 3);
        var arr: [4]f32 = v;
        arr[@intCast(i)] = f[0];
        return arr;
    }

    /// Lane 0 is the sum; lanes 1-3 mirror ozz's own reference backend rather
    /// than an invented filler, since ozz documents them as unspecified.
    pub fn hAdd2(v: SimdFloat4) SimdFloat4 {
        return .{ v[0] + v[1], v[1], v[2], v[3] };
    }
    pub fn hAdd3(v: SimdFloat4) SimdFloat4 {
        return .{ v[0] + v[1] + v[2], v[1], v[2], v[3] };
    }
    pub fn hAdd4(v: SimdFloat4) SimdFloat4 {
        return .{ v[0] + v[1] + v[2] + v[3], v[0], v[0], v[0] };
    }

    pub fn mAdd(a: SimdFloat4, b: SimdFloat4, add: SimdFloat4) SimdFloat4 {
        return a * b + add;
    }
    pub fn nMAdd(a: SimdFloat4, b: SimdFloat4, add: SimdFloat4) SimdFloat4 {
        return add - a * b;
    }
    pub fn mSub(a: SimdFloat4, b: SimdFloat4, add: SimdFloat4) SimdFloat4 {
        return a * b - add;
    }
    /// `v = -(a*b) - add`, matching simd_math_sse-inl.h's `OZZ_NMSUB` macro; the
    /// header's own doc comment for this one is copy-pasted from MAdd and does
    /// not match the implementation.
    pub fn nMSub(a: SimdFloat4, b: SimdFloat4, add: SimdFloat4) SimdFloat4 {
        return -(a * b + add);
    }
    pub fn divX(a: SimdFloat4, b: SimdFloat4) SimdFloat4 {
        return .{ a[0] / b[0], a[1], a[2], a[3] };
    }

    pub fn sqrt(v: SimdFloat4) SimdFloat4 {
        return @sqrt(v);
    }
    pub fn sqrtX(v: SimdFloat4) SimdFloat4 {
        return .{ @sqrt(v[0]), v[1], v[2], v[3] };
    }

    /// ozz computes this as `_mm_rsqrt_ps` plus one Newton-Raphson step. Zig has
    /// no rsqrt-estimate builtin, so this is the exact reciprocal square root via
    /// `@sqrt` instead — kept under ozz's name for API parity, not aliased.
    pub fn rSqrtEstNR(v: SimdFloat4) SimdFloat4 {
        return @as(SimdFloat4, @splat(1.0)) / @sqrt(v);
    }
    /// See `rSqrtEstNR` above: no estimate builtin in Zig, exact via `@sqrt`.
    pub fn rSqrtEst(v: SimdFloat4) SimdFloat4 {
        return @as(SimdFloat4, @splat(1.0)) / @sqrt(v);
    }
    /// See `rSqrtEstNR`. Lane 0 only, other lanes pass through from `v`.
    pub fn rSqrtEstX(v: SimdFloat4) SimdFloat4 {
        return .{ 1.0 / @sqrt(v[0]), v[1], v[2], v[3] };
    }
    /// See `rSqrtEstX`; already exact, nothing left for the NR step to refine.
    pub fn rSqrtEstXNR(v: SimdFloat4) SimdFloat4 {
        return .{ 1.0 / @sqrt(v[0]), v[1], v[2], v[3] };
    }

    /// No reciprocal-estimate builtin in Zig; this is the exact per-component
    /// reciprocal.
    pub fn rcpEst(v: SimdFloat4) SimdFloat4 {
        return @as(SimdFloat4, @splat(1.0)) / v;
    }
    /// See `rcpEst`: already exact, so ozz's extra Newton-Raphson step here has
    /// nothing left to refine.
    pub fn rcpEstNR(v: SimdFloat4) SimdFloat4 {
        return @as(SimdFloat4, @splat(1.0)) / v;
    }
    /// See `rcpEst`. Lane 0 only, other lanes pass through from `v`.
    pub fn rcpEstX(v: SimdFloat4) SimdFloat4 {
        return .{ 1.0 / v[0], v[1], v[2], v[3] };
    }
    /// See `rcpEstNR` and `rcpEstX`.
    pub fn rcpEstXNR(v: SimdFloat4) SimdFloat4 {
        return .{ 1.0 / v[0], v[1], v[2], v[3] };
    }

    pub fn abs(v: SimdFloat4) SimdFloat4 {
        return @abs(v);
    }
    // ozz's header declares the float min-vs-zero overload as `Min(SimdFloat4)`,
    // but simd_math_sse-inl.h implements (and everything actually calls) it as
    // `Min0` — the working name, used here.
    pub fn min0(v: SimdFloat4) SimdFloat4 {
        return @min(v, @as(SimdFloat4, @splat(0)));
    }
    pub fn max0(v: SimdFloat4) SimdFloat4 {
        return @max(v, @as(SimdFloat4, @splat(0)));
    }

    pub fn storePtrU(v: SimdFloat4, out: *[4]f32) void {
        out.* = v;
    }
    pub fn store3PtrU(v: SimdFloat4, out: *[3]f32) void {
        out.* = .{ v[0], v[1], v[2] };
    }
    pub fn storePtr(v: SimdFloat4, out: *align(16) [4]f32) void {
        out.* = v;
    }
    pub fn store1Ptr(v: SimdFloat4, out: *align(16) f32) void {
        out.* = v[0];
    }
    pub fn store1PtrU(v: SimdFloat4, out: *f32) void {
        out.* = v[0];
    }
    pub fn store2Ptr(v: SimdFloat4, out: *align(16) [2]f32) void {
        out.* = .{ v[0], v[1] };
    }
    pub fn store2PtrU(v: SimdFloat4, out: *[2]f32) void {
        out.* = .{ v[0], v[1] };
    }
    pub fn store3Ptr(v: SimdFloat4, out: *align(16) [3]f32) void {
        out.* = .{ v[0], v[1], v[2] };
    }

    /// ozz overloads `Swizzle` for both SimdFloat4 and SimdInt4; the
    /// `simd_int4` namespace holds the int one (see `simd_int4.swizzle`). Lane
    /// indices are comptime, like ozz's template parameters.
    pub fn swizzle(comptime lx: u2, comptime ly: u2, comptime lz: u2, comptime lw: u2, v: SimdFloat4) SimdFloat4 {
        const mask = @Vector(4, i32){ @intCast(lx), @intCast(ly), @intCast(lz), @intCast(lw) };
        return @shuffle(f32, v, v, mask);
    }

    pub fn transpose4x1(in: [4]SimdFloat4) [1]SimdFloat4 {
        return .{.{ in[0][0], in[1][0], in[2][0], in[3][0] }};
    }
    pub fn transpose1x4(in: [1]SimdFloat4) [4]SimdFloat4 {
        return .{
            .{ in[0][0], 0, 0, 0 },
            .{ in[0][1], 0, 0, 0 },
            .{ in[0][2], 0, 0, 0 },
            .{ in[0][3], 0, 0, 0 },
        };
    }
    pub fn transpose4x2(in: [4]SimdFloat4) [2]SimdFloat4 {
        return .{
            .{ in[0][0], in[1][0], in[2][0], in[3][0] },
            .{ in[0][1], in[1][1], in[2][1], in[3][1] },
        };
    }
    pub fn transpose2x4(in: [2]SimdFloat4) [4]SimdFloat4 {
        return .{
            .{ in[0][0], in[1][0], 0, 0 },
            .{ in[0][1], in[1][1], 0, 0 },
            .{ in[0][2], in[1][2], 0, 0 },
            .{ in[0][3], in[1][3], 0, 0 },
        };
    }
    pub fn transpose4x3(in: [4]SimdFloat4) [3]SimdFloat4 {
        return .{
            .{ in[0][0], in[1][0], in[2][0], in[3][0] },
            .{ in[0][1], in[1][1], in[2][1], in[3][1] },
            .{ in[0][2], in[1][2], in[2][2], in[3][2] },
        };
    }
    pub fn transpose3x4(in: [3]SimdFloat4) [4]SimdFloat4 {
        return .{
            .{ in[0][0], in[1][0], in[2][0], 0 },
            .{ in[0][1], in[1][1], in[2][1], 0 },
            .{ in[0][2], in[1][2], in[2][2], 0 },
            .{ in[0][3], in[1][3], in[2][3], 0 },
        };
    }
    pub fn transpose4x4(in: [4]SimdFloat4) [4]SimdFloat4 {
        return .{
            .{ in[0][0], in[1][0], in[2][0], in[3][0] },
            .{ in[0][1], in[1][1], in[2][1], in[3][1] },
            .{ in[0][2], in[1][2], in[2][2], in[3][2] },
            .{ in[0][3], in[1][3], in[2][3], in[3][3] },
        };
    }
    /// Four independent transpose4x4 calls, scattered: group `g`'s four outputs
    /// land at `out[g]`, `out[g+4]`, `out[g+8]`, `out[g+12]`.
    pub fn transpose16x16(in: [16]SimdFloat4) [16]SimdFloat4 {
        var out: [16]SimdFloat4 = undefined;
        inline for (0..4) |g| {
            const block = transpose4x4(.{ in[g * 4 + 0], in[g * 4 + 1], in[g * 4 + 2], in[g * 4 + 3] });
            inline for (0..4) |k| out[g + k * 4] = block[k];
        }
        return out;
    }

    /// ozz forwards `Cos`/`CosX` to `std::cos`; this does the same via
    /// `std.math.cos`. Lane 0 only, other lanes pass through from `v`.
    pub fn cosX(v: SimdFloat4) SimdFloat4 {
        return .{ std.math.cos(v[0]), v[1], v[2], v[3] };
    }
    /// See `cosX`: forwards to `std.math.sin`, matching ozz's forward to libm.
    pub fn sinX(v: SimdFloat4) SimdFloat4 {
        return .{ std.math.sin(v[0]), v[1], v[2], v[3] };
    }
    /// See `cosX`: forwards to `std.math.acos`, matching ozz's forward to libm.
    pub fn aCosX(v: SimdFloat4) SimdFloat4 {
        return .{ std.math.acos(v[0]), v[1], v[2], v[3] };
    }

    /// Forwards to std.math.sin, per component.
    pub fn sin(v: SimdFloat4) SimdFloat4 {
        return .{ std.math.sin(v[0]), std.math.sin(v[1]), std.math.sin(v[2]), std.math.sin(v[3]) };
    }
    /// See `sin`: forwards to std.math.cos, per component.
    pub fn cos(v: SimdFloat4) SimdFloat4 {
        return .{ std.math.cos(v[0]), std.math.cos(v[1]), std.math.cos(v[2]), std.math.cos(v[3]) };
    }
    /// See `sin`: forwards to std.math.tan, per component.
    pub fn tan(v: SimdFloat4) SimdFloat4 {
        return .{ std.math.tan(v[0]), std.math.tan(v[1]), std.math.tan(v[2]), std.math.tan(v[3]) };
    }
    /// See `cosX`: forwards to std.math.tan, lane 0 only.
    pub fn tanX(v: SimdFloat4) SimdFloat4 {
        return .{ std.math.tan(v[0]), v[1], v[2], v[3] };
    }
    /// See `sin`: forwards to std.math.asin, per component.
    pub fn aSin(v: SimdFloat4) SimdFloat4 {
        return .{ std.math.asin(v[0]), std.math.asin(v[1]), std.math.asin(v[2]), std.math.asin(v[3]) };
    }
    /// See `cosX`: forwards to std.math.asin, lane 0 only.
    pub fn aSinX(v: SimdFloat4) SimdFloat4 {
        return .{ std.math.asin(v[0]), v[1], v[2], v[3] };
    }
    /// See `sin`: forwards to std.math.acos, per component.
    pub fn aCos(v: SimdFloat4) SimdFloat4 {
        return .{ std.math.acos(v[0]), std.math.acos(v[1]), std.math.acos(v[2]), std.math.acos(v[3]) };
    }
    /// See `sin`: forwards to std.math.atan, per component.
    pub fn aTan(v: SimdFloat4) SimdFloat4 {
        return .{ std.math.atan(v[0]), std.math.atan(v[1]), std.math.atan(v[2]), std.math.atan(v[3]) };
    }
    /// See `cosX`: forwards to std.math.atan, lane 0 only.
    pub fn aTanX(v: SimdFloat4) SimdFloat4 {
        return .{ std.math.atan(v[0]), v[1], v[2], v[3] };
    }

    // Vector ops. dot/length/... lane 0 is the meaningful result; lanes 1-3
    // mirror ozz's reference backend's filler, per the same "unspecified but
    // deterministic" contract as `hAdd2`/`hAdd3`/`hAdd4` above.

    pub fn dot2(a: SimdFloat4, b: SimdFloat4) SimdFloat4 {
        const d = a[0] * b[0] + a[1] * b[1];
        return .{ d, a[0], a[0], a[0] };
    }
    pub fn dot3(a: SimdFloat4, b: SimdFloat4) SimdFloat4 {
        const d = a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
        return .{ d, a[0], a[0], a[0] };
    }
    pub fn dot4(a: SimdFloat4, b: SimdFloat4) SimdFloat4 {
        const d = a[0] * b[0] + a[1] * b[1] + a[2] * b[2] + a[3] * b[3];
        return .{ d, a[0], a[0], a[0] };
    }

    pub fn cross3(a: SimdFloat4, b: SimdFloat4) SimdFloat4 {
        return .{
            a[1] * b[2] - a[2] * b[1],
            a[2] * b[0] - a[0] * b[2],
            a[0] * b[1] - a[1] * b[0],
            0,
        };
    }

    pub fn length2(v: SimdFloat4) SimdFloat4 {
        const sq = v[0] * v[0] + v[1] * v[1];
        return .{ @sqrt(sq), v[0], v[0], v[0] };
    }
    pub fn length2Sqr(v: SimdFloat4) SimdFloat4 {
        return .{ v[0] * v[0] + v[1] * v[1], v[0], v[0], v[0] };
    }
    pub fn length3(v: SimdFloat4) SimdFloat4 {
        const sq = v[0] * v[0] + v[1] * v[1] + v[2] * v[2];
        return .{ @sqrt(sq), v[0], v[0], v[0] };
    }
    pub fn length3Sqr(v: SimdFloat4) SimdFloat4 {
        return .{ v[0] * v[0] + v[1] * v[1] + v[2] * v[2], v[0], v[0], v[0] };
    }
    pub fn length4(v: SimdFloat4) SimdFloat4 {
        const sq = v[0] * v[0] + v[1] * v[1] + v[2] * v[2] + v[3] * v[3];
        return .{ @sqrt(sq), v[0], v[0], v[0] };
    }
    pub fn length4Sqr(v: SimdFloat4) SimdFloat4 {
        return .{ v[0] * v[0] + v[1] * v[1] + v[2] * v[2] + v[3] * v[3], v[0], v[0], v[0] };
    }

    /// z and w pass through from `v` unchanged; only x, y are normalized.
    pub fn normalize2(v: SimdFloat4) SimdFloat4 {
        const sq = v[0] * v[0] + v[1] * v[1];
        std.debug.assert(sq != 0.0);
        const inv = 1.0 / @sqrt(sq);
        return .{ v[0] * inv, v[1] * inv, v[2], v[3] };
    }
    /// Lane w passes through from `v` unchanged; only x, y, z are normalized.
    pub fn normalize3(v: SimdFloat4) SimdFloat4 {
        const sq = v[0] * v[0] + v[1] * v[1] + v[2] * v[2];
        std.debug.assert(sq != 0.0);
        const inv = 1.0 / @sqrt(sq);
        return .{ v[0] * inv, v[1] * inv, v[2] * inv, v[3] };
    }
    pub fn normalize4(v: SimdFloat4) SimdFloat4 {
        const sq = v[0] * v[0] + v[1] * v[1] + v[2] * v[2] + v[3] * v[3];
        std.debug.assert(sq != 0.0);
        const inv = 1.0 / @sqrt(sq);
        return v * @as(SimdFloat4, @splat(inv));
    }

    /// See `rSqrtEstNR`.
    pub fn normalizeEst2(v: SimdFloat4) SimdFloat4 {
        const sq = v[0] * v[0] + v[1] * v[1];
        std.debug.assert(sq != 0.0);
        const inv = 1.0 / @sqrt(sq);
        return .{ v[0] * inv, v[1] * inv, v[2], v[3] };
    }
    /// See `rSqrtEstNR` above: no estimate builtin in Zig, exact via `@sqrt`.
    pub fn normalizeEst3(v: SimdFloat4) SimdFloat4 {
        const sq = v[0] * v[0] + v[1] * v[1] + v[2] * v[2];
        std.debug.assert(sq != 0.0);
        const inv = 1.0 / @sqrt(sq);
        return .{ v[0] * inv, v[1] * inv, v[2] * inv, v[3] };
    }
    /// See `rSqrtEstNR`.
    pub fn normalizeEst4(v: SimdFloat4) SimdFloat4 {
        const sq = v[0] * v[0] + v[1] * v[1] + v[2] * v[2] + v[3] * v[3];
        std.debug.assert(sq != 0.0);
        const inv = 1.0 / @sqrt(sq);
        return v * @as(SimdFloat4, @splat(inv));
    }

    /// z, w always come from `v`, even on the safe (zero-length) branch — see
    /// `normalizeSafe3`'s note on the same choice.
    pub fn normalizeSafe2(v: SimdFloat4, safer: SimdFloat4) SimdFloat4 {
        const sq = v[0] * v[0] + v[1] * v[1];
        if (sq == 0.0) return .{ safer[0], safer[1], v[2], v[3] };
        const inv = 1.0 / @sqrt(sq);
        return .{ v[0] * inv, v[1] * inv, v[2], v[3] };
    }
    /// Returns `safer` (with `v`'s own w) when `v` has zero length instead of
    /// asserting like `normalize3`.
    pub fn normalizeSafe3(v: SimdFloat4, safer: SimdFloat4) SimdFloat4 {
        const sq = v[0] * v[0] + v[1] * v[1] + v[2] * v[2];
        if (sq == 0.0) return .{ safer[0], safer[1], safer[2], v[3] };
        const inv = 1.0 / @sqrt(sq);
        return .{ v[0] * inv, v[1] * inv, v[2] * inv, v[3] };
    }
    pub fn normalizeSafe4(v: SimdFloat4, safer: SimdFloat4) SimdFloat4 {
        const sq = v[0] * v[0] + v[1] * v[1] + v[2] * v[2] + v[3] * v[3];
        if (sq == 0.0) return safer;
        const inv = 1.0 / @sqrt(sq);
        return v * @as(SimdFloat4, @splat(inv));
    }

    /// See `rSqrtEstNR` and `normalizeSafe2`.
    pub fn normalizeSafeEst2(v: SimdFloat4, safer: SimdFloat4) SimdFloat4 {
        const sq = v[0] * v[0] + v[1] * v[1];
        if (sq == 0.0) return .{ safer[0], safer[1], v[2], v[3] };
        const inv = 1.0 / @sqrt(sq);
        return .{ v[0] * inv, v[1] * inv, v[2], v[3] };
    }
    /// See `rSqrtEstNR` and `normalizeSafe3`.
    pub fn normalizeSafeEst3(v: SimdFloat4, safer: SimdFloat4) SimdFloat4 {
        const sq = v[0] * v[0] + v[1] * v[1] + v[2] * v[2];
        if (sq == 0.0) return .{ safer[0], safer[1], safer[2], v[3] };
        const inv = 1.0 / @sqrt(sq);
        return .{ v[0] * inv, v[1] * inv, v[2] * inv, v[3] };
    }
    /// See `rSqrtEstNR` and `normalizeSafe4`.
    pub fn normalizeSafeEst4(v: SimdFloat4, safer: SimdFloat4) SimdFloat4 {
        const sq = v[0] * v[0] + v[1] * v[1] + v[2] * v[2] + v[3] * v[3];
        if (sq == 0.0) return safer;
        const inv = 1.0 / @sqrt(sq);
        return v * @as(SimdFloat4, @splat(inv));
    }

    /// Lane x holds the result (-1 or 0); lanes y, z, w are 0.
    pub fn isNormalized2(v: SimdFloat4) SimdInt4 {
        const sq = v[0] * v[0] + v[1] * v[1];
        const ok = @abs(sq - 1.0) < k_normalization_tolerance_sq;
        return .{ if (ok) -1 else 0, 0, 0, 0 };
    }
    pub fn isNormalized3(v: SimdFloat4) SimdInt4 {
        const sq = v[0] * v[0] + v[1] * v[1] + v[2] * v[2];
        const ok = @abs(sq - 1.0) < k_normalization_tolerance_sq;
        return .{ if (ok) -1 else 0, 0, 0, 0 };
    }
    pub fn isNormalized4(v: SimdFloat4) SimdInt4 {
        const sq = v[0] * v[0] + v[1] * v[1] + v[2] * v[2] + v[3] * v[3];
        const ok = @abs(sq - 1.0) < k_normalization_tolerance_sq;
        return .{ if (ok) -1 else 0, 0, 0, 0 };
    }

    /// Same as `isNormalized2` but with the looser tolerance `*Est` math needs.
    pub fn isNormalizedEst2(v: SimdFloat4) SimdInt4 {
        const sq = v[0] * v[0] + v[1] * v[1];
        const ok = @abs(sq - 1.0) < k_normalization_tolerance_est_sq;
        return .{ if (ok) -1 else 0, 0, 0, 0 };
    }
    /// Same as `isNormalized3` but with the looser tolerance `*Est` math needs.
    pub fn isNormalizedEst3(v: SimdFloat4) SimdInt4 {
        const sq = v[0] * v[0] + v[1] * v[1] + v[2] * v[2];
        const ok = @abs(sq - 1.0) < k_normalization_tolerance_est_sq;
        return .{ if (ok) -1 else 0, 0, 0, 0 };
    }
    pub fn isNormalizedEst4(v: SimdFloat4) SimdInt4 {
        const sq = v[0] * v[0] + v[1] * v[1] + v[2] * v[2] + v[3] * v[3];
        const ok = @abs(sq - 1.0) < k_normalization_tolerance_est_sq;
        return .{ if (ok) -1 else 0, 0, 0, 0 };
    }
};

/// Mirrors ozz::math::simd_int4:: — loads, int<->float rounding, and the
/// mask constants — plus the compare, logic, shift, and swizzle operations
/// ozz keeps at `ozz::math::` scope, grouped here by result/operand type.
pub const simd_int4 = struct {
    pub fn loadX(x: bool) SimdInt4 {
        return .{ if (x) -1 else 0, 0, 0, 0 };
    }
    pub fn load1(x: bool) SimdInt4 {
        const v: i32 = if (x) -1 else 0;
        return .{ v, v, v, v };
    }
    /// 16-byte aligned load of 4 ints.
    pub fn loadPtr(i: *align(16) const [4]i32) SimdInt4 {
        return i.*;
    }
    pub fn loadPtrU(i: *const [4]i32) SimdInt4 {
        return i.*;
    }
    /// 16-byte aligned, despite reading a single int — matches ozz's own
    /// (stricter than strictly necessary) alignment contract for this one.
    pub fn loadXPtr(i: *align(16) const i32) SimdInt4 {
        return .{ i.*, 0, 0, 0 };
    }
    pub fn loadXPtrU(i: *const i32) SimdInt4 {
        return .{ i.*, 0, 0, 0 };
    }
    pub fn load1Ptr(i: *align(16) const i32) SimdInt4 {
        return .{ i.*, i.*, i.*, i.* };
    }
    pub fn load1PtrU(i: *const i32) SimdInt4 {
        return .{ i.*, i.*, i.*, i.* };
    }
    pub fn load2Ptr(i: *align(16) const [2]i32) SimdInt4 {
        return .{ i[0], i[1], 0, 0 };
    }
    pub fn load2PtrU(i: *const [2]i32) SimdInt4 {
        return .{ i[0], i[1], 0, 0 };
    }
    pub fn load3Ptr(i: *align(16) const [3]i32) SimdInt4 {
        return .{ i[0], i[1], i[2], 0 };
    }
    pub fn load3PtrU(i: *const [3]i32) SimdInt4 {
        return .{ i[0], i[1], i[2], 0 };
    }

    /// `@round` breaks an exact .5 tie away from zero; SSE's default MXCSR
    /// rounding mode breaks it to even. The two agree everywhere else.
    pub fn fromFloatRound(f: SimdFloat4) SimdInt4 {
        return .{
            @intFromFloat(@round(f[0])),
            @intFromFloat(@round(f[1])),
            @intFromFloat(@round(f[2])),
            @intFromFloat(@round(f[3])),
        };
    }
    pub fn fromFloatTrunc(f: SimdFloat4) SimdInt4 {
        return .{
            @intFromFloat(@trunc(f[0])),
            @intFromFloat(@trunc(f[1])),
            @intFromFloat(@trunc(f[2])),
            @intFromFloat(@trunc(f[3])),
        };
    }

    pub fn all_true() SimdInt4 {
        return .{ -1, -1, -1, -1 };
    }
    pub fn all_false() SimdInt4 {
        return .{ 0, 0, 0, 0 };
    }

    // Mask constants. Plain literals rather than ports of the SSE bit
    // tricks that build them — there is no register to build them in here.
    pub fn mask_sign() SimdInt4 {
        const s = std.math.minInt(i32);
        return .{ s, s, s, s };
    }
    pub fn mask_sign_xyz() SimdInt4 {
        const s = std.math.minInt(i32);
        return .{ s, s, s, 0 };
    }
    pub fn mask_sign_w() SimdInt4 {
        return .{ 0, 0, 0, std.math.minInt(i32) };
    }
    pub fn mask_not_sign() SimdInt4 {
        const s = std.math.maxInt(i32);
        return .{ s, s, s, s };
    }
    // ozz has no mask_sign_x.
    pub fn mask_ffff() SimdInt4 {
        return .{ -1, -1, -1, -1 };
    }
    pub fn mask_0000() SimdInt4 {
        return .{ 0, 0, 0, 0 };
    }
    pub fn mask_fff0() SimdInt4 {
        return .{ -1, -1, -1, 0 };
    }
    pub fn mask_f000() SimdInt4 {
        return .{ -1, 0, 0, 0 };
    }
    pub fn mask_0f00() SimdInt4 {
        return .{ 0, -1, 0, 0 };
    }
    pub fn mask_00f0() SimdInt4 {
        return .{ 0, 0, -1, 0 };
    }
    pub fn mask_000f() SimdInt4 {
        return .{ 0, 0, 0, -1 };
    }

    pub fn @"and"(a: SimdInt4, b: SimdInt4) SimdInt4 {
        return a & b;
    }
    pub fn xor(a: SimdInt4, b: SimdInt4) SimdInt4 {
        return a ^ b;
    }
    pub fn not(v: SimdInt4) SimdInt4 {
        return ~v;
    }
    /// ozz also has a float/mask overload, `AndNot(SimdFloat4, SimdInt4)`; this
    /// binds the int/int one, pairing with `and`/`xor` above.
    pub fn andNot(a: SimdInt4, b: SimdInt4) SimdInt4 {
        return a & ~b;
    }

    pub fn cmpLt(a: SimdFloat4, b: SimdFloat4) SimdInt4 {
        return @select(i32, a < b, @as(SimdInt4, @splat(-1)), @as(SimdInt4, @splat(0)));
    }
    pub fn cmpNe(a: SimdFloat4, b: SimdFloat4) SimdInt4 {
        return @select(i32, a != b, @as(SimdInt4, @splat(-1)), @as(SimdInt4, @splat(0)));
    }
    pub fn cmpEq(a: SimdFloat4, b: SimdFloat4) SimdInt4 {
        return @select(i32, a == b, @as(SimdInt4, @splat(-1)), @as(SimdInt4, @splat(0)));
    }
    pub fn cmpGe(a: SimdFloat4, b: SimdFloat4) SimdInt4 {
        return @select(i32, a >= b, @as(SimdInt4, @splat(-1)), @as(SimdInt4, @splat(0)));
    }
    pub fn cmpGt(a: SimdFloat4, b: SimdFloat4) SimdInt4 {
        return @select(i32, a > b, @as(SimdInt4, @splat(-1)), @as(SimdInt4, @splat(0)));
    }
    pub fn cmpLe(a: SimdFloat4, b: SimdFloat4) SimdInt4 {
        return @select(i32, a <= b, @as(SimdInt4, @splat(-1)), @as(SimdInt4, @splat(0)));
    }

    /// Sign bit only (0x80000000 or 0) — not the -1/0 boolean convention
    /// comparisons in this file use. Matches ozz's `Sign` exactly.
    pub fn sign(v: SimdFloat4) SimdInt4 {
        const bits: SimdInt4 = @bitCast(v);
        const sign_bit: SimdInt4 = @splat(std.math.minInt(i32));
        return bits & sign_bit;
    }

    pub fn areAllTrue(v: SimdInt4) bool {
        return v[0] < 0 and v[1] < 0 and v[2] < 0 and v[3] < 0;
    }
    pub fn areAllTrue3(v: SimdInt4) bool {
        return v[0] < 0 and v[1] < 0 and v[2] < 0;
    }
    pub fn areAllTrue2(v: SimdInt4) bool {
        return v[0] < 0 and v[1] < 0;
    }
    pub fn areAllTrue1(v: SimdInt4) bool {
        return v[0] < 0;
    }
    pub fn areAllFalse(v: SimdInt4) bool {
        return v[0] >= 0 and v[1] >= 0 and v[2] >= 0 and v[3] >= 0;
    }
    pub fn areAllFalse3(v: SimdInt4) bool {
        return v[0] >= 0 and v[1] >= 0 and v[2] >= 0;
    }
    pub fn areAllFalse2(v: SimdInt4) bool {
        return v[0] >= 0 and v[1] >= 0;
    }
    pub fn areAllFalse1(v: SimdInt4) bool {
        return v[0] >= 0;
    }

    /// Bit `i` is set when lane `i`'s sign bit is set, matching `_mm_movemask_ps`.
    pub fn moveMask(v: SimdInt4) i32 {
        var mask: i32 = 0;
        if (v[0] < 0) mask |= 1;
        if (v[1] < 0) mask |= 2;
        if (v[2] < 0) mask |= 4;
        if (v[3] < 0) mask |= 8;
        return mask;
    }

    /// See `simd_float4.swizzle`.
    pub fn swizzle(comptime x: u2, comptime y: u2, comptime z: u2, comptime w: u2, v: SimdInt4) SimdInt4 {
        const mask = @Vector(4, i32){ @intCast(x), @intCast(y), @intCast(z), @intCast(w) };
        return @shuffle(i32, v, v, mask);
    }

    pub fn shiftL(v: SimdInt4, bits: u5) SimdInt4 {
        return v << @as(@Vector(4, u5), @splat(bits));
    }
    /// Arithmetic (sign-extending) shift.
    pub fn shiftR(v: SimdInt4, bits: u5) SimdInt4 {
        return v >> @as(@Vector(4, u5), @splat(bits));
    }
    /// Logical (zero-filling) shift, unlike `shiftR`.
    pub fn shiftRu(v: SimdInt4, bits: u5) SimdInt4 {
        const unsigned: @Vector(4, u32) = @bitCast(v);
        const shifted = unsigned >> @as(@Vector(4, u5), @splat(bits));
        return @bitCast(shifted);
    }
};

/// Mirrors ozz::math's `SimdQuaternion`/`Quaternion` free-function API. A
/// quaternion is a plain `SimdFloat4` in (x, y, z, w) order, the same layout
/// `Transform.rotation` stores. Normalizing one is
/// `simd_float4.normalize4`/`normalizeSafe4`/`normalizeEst4`/
/// `normalizeSafeEst4` above — ozz's own `SimdQuaternion::Normalize` and
/// friends are trivial wrappers around those, so they are not duplicated here.
pub const quaternion = struct {
    pub fn conjugate(q: SimdFloat4) SimdFloat4 {
        return .{ -q[0], -q[1], -q[2], q[3] };
    }

    /// ozz's `operator*(Quaternion, Quaternion)` / `operator*(SimdQuaternion,
    /// SimdQuaternion)`. Normalized if both inputs are.
    pub fn mul(a: SimdFloat4, b: SimdFloat4) SimdFloat4 {
        return .{
            a[3] * b[0] + a[0] * b[3] + a[1] * b[2] - a[2] * b[1],
            a[3] * b[1] + a[1] * b[3] + a[2] * b[0] - a[0] * b[2],
            a[3] * b[2] + a[2] * b[3] + a[0] * b[1] - a[1] * b[0],
            a[3] * b[3] - a[0] * b[0] - a[1] * b[1] - a[2] * b[2],
        };
    }

    /// Linear interpolation followed by exact normalization. No zero-length
    /// guard — matches ozz's `NLerp`, which has none either.
    pub fn nlerp(a: SimdFloat4, b: SimdFloat4, f: f32) SimdFloat4 {
        const lerp = a + (b - a) * @as(SimdFloat4, @splat(f));
        const sq = lerp[0] * lerp[0] + lerp[1] * lerp[1] + lerp[2] * lerp[2] + lerp[3] * lerp[3];
        const inv = 1.0 / @sqrt(sq);
        return lerp * @as(SimdFloat4, @splat(inv));
    }

    /// ozz only defines `NLerpEst` for `SoaQuaternion` batches, not a single
    /// quaternion. This mirrors that relationship (lerp, then the `*Est`
    /// normalization ozz uses for quaternions specifically because they "loose
    /// much precision due to normalization") rather than copying a nonexistent
    /// single-quaternion original. See `simd_float4.rSqrtEstNR` for the `@sqrt`
    /// note.
    pub fn nlerpEst(a: SimdFloat4, b: SimdFloat4, f: f32) SimdFloat4 {
        const lerp = a + (b - a) * @as(SimdFloat4, @splat(f));
        const sq = lerp[0] * lerp[0] + lerp[1] * lerp[1] + lerp[2] * lerp[2] + lerp[3] * lerp[3];
        const inv = 1.0 / @sqrt(sq);
        return lerp * @as(SimdFloat4, @splat(inv));
    }

    /// Spherical interpolation. The `@abs(cos_half_theta)` hemisphere check
    /// (rather than a plain `>=`) is what makes `_a` and `-_a` (the same
    /// rotation, reached the long way around) both snap to `_a` instead of
    /// hitting the ill-defined near-180-degree case — dropping the `@abs` is the
    /// easy way to get this subtly wrong.
    pub fn slerp(a: SimdFloat4, b: SimdFloat4, f: f32) SimdFloat4 {
        std.debug.assert(simd_float4.isNormalized4(a)[0] != 0);
        std.debug.assert(simd_float4.isNormalized4(b)[0] != 0);
        const cos_half_theta = a[0] * b[0] + a[1] * b[1] + a[2] * b[2] + a[3] * b[3];
        if (@abs(cos_half_theta) >= 0.999) return a;

        const half_theta = std.math.acos(cos_half_theta);
        const sin_half_theta = @sqrt(1.0 - cos_half_theta * cos_half_theta);
        if (sin_half_theta < 0.001) {
            return .{
                (a[0] + b[0]) * 0.5,
                (a[1] + b[1]) * 0.5,
                (a[2] + b[2]) * 0.5,
                (a[3] + b[3]) * 0.5,
            };
        }

        const ratio_a = std.math.sin((1.0 - f) * half_theta) / sin_half_theta;
        const ratio_b = std.math.sin(f * half_theta) / sin_half_theta;
        return .{
            ratio_a * a[0] + ratio_b * b[0],
            ratio_a * a[1] + ratio_b * b[1],
            ratio_a * a[2] + ratio_b * b[2],
            ratio_a * a[3] + ratio_b * b[3],
        };
    }

    /// `angle` is taken as a plain `f32` rather than ozz's `_SimdFloat4 _angle`
    /// (lane 0) — the same value, more ergonomic without SSE register pressure
    /// to justify keeping it vectorized. `axis` must be normalized.
    pub fn fromAxisAngle(axis: SimdFloat4, angle: f32) SimdFloat4 {
        std.debug.assert(simd_float4.isNormalizedEst3(axis)[0] != 0);
        const half = angle * 0.5;
        const s = std.math.sin(half);
        const cosv = std.math.cos(half);
        return .{ axis[0] * s, axis[1] * s, axis[2] * s, cosv };
    }

    /// `cos` (of the angle) is taken as a plain `f32`; see `fromAxisAngle`.
    pub fn fromAxisCosAngle(axis: SimdFloat4, cos: f32) SimdFloat4 {
        std.debug.assert(simd_float4.isNormalizedEst3(axis)[0] != 0);
        std.debug.assert(cos >= -1.0 and cos <= 1.0);
        const half_cos2 = (1.0 + cos) * 0.5;
        const half_sin = @sqrt(1.0 - half_cos2);
        const half_cos = @sqrt(half_cos2);
        return .{ axis[0] * half_sin, axis[1] * half_sin, axis[2] * half_sin, half_cos };
    }

    /// Axis in xyz, angle in w. Below the axis threshold, angle collapses to 0
    /// too (not just the axis) — that is `SimdQuaternion::ToAxisAngle`'s actual
    /// behaviour; ozz's scalar `Quaternion` port keeps the real angle there
    /// instead, so the two disagree in this one corner.
    pub fn toAxisAngle(q: SimdFloat4) SimdFloat4 {
        std.debug.assert(simd_float4.isNormalizedEst4(q)[0] != 0);
        const clamped_w = std.math.clamp(q[3], -1.0, 1.0);
        const half_angle = std.math.acos(clamped_w);
        const s = @sqrt(1.0 - clamped_w * clamped_w);
        if (s < 1e-3) return .{ 1, 0, 0, 0 };
        const inv_s = 1.0 / s; // ozz uses RcpEstNR(s); no estimate reciprocal in Zig.
        return .{ q[0] * inv_s, q[1] * inv_s, q[2] * inv_s, half_angle + half_angle };
    }

    /// Inputs need not be normalized or non-zero.
    pub fn fromVectors(from: SimdFloat4, to: SimdFloat4) SimdFloat4 {
        const lensq_from = from[0] * from[0] + from[1] * from[1] + from[2] * from[2];
        const lensq_to = to[0] * to[0] + to[1] * to[1] + to[2] * to[2];
        const norm_from_norm_to = @sqrt(lensq_from * lensq_to);
        if (norm_from_norm_to < 1.0e-6) return .{ 0, 0, 0, 1 };

        const dot = from[0] * to[0] + from[1] * to[1] + from[2] * to[2];
        const real_part = norm_from_norm_to + dot;
        var q: SimdFloat4 = undefined;
        if (real_part < 1.0e-6 * norm_from_norm_to) {
            // _from and _to are exactly opposite: rotate 180 degrees around an
            // arbitrary axis orthogonal to _from.
            q = if (@abs(from[0]) > @abs(from[2]))
                SimdFloat4{ -from[1], from[0], 0, 0 }
            else
                SimdFloat4{ 0, -from[2], from[1], 0 };
        } else {
            q = .{
                from[1] * to[2] - from[2] * to[1],
                from[2] * to[0] - from[0] * to[2],
                from[0] * to[1] - from[1] * to[0],
                real_part,
            };
        }
        return simd_float4.normalize4(q);
    }

    /// Same as `fromVectors`, but both inputs must already be normalized.
    pub fn fromUnitVectors(from: SimdFloat4, to: SimdFloat4) SimdFloat4 {
        std.debug.assert(simd_float4.isNormalizedEst3(from)[0] != 0 and simd_float4.isNormalizedEst3(to)[0] != 0);
        const dot = from[0] * to[0] + from[1] * to[1] + from[2] * to[2];
        const real_part = 1.0 + dot;
        if (real_part < 1.0e-6) {
            // Not normalized in ozz either — the antiparallel fallback axis is
            // only unit length when _from happens to lie in the XY or ZY plane.
            return if (@abs(from[0]) > @abs(from[2]))
                SimdFloat4{ -from[1], from[0], 0, 0 }
            else
                SimdFloat4{ 0, -from[2], from[1], 0 };
        }
        return simd_float4.normalize4(.{
            from[1] * to[2] - from[2] * to[1],
            from[2] * to[0] - from[0] * to[2],
            from[0] * to[1] - from[1] * to[0],
            real_part,
        });
    }

    /// `ypr` is heading (yaw), elevation (pitch), bank (roll) in lanes x, y, z.
    pub fn fromEuler(ypr: SimdFloat4) SimdFloat4 {
        const half_yaw = ypr[0] * 0.5;
        const c1 = std.math.cos(half_yaw);
        const s1 = std.math.sin(half_yaw);
        const half_pitch = ypr[1] * 0.5;
        const c2 = std.math.cos(half_pitch);
        const s2 = std.math.sin(half_pitch);
        const half_roll = ypr[2] * 0.5;
        const c3 = std.math.cos(half_roll);
        const s3 = std.math.sin(half_roll);
        const c1c2 = c1 * c2;
        const s1s2 = s1 * s2;
        return .{
            c1c2 * s3 + s1s2 * c3,
            s1 * c2 * c3 + c1 * s2 * s3,
            c1 * s2 * c3 - s1 * c2 * s3,
            c1c2 * c3 - s1s2 * s3,
        };
    }

    /// Inverse of `fromEuler`: heading, elevation, bank in lanes x, y, z, w set
    /// to 0. `q` need not be normalized.
    pub fn toEuler(q: SimdFloat4) SimdFloat4 {
        const sqw = q[3] * q[3];
        const sqx = q[0] * q[0];
        const sqy = q[1] * q[1];
        const sqz = q[2] * q[2];
        const unit = sqx + sqy + sqz + sqw;
        const singularity_test = q[0] * q[1] + q[2] * q[3];
        if (singularity_test > 0.499 * unit) {
            return .{ 2.0 * std.math.atan2(q[0], q[3]), k_pi_2, 0, 0 };
        } else if (singularity_test < -0.499 * unit) {
            return .{ -2.0 * std.math.atan2(q[0], q[3]), -k_pi_2, 0, 0 };
        }
        return .{
            std.math.atan2(2.0 * q[1] * q[3] - 2.0 * q[0] * q[2], sqx - sqy - sqz + sqw),
            std.math.asin(2.0 * singularity_test / unit),
            std.math.atan2(2.0 * q[0] * q[3] - 2.0 * q[1] * q[2], -sqx + sqy - sqz + sqw),
            0,
        };
    }
};

// Matrices. Mat4 stores its 16 floats column-major and flat (see the doc
// comment above); these two helpers are the only place that shape is
// unpacked into/from the 4 SimdFloat4 columns ozz's Float4x4 uses natively.

fn col4(m: Mat4, i: usize) SimdFloat4 {
    return .{ m.m[i * 4 + 0], m.m[i * 4 + 1], m.m[i * 4 + 2], m.m[i * 4 + 3] };
}

fn mat4FromCols(c0: SimdFloat4, c1: SimdFloat4, c2: SimdFloat4, c3: SimdFloat4) Mat4 {
    var out: Mat4 = undefined;
    inline for (.{ c0, c1, c2, c3 }, 0..) |col, i| {
        out.m[i * 4 + 0] = col[0];
        out.m[i * 4 + 1] = col[1];
        out.m[i * 4 + 2] = col[2];
        out.m[i * 4 + 3] = col[3];
    }
    return out;
}

/// ozz::math::Float4x4 operations. `Mat4` is the re-exported C type (see the
/// file header) and cannot carry its own methods, so these are grouped here
/// instead: `mat4.transpose(m)`, not `m.transpose()`.
pub const mat4 = struct {
    pub fn transpose(m: Mat4) Mat4 {
        const c0 = col4(m, 0);
        const c1 = col4(m, 1);
        const c2 = col4(m, 2);
        const c3 = col4(m, 3);
        return mat4FromCols(
            .{ c0[0], c1[0], c2[0], c3[0] },
            .{ c0[1], c1[1], c2[1], c3[1] },
            .{ c0[2], c1[2], c2[2], c3[2] },
            .{ c0[3], c1[3], c2[3], c3[3] },
        );
    }

    /// If `invertible` is non-null, its target is set to whether `m` was
    /// invertible (result is zeroed, not garbage, when it was not). If null,
    /// asserts instead. The adjugate/cofactor computation here is ozz's non-SSE
    /// reference backend (exact-determinant division); ozz's SSE backend
    /// instead uses a refined `rcp` estimate, which Zig lacks, so this port
    /// always divides exactly.
    pub fn invert(m: Mat4, invertible: ?*SimdInt4) Mat4 {
        const c0 = col4(m, 0);
        const c1 = col4(m, 1);
        const c2 = col4(m, 2);
        const c3 = col4(m, 3);

        const a00 = c2[2] * c3[3] - c3[2] * c2[3];
        const a01 = c2[1] * c3[3] - c3[1] * c2[3];
        const a02 = c2[1] * c3[2] - c3[1] * c2[2];
        const a03 = c2[0] * c3[3] - c3[0] * c2[3];
        const a04 = c2[0] * c3[2] - c3[0] * c2[2];
        const a05 = c2[0] * c3[1] - c3[0] * c2[1];
        const a06 = c1[2] * c3[3] - c3[2] * c1[3];
        const a07 = c1[1] * c3[3] - c3[1] * c1[3];
        const a08 = c1[1] * c3[2] - c3[1] * c1[2];
        const a09 = c1[0] * c3[3] - c3[0] * c1[3];
        const a10 = c1[0] * c3[2] - c3[0] * c1[2];
        const a11 = c1[1] * c3[3] - c3[1] * c1[3];
        const a12 = c1[0] * c3[1] - c3[0] * c1[1];
        const a13 = c1[2] * c2[3] - c2[2] * c1[3];
        const a14 = c1[1] * c2[3] - c2[1] * c1[3];
        const a15 = c1[1] * c2[2] - c2[1] * c1[2];
        const a16 = c1[0] * c2[3] - c2[0] * c1[3];
        const a17 = c1[0] * c2[2] - c2[0] * c1[2];
        const a18 = c1[0] * c2[1] - c2[0] * c1[1];

        const b0x = c1[1] * a00 - c1[2] * a01 + c1[3] * a02;
        const b1x = -c1[0] * a00 + c1[2] * a03 - c1[3] * a04;
        const b2x = c1[0] * a01 - c1[1] * a03 + c1[3] * a05;
        const b3x = -c1[0] * a02 + c1[1] * a04 - c1[2] * a05;

        const b0y = -c0[1] * a00 + c0[2] * a01 - c0[3] * a02;
        const b1y = c0[0] * a00 - c0[2] * a03 + c0[3] * a04;
        const b2y = -c0[0] * a01 + c0[1] * a03 - c0[3] * a05;
        const b3y = c0[0] * a02 - c0[1] * a04 + c0[2] * a05;

        const b0z = c0[1] * a06 - c0[2] * a07 + c0[3] * a08;
        const b1z = -c0[0] * a06 + c0[2] * a09 - c0[3] * a10;
        const b2z = c0[0] * a11 - c0[1] * a09 + c0[3] * a12;
        const b3z = -c0[0] * a08 + c0[1] * a10 - c0[2] * a12;

        const b0w = -c0[1] * a13 + c0[2] * a14 - c0[3] * a15;
        const b1w = c0[0] * a13 - c0[2] * a16 + c0[3] * a17;
        const b2w = -c0[0] * a14 + c0[1] * a16 - c0[3] * a18;
        const b3w = c0[0] * a15 - c0[1] * a17 + c0[2] * a18;

        const det = c0[0] * b0x + c0[1] * b1x + c0[2] * b2x + c0[3] * b3x;
        const is_invertible = det != 0.0;
        std.debug.assert(invertible != null or is_invertible);
        if (invertible) |out| out.* = .{ if (is_invertible) -1 else 0, 0, 0, 0 };
        const inv_det: f32 = if (is_invertible) 1.0 / det else 0.0;

        return mat4FromCols(
            .{ b0x * inv_det, b0y * inv_det, b0z * inv_det, b0w * inv_det },
            .{ b1x * inv_det, b1y * inv_det, b1z * inv_det, b1w * inv_det },
            .{ b2x * inv_det, b2y * inv_det, b2z * inv_det, b2w * inv_det },
            .{ b3x * inv_det, b3y * inv_det, b3z * inv_det, b3w * inv_det },
        );
    }

    pub fn columnMultiply(m: Mat4, v: SimdFloat4) Mat4 {
        return mat4FromCols(col4(m, 0) * v, col4(m, 1) * v, col4(m, 2) * v, col4(m, 3) * v);
    }

    /// `v.w` is ignored, matching `Float4x4::Scaling`.
    pub fn scaling(v: SimdFloat4) Mat4 {
        return mat4FromCols(
            .{ v[0], 0, 0, 0 },
            .{ 0, v[1], 0, 0 },
            .{ 0, 0, v[2], 0 },
            .{ 0, 0, 0, 1 },
        );
    }

    /// Translates `m` along `v` (`v.w` ignored). To build a pure translation
    /// matrix from scratch, `mat4.translate(mat4_identity, v)`.
    pub fn translate(m: Mat4, v: SimdFloat4) Mat4 {
        const c0 = col4(m, 0);
        const c1 = col4(m, 1);
        const c2 = col4(m, 2);
        const c3 = col4(m, 3);
        return mat4FromCols(c0, c1, c2, .{
            c0[0] * v[0] + c1[0] * v[1] + c2[0] * v[2] + c3[0],
            c0[1] * v[0] + c1[1] * v[1] + c2[1] * v[2] + c3[1],
            c0[2] * v[0] + c1[2] * v[1] + c2[2] * v[2] + c3[2],
            c0[3] * v[0] + c1[3] * v[1] + c2[3] * v[2] + c3[3],
        });
    }

    /// Lane x holds the result (-1 or 0); lanes y, z, w are 0. A matrix
    /// containing a reflection is never considered orthogonal.
    pub fn isOrthogonal(m: Mat4) SimdInt4 {
        const zero = simd_float4.zero();
        const cross = simd_float4.normalizeSafe3(simd_float4.cross3(col4(m, 0), col4(m, 1)), zero);
        const at = simd_float4.normalizeSafe3(col4(m, 2), zero);
        const sq_len = cross[0] * at[0] + cross[1] * at[1] + cross[2] * at[2];
        const same = @abs(sq_len - 1.0) < k_normalization_tolerance_sq;
        return .{ if (same) -1 else 0, 0, 0, 0 };
    }

    /// Equivalent to multiplying `m` by a SimdFloat4 with a w component of 1.
    pub fn transformPoint(m: Mat4, v: SimdFloat4) SimdFloat4 {
        const c0 = col4(m, 0);
        const c1 = col4(m, 1);
        const c2 = col4(m, 2);
        const c3 = col4(m, 3);
        return .{
            c0[0] * v[0] + c1[0] * v[1] + c2[0] * v[2] + c3[0],
            c0[1] * v[0] + c1[1] * v[1] + c2[1] * v[2] + c3[1],
            c0[2] * v[0] + c1[2] * v[1] + c2[2] * v[2] + c3[2],
            c0[3] * v[0] + c1[3] * v[1] + c2[3] * v[2] + c3[3],
        };
    }

    /// Equivalent to multiplying `m` by a SimdFloat4 with a w component of 0.
    pub fn transformVector(m: Mat4, v: SimdFloat4) SimdFloat4 {
        const c0 = col4(m, 0);
        const c1 = col4(m, 1);
        const c2 = col4(m, 2);
        return .{
            c0[0] * v[0] + c1[0] * v[1] + c2[0] * v[2],
            c0[1] * v[0] + c1[1] * v[1] + c2[1] * v[2],
            c0[2] * v[0] + c1[2] * v[1] + c2[2] * v[2],
            c0[3] * v[0] + c1[3] * v[1] + c2[3] * v[2],
        };
    }

    /// The core of ozz's three `FromAffine` overloads; the `Float3`+`Quaternion`
    /// and `Transform` convenience overloads are not duplicated since Zig has no
    /// overloading — a caller converts its translation/scale to SimdFloat4.
    pub fn fromAffine(translation: SimdFloat4, rotation: SimdFloat4, scale: SimdFloat4) Mat4 {
        std.debug.assert(simd_float4.isNormalizedEst4(rotation)[0] != 0);
        const qx = rotation[0];
        const qy = rotation[1];
        const qz = rotation[2];
        const qw = rotation[3];
        const xx = qx * qx;
        const xy = qx * qy;
        const xz = qx * qz;
        const xw = qx * qw;
        const yy = qy * qy;
        const yz = qy * qz;
        const yw = qy * qw;
        const zz = qz * qz;
        const zw = qz * qw;
        return mat4FromCols(
            .{ scale[0] * (1.0 - 2.0 * (yy + zz)), scale[0] * 2.0 * (xy + zw), scale[0] * 2.0 * (xz - yw), 0 },
            .{ scale[1] * 2.0 * (xy - zw), scale[1] * (1.0 - 2.0 * (xx + zz)), scale[1] * 2.0 * (yz + xw), 0 },
            .{ scale[2] * 2.0 * (xz + yw), scale[2] * 2.0 * (yz - xw), scale[2] * (1.0 - 2.0 * (xx + yy)), 0 },
            .{ translation[0], translation[1], translation[2], 1 },
        );
    }

    /// The core of ozz's three `ToAffine` overloads; see `fromAffine`. Returns
    /// false, leaving the out params untouched, when `m` cannot be decomposed
    /// (more than one of its first 3 columns scaled to ~0).
    pub fn toAffine(m: Mat4, translation: *SimdFloat4, rotation: *SimdFloat4, scale: *SimdFloat4) bool {
        const c0 = col4(m, 0);
        const c1 = col4(m, 1);
        const c2 = col4(m, 2);
        const c3 = col4(m, 3);
        translation.* = .{ c3[0], c3[1], c3[2], 1 };

        const sq_scale_x = c0[0] * c0[0] + c0[1] * c0[1] + c0[2] * c0[2];
        const scale_x = @sqrt(sq_scale_x);
        const sq_scale_y = c1[0] * c1[0] + c1[1] * c1[1] + c1[2] * c1[2];
        const scale_y = @sqrt(sq_scale_y);
        const sq_scale_z = c2[0] * c2[0] + c2[1] * c2[1] + c2[2] * c2[2];
        const scale_z = @sqrt(sq_scale_z);

        const x_zero = @abs(sq_scale_x) < k_orthogonalisation_tolerance_sq;
        const y_zero = @abs(sq_scale_y) < k_orthogonalisation_tolerance_sq;
        const z_zero = @abs(sq_scale_z) < k_orthogonalisation_tolerance_sq;

        // Builds an orthonormal matrix in order to support quaternion extraction.
        var o0: SimdFloat4 = undefined;
        var o1: SimdFloat4 = undefined;
        var o2: SimdFloat4 = undefined;
        if (x_zero) {
            if (y_zero or z_zero) return false;
            o1 = .{ c1[0] / scale_y, c1[1] / scale_y, c1[2] / scale_y, 0 };
            o0 = simd_float4.normalize3(simd_float4.cross3(o1, c2));
            o2 = simd_float4.normalize3(simd_float4.cross3(o0, o1));
        } else if (z_zero) {
            if (x_zero or y_zero) return false;
            o0 = .{ c0[0] / scale_x, c0[1] / scale_x, c0[2] / scale_x, 0 };
            o2 = simd_float4.normalize3(simd_float4.cross3(o0, c1));
            o1 = simd_float4.normalize3(simd_float4.cross3(o2, o0));
        } else { // Favor z axis in the default case.
            if (x_zero or z_zero) return false;
            o2 = .{ c2[0] / scale_z, c2[1] / scale_z, c2[2] / scale_z, 0 };
            o1 = simd_float4.normalize3(simd_float4.cross3(o2, c0));
            o0 = simd_float4.normalize3(simd_float4.cross3(o1, o2));
        }

        // Gets back scale signs in case of reflections.
        scale.* = .{
            if (o0[0] * c0[0] + o0[1] * c0[1] + o0[2] * c0[2] > 0.0) scale_x else -scale_x,
            if (o1[0] * c1[0] + o1[1] * c1[1] + o1[2] * c1[2] > 0.0) scale_y else -scale_y,
            if (o2[0] * c2[0] + o2[1] * c2[1] + o2[2] * c2[2] > 0.0) scale_z else -scale_z,
            1,
        };

        rotation.* = toQuaternion(mat4FromCols(o0, o1, o2, .{ 0, 0, 0, 1 }));
        return true;
    }

    pub fn fromQuaternion(rotation: SimdFloat4) Mat4 {
        std.debug.assert(simd_float4.isNormalizedEst4(rotation)[0] != 0);
        const qx = rotation[0];
        const qy = rotation[1];
        const qz = rotation[2];
        const qw = rotation[3];
        const xx = qx * qx;
        const xy = qx * qy;
        const xz = qx * qz;
        const xw = qx * qw;
        const yy = qy * qy;
        const yz = qy * qz;
        const yw = qy * qw;
        const zz = qz * qz;
        const zw = qz * qw;
        return mat4FromCols(
            .{ 1.0 - 2.0 * (yy + zz), 2.0 * (xy + zw), 2.0 * (xz - yw), 0 },
            .{ 2.0 * (xy - zw), 1.0 - 2.0 * (xx + zz), 2.0 * (yz + xw), 0 },
            .{ 2.0 * (xz + yw), 2.0 * (yz - xw), 1.0 - 2.0 * (xx + yy), 0 },
            .{ 0, 0, 0, 1 },
        );
    }

    /// `m` must be normalized and orthogonal; the returned quaternion is
    /// normalized. Cf. "From Quaternion to Matrix and Back", J.M.P. van Waveren.
    pub fn toQuaternion(m: Mat4) SimdFloat4 {
        const c0 = col4(m, 0);
        const c1 = col4(m, 1);
        const c2 = col4(m, 2);
        if (c0[0] + c1[1] + c2[2] > 0.0) {
            const t = c0[0] + c1[1] + c2[2] + 1.0;
            const s = (1.0 / @sqrt(t)) * 0.5;
            return .{ (c1[2] - c2[1]) * s, (c2[0] - c0[2]) * s, (c0[1] - c1[0]) * s, s * t };
        } else if (c0[0] > c1[1] and c0[0] > c2[2]) {
            const t = c0[0] - c1[1] - c2[2] + 1.0;
            const s = (1.0 / @sqrt(t)) * 0.5;
            return .{ s * t, (c0[1] + c1[0]) * s, (c2[0] + c0[2]) * s, (c1[2] - c2[1]) * s };
        } else if (c1[1] > c2[2]) {
            const t = -c0[0] + c1[1] - c2[2] + 1.0;
            const s = (1.0 / @sqrt(t)) * 0.5;
            return .{ (c0[1] + c1[0]) * s, s * t, (c1[2] + c2[1]) * s, (c2[0] - c0[2]) * s };
        }
        const t = -c0[0] - c1[1] + c2[2] + 1.0;
        const s = (1.0 / @sqrt(t)) * 0.5;
        return .{ (c2[0] + c0[2]) * s, (c1[2] + c2[1]) * s, s * t, (c0[1] - c1[0]) * s };
    }
};

// Box. Only min/max and `transform` are ported — ozz's other Box members
// (is_valid, is_inside, Merge, the point-cloud constructor) were not asked
// for.

pub const Box = struct {
    min: [3]f32,
    max: [3]f32,

    /// A box is valid when every component of `min` is at most its `max`.
    pub fn isValid(self: Box) bool {
        return self.min[0] <= self.max[0] and
            self.min[1] <= self.max[1] and
            self.min[2] <= self.max[2];
    }

    pub fn isInside(self: Box, p: [3]f32) bool {
        return p[0] >= self.min[0] and p[0] <= self.max[0] and
            p[1] >= self.min[1] and p[1] <= self.max[1] and
            p[2] >= self.min[2] and p[2] <= self.max[2];
    }

    /// Either box may be invalid, in which case the other is returned unchanged.
    pub fn merge(self: Box, other: Box) Box {
        if (!self.isValid()) return other;
        if (!other.isValid()) return self;
        return .{
            .min = .{ @min(self.min[0], other.min[0]), @min(self.min[1], other.min[1]), @min(self.min[2], other.min[2]) },
            .max = .{ @max(self.max[0], other.max[0]), @max(self.max[1], other.max[1]), @max(self.max[2], other.max[2]) },
        };
    }

    /// Transforms just the two corners `min`/`max`, not all 8 — this
    /// under-approximates for a rotated box, but it is exactly what ozz does.
    pub fn transform(self: Box, m: Mat4) Box {
        const bmin: SimdFloat4 = .{ self.min[0], self.min[1], self.min[2], 0 };
        const bmax: SimdFloat4 = .{ self.max[0], self.max[1], self.max[2], 0 };
        const ta = mat4.transformPoint(m, bmin);
        const tb = mat4.transformPoint(m, bmax);
        return .{
            .min = .{ @min(ta[0], tb[0]), @min(ta[1], tb[1]), @min(ta[2], tb[2]) },
            .max = .{ @max(ta[0], tb[0]), @max(ta[1], tb[1]), @max(ta[2], tb[2]) },
        };
    }
};

/// A rectangle given by its lower-left corner and its size, mirroring
/// `ozz::math::RectInt` and `RectFloat`. `T` is `i32` or `f32`.
pub fn Rect(comptime T: type) type {
    return struct {
        const Self = @This();

        left: T = 0,
        bottom: T = 0,
        width: T = 0,
        height: T = 0,

        /// Right and top are exclusive; `isInside` uses `<` against them.
        pub fn right(self: Self) T {
            return self.left + self.width;
        }

        pub fn top(self: Self) T {
            return self.bottom + self.height;
        }

        pub fn isInside(self: Self, x: T, y: T) bool {
            return x >= self.left and x < self.right() and
                y >= self.bottom and y < self.top();
        }
    };
}

pub const RectInt = Rect(i32);
pub const RectFloat = Rect(f32);

/// Names this port rather than copying ozz's build-time backend string
/// (which would name a compiled-in SSE/AVX/NEON kernel this file has none
/// of): a scalar `@Vector`-based Zig port, left for LLVM to autovectorize.
pub fn simdImplementationName() []const u8 {
    return "Zig scalar (pure-Zig port, no SIMD intrinsics)";
}

// ozz::animation::offline::raw_animation_utils.h: the same interpolation the
// runtime sampling job uses, exposed for offline resampling/retargeting.

/// Mirrors `LerpTranslation`.
pub fn lerpTranslation(a: [3]f32, b: [3]f32, alpha: f32) [3]f32 {
    return .{
        a[0] + (b[0] - a[0]) * alpha,
        a[1] + (b[1] - a[1]) * alpha,
        a[2] + (b[2] - a[2]) * alpha,
    };
}

/// Mirrors `LerpScale`. See `lerpTranslation`.
pub fn lerpScale(a: [3]f32, b: [3]f32, alpha: f32) [3]f32 {
    return lerpTranslation(a, b, alpha);
}

/// Mirrors `LerpRotation`: a hemisphere check before interpolating, so two
/// quaternions more than 180 degrees apart (`dot < 0`) interpolate along the
/// short arc instead of the long one — the same shortest-path choice
/// `AnimationBuilder` bakes into a runtime animation. `a`/`b` are quaternions
/// in (x, y, z, w) order, matching this file's `SimdFloat4` convention.
pub fn lerpRotation(a: SimdFloat4, b: SimdFloat4, alpha: f32) SimdFloat4 {
    const dot = a[0] * b[0] + a[1] * b[1] + a[2] * b[2] + a[3] * b[3];
    const same_hemisphere = if (dot < 0.0) -b else b;
    return quaternion.nlerp(a, same_hemisphere, alpha);
}

// ozz::base::platform.h.
//
// Align/IsAligned are exactly std.mem.alignForward / std.mem.isAligned —
// ozz's rounding formula (`(value + (alignment-1)) & (0-alignment)`) is the
// same round-up-to-a-power-of-two-boundary computation, so they are not
// reimplemented here under a zozz-specific name; use those directly.

/// Offsets a pointer by `stride` BYTES, not elements — ozz's `PointerStride`.
/// std.mem has no equivalent for a byte offset that keeps a pointer's
/// pointee type, unlike Align/IsAligned above.
pub fn pointerStride(ptr: anytype, stride: usize) @TypeOf(ptr) {
    comptime {
        if (@typeInfo(@TypeOf(ptr)) != .pointer) @compileError("pointerStride: ptr must be a pointer");
    }
    return @ptrFromInt(@intFromPtr(ptr) + stride);
}

/// Case-sensitive wildcard matching, ported straight from platform.cc's
/// backtracking rather than rewritten as an iterative matcher, to keep the
/// same behaviour on the pathological inputs backtracking is known for.
/// `?` matches exactly one character (never an empty string); `*` matches
/// any string, including an empty one.
pub fn strmatch(str: []const u8, pattern: []const u8) bool {
    var si: usize = 0;
    var pi: usize = 0;
    while (pi < pattern.len) {
        if (pattern[pi] == '?') {
            if (si >= str.len) return false;
        } else if (pattern[pi] == '*') {
            if (strmatch(str[si..], pattern[pi + 1 ..])) return true;
            if (si < str.len and strmatch(str[si + 1 ..], pattern[pi..])) return true;
            return false;
        } else {
            if (si >= str.len or str[si] != pattern[pi]) return false;
        }
        si += 1;
        pi += 1;
    }
    return si >= str.len;
}
