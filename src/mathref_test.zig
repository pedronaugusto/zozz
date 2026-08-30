//! Differential test: `src/math.zig` against the ozz it is a port of.
//!
//! Every other test of the port compares it against itself, which cannot see a
//! transcription that is wrong the same way twice. `tests/mathref.h` reaches
//! the compiled ozz; this side runs the same operation on the same registers
//! and compares the bits.
//!
//! A tolerance is never a free parameter here: it is one of the named
//! constants below, each carrying what makes it necessary. `exact` is the
//! default. A deviation no constant covers is a finding, not a number to
//! raise.

const std = @import("std");
const math = @import("math.zig");

const ref = @cImport({
    @cInclude("mathref.h");
});

const F4 = math.SimdFloat4;
const I4 = math.SimdInt4;

/// One sixteen-byte operand. Every value ozz::math takes or returns is a whole
/// number of these, which is what lets one shape carry all of them.
const Reg = [4]f32;

const max_regs = 16;
const iterations = 128;
const seed = 0x2026_08_30;

// Tolerances, as relative deviation |a - b| / max(1, |b|).

/// Bit-for-bit. The default, and what most of the port holds.
const exact: f32 = 0;

/// ozz's `*Est` family is a hardware estimate; the port computes it exactly
/// (see `simd_float4.rSqrtEstNR`), so the deviation is the estimate's own
/// error. Worst measured on an SSE build of ozz: 2.6e-4.
const est: f32 = 1e-3;

/// A sum of products, evaluated in Zig's order rather than ozz's. Every
/// operation of that shape carries this, whether or not it happens to be
/// bit-exact today. Worst measured: 4.8e-7, an ulp or two.
const rounding: f32 = 1e-6;

/// Derived from a trigonometric function. The two sides reach the same libm
/// here and agree to a few ulps, but a different platform's libm is a
/// different approximation, which is what the extra room is for.
const trig: f32 = 1e-5;

/// A composition -- a transform product, a matrix inverse -- carries the
/// rounding of every step and cancels in the sum, so its error scales with the
/// operands rather than with the result. Worst measured: 1.4e-6.
const composed: f32 = 5e-6;

/// A single operation's Zig side: how many registers it reads and writes, and
/// the call itself. Both counts are checked against `zozzMathRefArity`.
const Impl = struct {
    eval: *const fn (in: []const Reg, out: []Reg) void,
    in_regs: usize,
    out_regs: usize,
};

//===----------------------------------------------------------------------===//
// Registers to values and back.
//
// The mapping is per type, so an operation's arity is derived from its Zig
// signature rather than restated: `adapt` reads the parameter and return
// types and counts the registers itself. An arity that disagrees with the C
// table is then a test failure with nothing hand-written to keep in step.
//===----------------------------------------------------------------------===//

fn regsFor(comptime T: type) usize {
    return switch (T) {
        F4, I4 => 1,
        math.Mat4 => 4,
        math.SoaFloat3, math.Transform => 3,
        math.SoaQuaternion => 4,
        else => switch (@typeInfo(T)) {
            .int, .float, .bool => 1,
            .array => |a| a.len * regsFor(a.child),
            else => @compileError("mathref: no register mapping for " ++ @typeName(T)),
        },
    };
}

fn readArg(comptime T: type, in: []const Reg, at: usize) T {
    return switch (T) {
        F4 => in[at],
        I4 => @bitCast(@as(F4, in[at])),
        f32 => in[at][0],
        i32 => @intFromFloat(in[at][0]),
        math.Mat4 => blk: {
            var m: math.Mat4 = undefined;
            for (0..4) |i| for (0..4) |j| {
                m.m[i * 4 + j] = in[at + i][j];
            };
            break :blk m;
        },
        math.SoaFloat3 => .{ .x = in[at], .y = in[at + 1], .z = in[at + 2] },
        math.SoaQuaternion => .{
            .x = in[at],
            .y = in[at + 1],
            .z = in[at + 2],
            .w = in[at + 3],
        },
        math.Transform => blk: {
            var t: math.Transform = undefined;
            const bytes = std.mem.sliceAsBytes(in[at .. at + 3]);
            @memcpy(std.mem.asBytes(&t), bytes[0..@sizeOf(math.Transform)]);
            break :blk t;
        },
        else => switch (@typeInfo(T)) {
            // An integer operand travels as a float and is truncated, which is
            // what the C side does with it too.
            .int => @intFromFloat(in[at][0]),
            .bool => in[at][0] != 0,
            .array => |a| blk: {
                var v: T = undefined;
                for (&v, 0..) |*slot, i| {
                    slot.* = readArg(a.child, in, at + i * regsFor(a.child));
                }
                break :blk v;
            },
            else => @compileError("mathref: cannot read " ++ @typeName(T)),
        },
    };
}

fn writeResult(comptime T: type, out: []Reg, at: usize, value: T) void {
    switch (T) {
        F4 => out[at] = value,
        I4 => out[at] = @as(F4, @bitCast(value)),
        f32 => out[at] = @as(F4, @splat(value)),
        math.Mat4 => for (0..4) |i| for (0..4) |j| {
            out[at + i][j] = value.m[i * 4 + j];
        },
        math.SoaFloat3 => {
            out[at] = value.x;
            out[at + 1] = value.y;
            out[at + 2] = value.z;
        },
        math.SoaQuaternion => {
            out[at] = value.x;
            out[at + 1] = value.y;
            out[at + 2] = value.z;
            out[at + 3] = value.w;
        },
        math.Transform => {
            const bytes = std.mem.sliceAsBytes(out[at .. at + 3]);
            @memset(bytes, 0);
            @memcpy(bytes[0..@sizeOf(math.Transform)], std.mem.asBytes(&value));
        },
        else => switch (@typeInfo(T)) {
            .int => out[at] = @as(F4, @bitCast(I4{ @intCast(value), 0, 0, 0 })),
            .bool => out[at] = @as(F4, @bitCast(@as(I4, if (value) @splat(-1) else @splat(0)))),
            .array => |a| for (value, 0..) |slot, i| {
                writeResult(a.child, out, at + i * regsFor(a.child), slot);
            },
            else => @compileError("mathref: cannot write " ++ @typeName(T)),
        },
    }
}

/// Wraps a `math.zig` function as an `Impl`, deriving both register counts
/// from its signature.
fn adapt(comptime op: anytype) Impl {
    const info = @typeInfo(@TypeOf(op)).@"fn";
    comptime var total: usize = 0;
    inline for (info.params) |p| total += regsFor(p.type.?);
    return .{
        .eval = &struct {
            fn e(in: []const Reg, out: []Reg) void {
                var args: std.meta.ArgsTuple(@TypeOf(op)) = undefined;
                comptime var at: usize = 0;
                inline for (info.params, 0..) |p, i| {
                    args[i] = readArg(p.type.?, in, at);
                    at += comptime regsFor(p.type.?);
                }
                writeResult(info.return_type.?, out, 0, @call(.auto, op, args));
            }
        }.e,
        .in_regs = total,
        .out_regs = regsFor(info.return_type.?),
    };
}

/// For the operations whose Zig signature takes pointers or comptime lane
/// indices, where there is nothing to derive.
fn manual(
    comptime in_regs: usize,
    comptime out_regs: usize,
    comptime e: fn (in: []const Reg, out: []Reg) void,
) Impl {
    return .{ .eval = &e, .in_regs = in_regs, .out_regs = out_regs };
}

/// The pointer-taking loads. `@alignCast` holds because the register buffers
/// are declared sixteen-byte aligned.
const load = struct {
    fn ptr(in: []const Reg, out: []Reg) void {
        out[0] = math.simd_float4.loadPtr(@alignCast(&in[0]));
    }
    fn ptrU(in: []const Reg, out: []Reg) void {
        out[0] = math.simd_float4.loadPtrU(&in[0]);
    }
    fn xPtrU(in: []const Reg, out: []Reg) void {
        out[0] = math.simd_float4.loadXPtrU(&in[0][0]);
    }
    fn onePtrU(in: []const Reg, out: []Reg) void {
        out[0] = math.simd_float4.load1PtrU(&in[0][0]);
    }
    fn twoPtrU(in: []const Reg, out: []Reg) void {
        out[0] = math.simd_float4.load2PtrU(in[0][0..2]);
    }
    fn threePtrU(in: []const Reg, out: []Reg) void {
        out[0] = math.simd_float4.load3PtrU(in[0][0..3]);
    }
};

/// The partial stores. Register 1 seeds the output so the lanes a store must
/// leave alone are visible in the result rather than merely untested.
const store = struct {
    fn ptr(in: []const Reg, out: []Reg) void {
        out[0] = in[1];
        math.simd_float4.storePtr(in[0], @alignCast(&out[0]));
    }
    fn onePtr(in: []const Reg, out: []Reg) void {
        out[0] = in[1];
        math.simd_float4.store1Ptr(in[0], @alignCast(&out[0][0]));
    }
    fn twoPtr(in: []const Reg, out: []Reg) void {
        out[0] = in[1];
        math.simd_float4.store2Ptr(in[0], @alignCast(out[0][0..2]));
    }
    fn threePtr(in: []const Reg, out: []Reg) void {
        out[0] = in[1];
        math.simd_float4.store3Ptr(in[0], @alignCast(out[0][0..3]));
    }
    fn ptrU(in: []const Reg, out: []Reg) void {
        out[0] = in[1];
        math.simd_float4.storePtrU(in[0], &out[0]);
    }
    fn onePtrU(in: []const Reg, out: []Reg) void {
        out[0] = in[1];
        math.simd_float4.store1PtrU(in[0], &out[0][0]);
    }
    fn twoPtrU(in: []const Reg, out: []Reg) void {
        out[0] = in[1];
        math.simd_float4.store2PtrU(in[0], out[0][0..2]);
    }
    fn threePtrU(in: []const Reg, out: []Reg) void {
        out[0] = in[1];
        math.simd_float4.store3PtrU(in[0], out[0][0..3]);
    }
};

/// `simd_int4`'s pointer loads, the same twelve shapes as the float ones.
const loadInt = struct {
    fn asInts(in: []const Reg) *const [4]i32 {
        return @ptrCast(&in[0]);
    }
    fn ptr(in: []const Reg, out: []Reg) void {
        put(out, math.simd_int4.loadPtr(@alignCast(asInts(in))));
    }
    fn ptrU(in: []const Reg, out: []Reg) void {
        put(out, math.simd_int4.loadPtrU(asInts(in)));
    }
    fn xPtr(in: []const Reg, out: []Reg) void {
        put(out, math.simd_int4.loadXPtr(@alignCast(&asInts(in)[0])));
    }
    fn xPtrU(in: []const Reg, out: []Reg) void {
        put(out, math.simd_int4.loadXPtrU(&asInts(in)[0]));
    }
    fn onePtr(in: []const Reg, out: []Reg) void {
        put(out, math.simd_int4.load1Ptr(@alignCast(&asInts(in)[0])));
    }
    fn onePtrU(in: []const Reg, out: []Reg) void {
        put(out, math.simd_int4.load1PtrU(&asInts(in)[0]));
    }
    fn twoPtr(in: []const Reg, out: []Reg) void {
        put(out, math.simd_int4.load2Ptr(@alignCast(asInts(in)[0..2])));
    }
    fn twoPtrU(in: []const Reg, out: []Reg) void {
        put(out, math.simd_int4.load2PtrU(asInts(in)[0..2]));
    }
    fn threePtr(in: []const Reg, out: []Reg) void {
        put(out, math.simd_int4.load3Ptr(@alignCast(asInts(in)[0..3])));
    }
    fn threePtrU(in: []const Reg, out: []Reg) void {
        put(out, math.simd_int4.load3PtrU(asInts(in)[0..3]));
    }
    fn swizzleZWXY(in: []const Reg, out: []Reg) void {
        put(out, math.simd_int4.swizzle(2, 3, 0, 1, readArg(I4, in, 0)));
    }
};

fn put(out: []Reg, v: I4) void {
    writeResult(I4, out, 0, v);
}

/// The three with a shape `adapt` cannot reach: comptime lane indices, and two
/// out-parameters.
const special = struct {
    fn swizzleWZYX(in: []const Reg, out: []Reg) void {
        out[0] = math.simd_float4.swizzle(3, 2, 1, 0, in[0]);
    }
    fn mat4Invert(in: []const Reg, out: []Reg) void {
        var invertible: I4 = undefined;
        const m = readArg(math.Mat4, in, 0);
        writeResult(math.Mat4, out, 0, math.mat4.invert(m, &invertible));
        writeResult(I4, out, 4, invertible);
    }
    fn mat4ToAffine(in: []const Reg, out: []Reg) void {
        var t: F4 = undefined;
        var r: F4 = undefined;
        var s: F4 = undefined;
        const ok = math.mat4.toAffine(readArg(math.Mat4, in, 0), &t, &r, &s);
        writeResult(F4, out, 0, t);
        writeResult(F4, out, 1, r);
        writeResult(F4, out, 2, s);
        writeResult(I4, out, 3, if (ok) @as(I4, @splat(-1)) else @as(I4, @splat(0)));
    }
};

//===----------------------------------------------------------------------===//
// Inputs.
//
// A fill owns the whole input register block for its operation, because what a
// register must contain depends on where it sits: ozz asserts its own
// preconditions (a normalized axis, a rotation matrix, a cosine in range) and
// a fill that ignores them tests the assert rather than the arithmetic.
//===----------------------------------------------------------------------===//

const Fill = *const fn (rnd: std.Random, in: []Reg, iter: usize) void;

fn uniform(rnd: std.Random, lo: f32, hi: f32) f32 {
    return lo + (hi - lo) * rnd.float(f32);
}

fn away(rnd: std.Random, lo: f32, hi: f32) f32 {
    const v = uniform(rnd, lo, hi);
    return if (rnd.boolean()) v else -v;
}

fn setAny(rnd: std.Random, r: *Reg) void {
    for (r) |*v| v.* = uniform(rnd, -2, 2);
}

fn setNonZero(rnd: std.Random, r: *Reg) void {
    for (r) |*v| v.* = away(rnd, 0.25, 2);
}

fn setPositive(rnd: std.Random, r: *Reg) void {
    for (r) |*v| v.* = uniform(rnd, 0.05, 4);
}

fn setUnit(rnd: std.Random, r: *Reg, comptime lanes: usize) void {
    while (true) {
        setAny(rnd, r);
        var sum: f32 = 0;
        for (r[0..lanes]) |v| sum += v * v;
        if (sum < 1e-4) continue;
        const inv = 1.0 / @sqrt(sum);
        for (r[0..lanes]) |*v| v.* *= inv;
        return;
    }
}

fn any(rnd: std.Random, in: []Reg, iter: usize) void {
    _ = iter;
    for (in) |*r| setAny(rnd, r);
}

fn nonZero(rnd: std.Random, in: []Reg, iter: usize) void {
    _ = iter;
    for (in) |*r| setNonZero(rnd, r);
}

fn positive(rnd: std.Random, in: []Reg, iter: usize) void {
    _ = iter;
    for (in) |*r| setPositive(rnd, r);
}

fn signedUnit(rnd: std.Random, in: []Reg, iter: usize) void {
    _ = iter;
    for (in) |*r| for (r) |*v| {
        v.* = uniform(rnd, -1, 1);
    };
}

fn angles(rnd: std.Random, in: []Reg, iter: usize) void {
    _ = iter;
    for (in) |*r| for (r) |*v| {
        v.* = uniform(rnd, -std.math.pi, std.math.pi);
    };
}

fn ints(rnd: std.Random, in: []Reg, iter: usize) void {
    _ = iter;
    for (in) |*r| for (r) |*v| {
        v.* = @bitCast(rnd.intRangeAtMost(i32, -1000, 1000));
    };
}

/// A lane of a select mask is all ones or all zeroes, never anything between.
fn mask(rnd: std.Random, in: []Reg, iter: usize) void {
    _ = iter;
    for (&in[0]) |*v| v.* = @bitCast(@as(i32, if (rnd.boolean()) -1 else 0));
    setAny(rnd, &in[1]);
    setAny(rnd, &in[2]);
}

/// Full-range bit patterns: a bitwise operation that drops the high bits is
/// invisible to the small integers `ints` produces.
fn bits(rnd: std.Random, in: []Reg, iter: usize) void {
    _ = iter;
    for (in) |*r| for (r) |*v| {
        v.* = @bitCast(rnd.int(i32));
    };
}

/// Every lane all ones or all zeroes, which is the only shape ozz's own
/// predicates ever produce and the only one `AreAllTrue` is defined on.
fn laneMask(rnd: std.Random, in: []Reg, iter: usize) void {
    _ = iter;
    for (in) |*r| for (r) |*v| {
        v.* = @bitCast(@as(i32, if (rnd.boolean()) -1 else 0));
    };
}

fn boolean(rnd: std.Random, in: []Reg, iter: usize) void {
    _ = iter;
    in[0] = @splat(if (rnd.boolean()) 1 else 0);
}

/// Random floats never compare equal, so every other sample makes the second
/// operand a copy of the first with one lane moved.
fn comparable(rnd: std.Random, in: []Reg, iter: usize) void {
    setAny(rnd, &in[0]);
    if (iter % 2 == 0) {
        setAny(rnd, &in[1]);
    } else {
        in[1] = in[0];
        in[1][iter % 4] += 1;
    }
}

/// A shift count in lane 0 of the second register, over the whole legal range.
fn shift(rnd: std.Random, in: []Reg, iter: usize) void {
    for (&in[0]) |*v| v.* = @bitCast(rnd.int(i32));
    in[1] = @splat(@floatFromInt(iter % 32));
}

fn unitFill(comptime lanes: usize) Fill {
    return &struct {
        fn f(rnd: std.Random, in: []Reg, iter: usize) void {
            _ = iter;
            for (in) |*r| setUnit(rnd, r, lanes);
        }
    }.f;
}

/// Half the samples are normalized and half are not, so an `IsNormalized*`
/// answer of "no" is exercised as well as "yes".
fn maybeUnitFill(comptime lanes: usize) Fill {
    return &struct {
        fn f(rnd: std.Random, in: []Reg, iter: usize) void {
            for (in) |*r| {
                if (iter % 2 == 0) setUnit(rnd, r, lanes) else setAny(rnd, r);
            }
        }
    }.f;
}

/// `NormalizeSafe*` needs a normalized fallback, and needs the zero input that
/// selects it: every other sample is the degenerate one.
fn safeFill(comptime lanes: usize) Fill {
    return &struct {
        fn f(rnd: std.Random, in: []Reg, iter: usize) void {
            if (iter % 2 == 0) in[0] = .{ 0, 0, 0, 0 } else setAny(rnd, &in[0]);
            setUnit(rnd, &in[1], lanes);
        }
    }.f;
}

fn vec3(rnd: std.Random, in: []Reg, iter: usize) void {
    _ = iter;
    for (in) |*r| {
        setAny(rnd, r);
        r[3] = 0;
    }
}

fn unitVec3(rnd: std.Random, in: []Reg, iter: usize) void {
    _ = iter;
    for (in) |*r| {
        setUnit(rnd, r, 3);
        r[3] = 0;
    }
}

fn quats(rnd: std.Random, in: []Reg, iter: usize) void {
    _ = iter;
    for (in) |*r| setUnit(rnd, r, 4);
}

fn quatAndVector(rnd: std.Random, in: []Reg, iter: usize) void {
    _ = iter;
    setUnit(rnd, &in[0], 4);
    setAny(rnd, &in[1]);
}

/// Two Float3s in lane 0 of three registers each, then an alpha.
fn lerpTriplet(rnd: std.Random, in: []Reg, iter: usize) void {
    _ = iter;
    for (in[0..6]) |*r| r.* = @splat(uniform(rnd, -5, 5));
    in[6] = @splat(rnd.float(f32));
}

/// Two quaternions and an interpolation ratio in lane 0 of the third.
fn quatLerp(rnd: std.Random, in: []Reg, iter: usize) void {
    _ = iter;
    setUnit(rnd, &in[0], 4);
    setUnit(rnd, &in[1], 4);
    in[2] = @splat(rnd.float(f32));
}

/// A normalized axis, and an angle splatted across the second register: ozz
/// takes it as a `SimdFloat4` where only lane 0 is read, the port as an `f32`.
fn axisAngle(rnd: std.Random, in: []Reg, iter: usize) void {
    _ = iter;
    setUnit(rnd, &in[0], 3);
    in[0][3] = 0;
    in[1] = @splat(uniform(rnd, -std.math.pi, std.math.pi));
}

fn axisCosAngle(rnd: std.Random, in: []Reg, iter: usize) void {
    _ = iter;
    setUnit(rnd, &in[0], 3);
    in[0][3] = 0;
    in[1] = @splat(uniform(rnd, -1, 1));
}

/// Heading, elevation and bank in the first three lanes, ozz's `Float3`.
fn euler(rnd: std.Random, in: []Reg, iter: usize) void {
    _ = iter;
    for (in[0][0..3]) |*v| v.* = uniform(rnd, -1.5, 1.5);
    in[0][3] = 0;
}

fn setIndex(rnd: std.Random, in: []Reg, iter: usize) void {
    setAny(rnd, &in[0]);
    setAny(rnd, &in[1]);
    in[2] = @splat(@floatFromInt(iter % 4));
}

/// A rotation matrix built from scalar trigonometry only. The fixture must not
/// call the code under test to make its own inputs.
fn writeRotation(rnd: std.Random, in: []Reg, scaled: bool) void {
    var rot: Reg = undefined;
    setUnit(rnd, &rot, 4);
    const x = rot[0];
    const y = rot[1];
    const z = rot[2];
    const w = rot[3];
    var s: [3]f32 = .{ 1, 1, 1 };
    if (scaled) for (&s) |*v| {
        v.* = uniform(rnd, 0.5, 2);
    };
    in[0] = .{ (1 - 2 * (y * y + z * z)) * s[0], 2 * (x * y + z * w) * s[0], 2 * (x * z - y * w) * s[0], 0 };
    in[1] = .{ 2 * (x * y - z * w) * s[1], (1 - 2 * (x * x + z * z)) * s[1], 2 * (y * z + x * w) * s[1], 0 };
    in[2] = .{ 2 * (x * z + y * w) * s[2], 2 * (y * z - x * w) * s[2], (1 - 2 * (x * x + y * y)) * s[2], 0 };
    in[3] = .{ uniform(rnd, -5, 5), uniform(rnd, -5, 5), uniform(rnd, -5, 5), 1 };
}

fn rotation(rnd: std.Random, in: []Reg, iter: usize) void {
    _ = iter;
    writeRotation(rnd, in[0..4], false);
}

fn affine(rnd: std.Random, in: []Reg, iter: usize) void {
    _ = iter;
    writeRotation(rnd, in[0..4], true);
}

fn affineAndVector(rnd: std.Random, in: []Reg, iter: usize) void {
    _ = iter;
    writeRotation(rnd, in[0..4], true);
    setAny(rnd, &in[4]);
}

/// Half orthogonal, half not, so `IsOrthogonal` answers both ways.
fn maybeOrthogonal(rnd: std.Random, in: []Reg, iter: usize) void {
    if (iter % 2 == 0) writeRotation(rnd, in[0..4], false) else any(rnd, in, iter);
}

/// Translation, a normalized rotation and a non-zero scale, in that order.
fn affineParts(rnd: std.Random, in: []Reg, iter: usize) void {
    _ = iter;
    setAny(rnd, &in[0]);
    setUnit(rnd, &in[1], 4);
    setNonZero(rnd, &in[2]);
}

/// Two `Transform`s: ten floats each over three registers, the last two lanes
/// unused, so the padding is written rather than left undefined.
fn transforms(rnd: std.Random, in: []Reg, iter: usize) void {
    _ = iter;
    for (0..2) |t| {
        const at = t * 3;
        var rot: Reg = undefined;
        setUnit(rnd, &rot, 4);
        in[at] = .{ uniform(rnd, -5, 5), uniform(rnd, -5, 5), uniform(rnd, -5, 5), rot[0] };
        in[at + 1] = .{ rot[1], rot[2], rot[3], away(rnd, 0.5, 2) };
        in[at + 2] = .{ away(rnd, 0.5, 2), away(rnd, 0.5, 2), 0, 0 };
    }
}

//===----------------------------------------------------------------------===//
// The table. One row per operation in tests/mathref.h, and a comptime gate
// below that says so.
//===----------------------------------------------------------------------===//

const Case = struct {
    name: []const u8,
    impl: Impl,
    fill: Fill = &any,
    tol: f32 = exact,
    /// Lanes of each output register ozz defines, when it does not define all
    /// four. Its own two backends disagree on the rest, so comparing them
    /// would be comparing nothing -- see the note above `cases`.
    defined: []const u8 = &.{},
};

/// Lane 0 only: ozz documents y, z and w of the result as undefined, and its
/// SSE and reference backends do leave different values there.
const lane_x: []const u8 = &.{1};

/// Lane 0 only, for a second reason: ozz's SSE RcpEstX and RSqrtEstX are a
/// bare _mm_rcp_ss / _mm_rsqrt_ss, whose upper lanes hold whatever the
/// compiler left there. Measured, Zig 0.16 clang, x86_64-windows-gnu:
/// pass-through at -O0/-O2/-O3, zero at -Os. What varies with the optimiser
/// is not a reference; the port's own upper lanes are pinned instead, in
/// src/math_test.zig.
const lane_x_estimate: []const u8 = &.{1};

const sf = math.simd_float4;
const q = math.quaternion;
const m4 = math.mat4;
const s3 = math.soa_float3;
const sq = math.soa_quaternion;
const si = math.simd_int4;

const cases = [_]Case{
    .{ .name = "MADD", .impl = adapt(sf.mAdd), .tol = rounding },
    .{ .name = "MSUB", .impl = adapt(sf.mSub), .tol = rounding },
    .{ .name = "NMADD", .impl = adapt(sf.nMAdd), .tol = rounding },
    .{ .name = "NMSUB", .impl = adapt(sf.nMSub), .tol = rounding },
    .{ .name = "DIVX", .impl = adapt(sf.divX), .fill = &nonZero },
    .{ .name = "HADD2", .impl = adapt(sf.hAdd2), .defined = lane_x },
    .{ .name = "HADD3", .impl = adapt(sf.hAdd3), .tol = rounding, .defined = lane_x },
    .{ .name = "HADD4", .impl = adapt(sf.hAdd4), .tol = rounding, .defined = lane_x },
    .{ .name = "SQRT", .impl = adapt(sf.sqrt), .fill = &positive },
    .{ .name = "SQRTX", .impl = adapt(sf.sqrtX), .fill = &positive },
    .{ .name = "ABS", .impl = adapt(sf.abs) },
    .{ .name = "MIN0", .impl = adapt(sf.min0) },
    .{ .name = "MAX0", .impl = adapt(sf.max0) },
    .{ .name = "FROMINT", .impl = adapt(sf.fromInt), .fill = &ints },
    .{ .name = "SELECT", .impl = adapt(sf.select), .fill = &mask },

    .{ .name = "DOT2", .impl = adapt(sf.dot2), .tol = rounding, .defined = lane_x },
    .{ .name = "DOT3", .impl = adapt(sf.dot3), .tol = rounding, .defined = lane_x },
    .{ .name = "DOT4", .impl = adapt(sf.dot4), .tol = rounding, .defined = lane_x },
    .{ .name = "CROSS3", .impl = adapt(sf.cross3), .tol = rounding, .defined = &.{3} },
    .{ .name = "LENGTH2", .impl = adapt(sf.length2), .tol = rounding, .defined = lane_x },
    .{ .name = "LENGTH3", .impl = adapt(sf.length3), .tol = rounding, .defined = lane_x },
    .{ .name = "LENGTH4", .impl = adapt(sf.length4), .tol = rounding, .defined = lane_x },
    .{ .name = "LENGTH2SQR", .impl = adapt(sf.length2Sqr), .tol = rounding, .defined = lane_x },
    .{ .name = "LENGTH3SQR", .impl = adapt(sf.length3Sqr), .tol = rounding, .defined = lane_x },
    .{ .name = "LENGTH4SQR", .impl = adapt(sf.length4Sqr), .tol = rounding, .defined = lane_x },
    .{ .name = "NORMALIZE2", .impl = adapt(sf.normalize2), .fill = &nonZero, .tol = rounding },
    .{ .name = "NORMALIZE3", .impl = adapt(sf.normalize3), .fill = &nonZero, .tol = rounding },
    .{ .name = "NORMALIZE4", .impl = adapt(sf.normalize4), .fill = &nonZero, .tol = rounding },
    .{ .name = "NORMALIZESAFE2", .impl = adapt(sf.normalizeSafe2), .fill = safeFill(2), .defined = &.{2} },
    .{ .name = "NORMALIZESAFE3", .impl = adapt(sf.normalizeSafe3), .fill = safeFill(3), .defined = &.{3} },
    .{ .name = "NORMALIZESAFE4", .impl = adapt(sf.normalizeSafe4), .fill = safeFill(4), .tol = rounding },
    .{ .name = "ISNORMALIZED2", .impl = adapt(sf.isNormalized2), .fill = maybeUnitFill(2) },
    .{ .name = "ISNORMALIZED3", .impl = adapt(sf.isNormalized3), .fill = maybeUnitFill(3) },
    .{ .name = "ISNORMALIZED4", .impl = adapt(sf.isNormalized4), .fill = maybeUnitFill(4) },

    .{ .name = "RCPEST", .impl = adapt(sf.rcpEst), .fill = &nonZero, .tol = est },
    .{ .name = "RCPESTNR", .impl = adapt(sf.rcpEstNR), .fill = &nonZero, .tol = est },
    .{ .name = "RCPESTX", .impl = adapt(sf.rcpEstX), .fill = &nonZero, .tol = est, .defined = lane_x_estimate },
    .{ .name = "RCPESTXNR", .impl = adapt(sf.rcpEstXNR), .fill = &nonZero, .tol = est, .defined = lane_x },
    .{ .name = "RSQRTEST", .impl = adapt(sf.rSqrtEst), .fill = &positive, .tol = est },
    .{ .name = "RSQRTESTNR", .impl = adapt(sf.rSqrtEstNR), .fill = &positive, .tol = est },
    .{ .name = "RSQRTESTX", .impl = adapt(sf.rSqrtEstX), .fill = &positive, .tol = est, .defined = lane_x_estimate },
    .{ .name = "RSQRTESTXNR", .impl = adapt(sf.rSqrtEstXNR), .fill = &positive, .tol = est, .defined = lane_x },
    .{ .name = "NORMALIZEEST2", .impl = adapt(sf.normalizeEst2), .fill = &nonZero, .tol = est },
    .{ .name = "NORMALIZEEST3", .impl = adapt(sf.normalizeEst3), .fill = &nonZero, .tol = est },
    .{ .name = "NORMALIZEEST4", .impl = adapt(sf.normalizeEst4), .fill = &nonZero, .tol = est },
    .{ .name = "NORMALIZESAFEEST2", .impl = adapt(sf.normalizeSafeEst2), .fill = safeFill(2), .tol = est, .defined = &.{2} },
    .{ .name = "NORMALIZESAFEEST3", .impl = adapt(sf.normalizeSafeEst3), .fill = safeFill(3), .tol = est, .defined = &.{3} },
    .{ .name = "NORMALIZESAFEEST4", .impl = adapt(sf.normalizeSafeEst4), .fill = safeFill(4), .tol = est },
    .{ .name = "ISNORMALIZEDEST2", .impl = adapt(sf.isNormalizedEst2), .fill = maybeUnitFill(2) },
    .{ .name = "ISNORMALIZEDEST3", .impl = adapt(sf.isNormalizedEst3), .fill = maybeUnitFill(3) },
    .{ .name = "ISNORMALIZEDEST4", .impl = adapt(sf.isNormalizedEst4), .fill = maybeUnitFill(4) },

    .{ .name = "COS", .impl = adapt(sf.cos), .fill = &angles, .tol = trig },
    .{ .name = "COSX", .impl = adapt(sf.cosX), .fill = &angles, .tol = trig },
    .{ .name = "SIN", .impl = adapt(sf.sin), .fill = &angles, .tol = trig },
    .{ .name = "SINX", .impl = adapt(sf.sinX), .fill = &angles, .tol = trig },
    .{ .name = "TAN", .impl = adapt(sf.tan), .fill = &angles, .tol = trig },
    .{ .name = "TANX", .impl = adapt(sf.tanX), .fill = &angles, .tol = trig },
    .{ .name = "ACOS", .impl = adapt(sf.aCos), .fill = &signedUnit, .tol = trig },
    .{ .name = "ACOSX", .impl = adapt(sf.aCosX), .fill = &signedUnit, .tol = trig },
    .{ .name = "ASIN", .impl = adapt(sf.aSin), .fill = &signedUnit, .tol = trig },
    .{ .name = "ASINX", .impl = adapt(sf.aSinX), .fill = &signedUnit, .tol = trig },
    .{ .name = "ATAN", .impl = adapt(sf.aTan), .tol = trig },
    .{ .name = "ATANX", .impl = adapt(sf.aTanX), .tol = trig },

    .{ .name = "LOADX", .impl = adapt(sf.loadX) },
    .{ .name = "LOAD1", .impl = adapt(sf.load1) },
    .{ .name = "LOADPTR", .impl = manual(1, 1, load.ptr) },
    .{ .name = "LOADPTRU", .impl = manual(1, 1, load.ptrU) },
    .{ .name = "LOADXPTRU", .impl = manual(1, 1, load.xPtrU) },
    .{ .name = "LOAD1PTRU", .impl = manual(1, 1, load.onePtrU) },
    .{ .name = "LOAD2PTRU", .impl = manual(1, 1, load.twoPtrU) },
    .{ .name = "LOAD3PTRU", .impl = manual(1, 1, load.threePtrU) },
    .{ .name = "GETX", .impl = adapt(sf.x) },
    .{ .name = "GETY", .impl = adapt(sf.y) },
    .{ .name = "GETZ", .impl = adapt(sf.z) },
    .{ .name = "GETW", .impl = adapt(sf.w) },
    .{ .name = "SETX", .impl = adapt(sf.withX) },
    .{ .name = "SETY", .impl = adapt(sf.withY) },
    .{ .name = "SETZ", .impl = adapt(sf.withZ) },
    .{ .name = "SETW", .impl = adapt(sf.withW) },
    .{ .name = "SETI", .impl = adapt(sf.withI), .fill = &setIndex },
    .{ .name = "SPLATX", .impl = adapt(sf.splatX) },
    .{ .name = "SPLATY", .impl = adapt(sf.splatY) },
    .{ .name = "SPLATZ", .impl = adapt(sf.splatZ) },
    .{ .name = "SPLATW", .impl = adapt(sf.splatW) },
    .{ .name = "SWIZZLEWZYX", .impl = manual(1, 1, special.swizzleWZYX) },
    .{ .name = "STOREPTR", .impl = manual(2, 1, store.ptr) },
    .{ .name = "STORE1PTR", .impl = manual(2, 1, store.onePtr) },
    .{ .name = "STORE2PTR", .impl = manual(2, 1, store.twoPtr) },
    .{ .name = "STORE3PTR", .impl = manual(2, 1, store.threePtr) },
    .{ .name = "STOREPTRU", .impl = manual(2, 1, store.ptrU) },
    .{ .name = "STORE1PTRU", .impl = manual(2, 1, store.onePtrU) },
    .{ .name = "STORE2PTRU", .impl = manual(2, 1, store.twoPtrU) },
    .{ .name = "STORE3PTRU", .impl = manual(2, 1, store.threePtrU) },

    .{ .name = "TRANSPOSE4X1", .impl = adapt(sf.transpose4x1) },
    .{ .name = "TRANSPOSE1X4", .impl = adapt(sf.transpose1x4) },
    .{ .name = "TRANSPOSE4X2", .impl = adapt(sf.transpose4x2) },
    .{ .name = "TRANSPOSE2X4", .impl = adapt(sf.transpose2x4) },
    .{ .name = "TRANSPOSE4X3", .impl = adapt(sf.transpose4x3) },
    .{ .name = "TRANSPOSE3X4", .impl = adapt(sf.transpose3x4) },
    .{ .name = "TRANSPOSE4X4", .impl = adapt(sf.transpose4x4) },
    .{ .name = "TRANSPOSE16X16", .impl = adapt(sf.transpose16x16) },

    .{ .name = "QUATCONJUGATE", .impl = adapt(q.conjugate), .fill = &quats },
    .{ .name = "QUATMUL", .impl = adapt(q.mul), .fill = &quats, .tol = rounding },
    .{ .name = "QUATTRANSFORMVECTOR", .impl = adapt(q.transformVector), .fill = &quatAndVector, .tol = rounding },
    .{ .name = "QUATNLERP", .impl = adapt(q.nlerp), .fill = &quatLerp, .tol = rounding },
    .{ .name = "QUATSLERP", .impl = adapt(q.slerp), .fill = &quatLerp, .tol = rounding },
    .{ .name = "QUATFROMAXISANGLE", .impl = adapt(q.fromAxisAngle), .fill = &axisAngle, .tol = trig },
    .{ .name = "QUATFROMAXISCOSANGLE", .impl = adapt(q.fromAxisCosAngle), .fill = &axisCosAngle, .tol = rounding },
    .{ .name = "QUATTOAXISANGLE", .impl = adapt(q.toAxisAngle), .fill = &quats, .tol = trig },
    .{ .name = "QUATFROMVECTORS", .impl = adapt(q.fromVectors), .fill = &vec3, .tol = rounding },
    .{ .name = "QUATFROMUNITVECTORS", .impl = adapt(q.fromUnitVectors), .fill = &unitVec3, .tol = rounding },
    .{ .name = "QUATFROMEULER", .impl = adapt(q.fromEuler), .fill = &euler, .tol = trig },
    .{ .name = "QUATTOEULER", .impl = adapt(q.toEuler), .fill = &quats, .tol = trig },

    .{ .name = "MAT4TRANSPOSE", .impl = adapt(m4.transpose) },
    .{ .name = "MAT4INVERT", .impl = manual(4, 5, special.mat4Invert), .fill = &affine, .tol = composed, .defined = &.{ 4, 4, 4, 4, 1 } },
    .{ .name = "MAT4COLUMNMULTIPLY", .impl = adapt(m4.columnMultiply) },
    .{ .name = "MAT4SCALING", .impl = adapt(m4.scaling) },
    .{ .name = "MAT4TRANSLATE", .impl = adapt(m4.translate), .tol = rounding },
    .{ .name = "MAT4ISORTHOGONAL", .impl = adapt(m4.isOrthogonal), .fill = &maybeOrthogonal },
    .{ .name = "MAT4TRANSFORMPOINT", .impl = adapt(m4.transformPoint), .fill = &affineAndVector, .tol = rounding },
    .{ .name = "MAT4TRANSFORMVECTOR", .impl = adapt(m4.transformVector), .fill = &affineAndVector, .tol = rounding },
    .{ .name = "MAT4FROMAFFINE", .impl = adapt(m4.fromAffine), .fill = &affineParts, .tol = rounding },
    .{ .name = "MAT4TOAFFINE", .impl = manual(4, 4, special.mat4ToAffine), .fill = &affine, .tol = rounding },
    .{ .name = "MAT4FROMQUATERNION", .impl = adapt(m4.fromQuaternion), .fill = &quats, .tol = rounding },
    .{ .name = "MAT4TOQUATERNION", .impl = adapt(m4.toQuaternion), .fill = &rotation, .tol = rounding },
    .{ .name = "MAT4MULVEC", .impl = adapt(m4.mulVec), .fill = &affineAndVector, .tol = rounding },
    .{ .name = "MAT4MUL", .impl = adapt(m4.mul), .tol = rounding },
    .{ .name = "MAT4ADD", .impl = adapt(m4.add) },
    .{ .name = "MAT4SUB", .impl = adapt(m4.sub) },

    .{ .name = "TRANSFORMMUL", .impl = adapt(math.transform.mul), .fill = &transforms, .tol = composed },

    .{ .name = "SOAFLOAT3ADD", .impl = adapt(s3.add) },
    .{ .name = "SOAFLOAT3SUB", .impl = adapt(s3.sub) },
    .{ .name = "SOAFLOAT3NEG", .impl = adapt(s3.neg) },
    .{ .name = "SOAFLOAT3MUL", .impl = adapt(s3.mul) },
    .{ .name = "SOAFLOAT3MULSCALAR", .impl = adapt(s3.mulScalar) },
    .{ .name = "SOAFLOAT3DIV", .impl = adapt(s3.div), .fill = &nonZero },
    .{ .name = "SOAFLOAT3DIVSCALAR", .impl = adapt(s3.divScalar), .fill = &nonZero },
    .{ .name = "SOAFLOAT3LT", .impl = adapt(s3.lt) },
    .{ .name = "SOAFLOAT3LE", .impl = adapt(s3.le) },
    .{ .name = "SOAFLOAT3GT", .impl = adapt(s3.gt) },
    .{ .name = "SOAFLOAT3GE", .impl = adapt(s3.ge) },
    .{ .name = "SOAFLOAT3EQ", .impl = adapt(s3.eq) },
    .{ .name = "SOAFLOAT3NE", .impl = adapt(s3.ne) },

    .{ .name = "SOAQUATNEG", .impl = adapt(sq.neg) },
    .{ .name = "SOAQUATCONJUGATE", .impl = adapt(sq.conjugate) },
    .{ .name = "SOAQUATADD", .impl = adapt(sq.add) },
    .{ .name = "SOAQUATMUL", .impl = adapt(sq.mul), .tol = rounding },
    .{ .name = "SOAQUATMULSCALAR", .impl = adapt(sq.mulScalar) },
    .{ .name = "SOAQUATDOT", .impl = adapt(sq.dot), .tol = rounding },
    .{ .name = "SOAQUATEQ", .impl = adapt(sq.eq) },

    .{ .name = "INTALLTRUE", .impl = adapt(si.all_true) },
    .{ .name = "INTALLFALSE", .impl = adapt(si.all_false) },
    .{ .name = "INTMASKSIGN", .impl = adapt(si.mask_sign) },
    .{ .name = "INTMASKSIGNXYZ", .impl = adapt(si.mask_sign_xyz) },
    .{ .name = "INTMASKSIGNW", .impl = adapt(si.mask_sign_w) },
    .{ .name = "INTMASKNOTSIGN", .impl = adapt(si.mask_not_sign) },
    .{ .name = "INTMASKFFFF", .impl = adapt(si.mask_ffff) },
    .{ .name = "INTMASK0000", .impl = adapt(si.mask_0000) },
    .{ .name = "INTMASKFFF0", .impl = adapt(si.mask_fff0) },
    .{ .name = "INTMASKF000", .impl = adapt(si.mask_f000) },
    .{ .name = "INTMASK0F00", .impl = adapt(si.mask_0f00) },
    .{ .name = "INTMASK00F0", .impl = adapt(si.mask_00f0) },
    .{ .name = "INTMASK000F", .impl = adapt(si.mask_000f) },

    .{ .name = "INTLOADX", .impl = adapt(si.loadX), .fill = &boolean },
    .{ .name = "INTLOAD1", .impl = adapt(si.load1), .fill = &boolean },
    .{ .name = "INTLOADPTR", .impl = manual(1, 1, loadInt.ptr), .fill = &bits },
    .{ .name = "INTLOADPTRU", .impl = manual(1, 1, loadInt.ptrU), .fill = &bits },
    .{ .name = "INTLOADXPTR", .impl = manual(1, 1, loadInt.xPtr), .fill = &bits },
    .{ .name = "INTLOADXPTRU", .impl = manual(1, 1, loadInt.xPtrU), .fill = &bits },
    .{ .name = "INTLOAD1PTR", .impl = manual(1, 1, loadInt.onePtr), .fill = &bits },
    .{ .name = "INTLOAD1PTRU", .impl = manual(1, 1, loadInt.onePtrU), .fill = &bits },
    .{ .name = "INTLOAD2PTR", .impl = manual(1, 1, loadInt.twoPtr), .fill = &bits },
    .{ .name = "INTLOAD2PTRU", .impl = manual(1, 1, loadInt.twoPtrU), .fill = &bits },
    .{ .name = "INTLOAD3PTR", .impl = manual(1, 1, loadInt.threePtr), .fill = &bits },
    .{ .name = "INTLOAD3PTRU", .impl = manual(1, 1, loadInt.threePtrU), .fill = &bits },
    .{ .name = "INTFROMFLOATROUND", .impl = adapt(si.fromFloatRound) },
    .{ .name = "INTFROMFLOATTRUNC", .impl = adapt(si.fromFloatTrunc) },

    .{ .name = "INTAND", .impl = adapt(si.@"and"), .fill = &bits },
    .{ .name = "INTXOR", .impl = adapt(si.xor), .fill = &bits },
    .{ .name = "INTNOT", .impl = adapt(si.not), .fill = &bits },
    .{ .name = "INTANDNOT", .impl = adapt(si.andNot), .fill = &bits },
    .{ .name = "INTCMPLT", .impl = adapt(si.cmpLt), .fill = &comparable },
    .{ .name = "INTCMPLE", .impl = adapt(si.cmpLe), .fill = &comparable },
    .{ .name = "INTCMPGT", .impl = adapt(si.cmpGt), .fill = &comparable },
    .{ .name = "INTCMPGE", .impl = adapt(si.cmpGe), .fill = &comparable },
    .{ .name = "INTCMPEQ", .impl = adapt(si.cmpEq), .fill = &comparable },
    .{ .name = "INTCMPNE", .impl = adapt(si.cmpNe), .fill = &comparable },
    .{ .name = "INTSIGN", .impl = adapt(si.sign) },
    .{ .name = "INTAREALLTRUE", .impl = adapt(si.areAllTrue), .fill = &laneMask },
    .{ .name = "INTAREALLTRUE3", .impl = adapt(si.areAllTrue3), .fill = &laneMask },
    .{ .name = "INTAREALLTRUE2", .impl = adapt(si.areAllTrue2), .fill = &laneMask },
    .{ .name = "INTAREALLTRUE1", .impl = adapt(si.areAllTrue1), .fill = &laneMask },
    .{ .name = "INTAREALLFALSE", .impl = adapt(si.areAllFalse), .fill = &laneMask },
    .{ .name = "INTAREALLFALSE3", .impl = adapt(si.areAllFalse3), .fill = &laneMask },
    .{ .name = "INTAREALLFALSE2", .impl = adapt(si.areAllFalse2), .fill = &laneMask },
    .{ .name = "INTAREALLFALSE1", .impl = adapt(si.areAllFalse1), .fill = &laneMask },
    .{ .name = "INTMOVEMASK", .impl = adapt(si.moveMask), .fill = &laneMask },
    .{ .name = "INTSWIZZLEZWXY", .impl = manual(1, 1, loadInt.swizzleZWXY), .fill = &bits },
    .{ .name = "INTSHIFTL", .impl = adapt(si.shiftL), .fill = &shift },
    .{ .name = "INTSHIFTR", .impl = adapt(si.shiftR), .fill = &shift },
    .{ .name = "INTSHIFTRU", .impl = adapt(si.shiftRu), .fill = &shift },

    .{ .name = "ZERO", .impl = adapt(sf.zero) },
    .{ .name = "ONE", .impl = adapt(sf.one) },
    .{ .name = "XAXIS", .impl = adapt(sf.x_axis) },
    .{ .name = "YAXIS", .impl = adapt(sf.y_axis) },
    .{ .name = "ZAXIS", .impl = adapt(sf.z_axis) },
    .{ .name = "WAXIS", .impl = adapt(sf.w_axis) },

    .{ .name = "LERPTRANSLATION", .impl = adapt(math.lerpTranslation), .fill = &lerpTriplet, .tol = rounding },
    .{ .name = "LERPSCALE", .impl = adapt(math.lerpScale), .fill = &lerpTriplet, .tol = rounding },
    .{ .name = "LERPROTATION", .impl = adapt(math.lerpRotation), .fill = &quatLerp, .tol = rounding },
};

/// Resolved once, at comptime: a row naming an operation the header does not
/// declare is a compile error rather than a lookup that fails at run time.
const ids = blk: {
    @setEvalBranchQuota(100_000);
    var out: [cases.len]c_int = undefined;
    for (cases, 0..) |cs, i| out[i] = @field(ref, "ZOZZ_MATHREF_" ++ cs.name);
    break :blk out;
};

comptime {
    @setEvalBranchQuota(100_000);
    if (cases.len != ref.ZOZZ_MATHREF_OP_COUNT) {
        @compileError("mathref: tests/mathref.h declares a different number of " ++
            "operations than src/mathref_test.zig has rows for");
    }
    for (@typeInfo(ref).@"struct".decls) |d| {
        if (!std.mem.startsWith(u8, d.name, "ZOZZ_MATHREF_")) continue;
        // The X-macro list and the count sentinel are the header's only two
        // ZOZZ_MATHREF_ names that are not operations.
        if (std.mem.eql(u8, d.name, "ZOZZ_MATHREF_OPS")) continue;
        if (std.mem.eql(u8, d.name, "ZOZZ_MATHREF_OP_COUNT")) continue;
        const want = d.name["ZOZZ_MATHREF_".len..];
        var found = false;
        for (cases) |cs| {
            if (std.mem.eql(u8, cs.name, want)) found = true;
        }
        if (!found) @compileError("mathref: no row for " ++ d.name);
    }
}

/// Relative deviation, with the non-finite cases decided rather than divided:
/// two NaNs agree, and a NaN facing a number never does.
fn deviation(a: f32, b: f32) f32 {
    if (@as(u32, @bitCast(a)) == @as(u32, @bitCast(b))) return 0;
    const a_nan = std.math.isNan(a);
    const b_nan = std.math.isNan(b);
    if (a_nan and b_nan) return 0;
    if (a_nan or b_nan or std.math.isInf(a) or std.math.isInf(b)) {
        return std.math.inf(f32);
    }
    return @abs(a - b) / @max(1.0, @abs(b));
}

/// Where the worst deviation was. A bare magnitude says an operation
/// disagrees; this says which lane of which output register, on which input,
/// and what each side produced.
const Site = struct {
    iter: usize = 0,
    reg: usize = 0,
    lane: usize = 0,
    got: f32 = 0,
    want: f32 = 0,
    in_count: usize = 0,
    in: [max_regs]Reg = @splat(@splat(0)),

    fn report(self: Site, name: []const u8, worst: f32, tol: f32) void {
        std.debug.print(
            "mathref: {s} deviates by {e} (tolerance {e})\n" ++
                "  iteration {d}, out register {d}, lane {d}: zozz {e} vs ozz {e}\n",
            .{ name, worst, tol, self.iter, self.reg, self.lane, self.got, self.want },
        );
        for (self.in[0..self.in_count], 0..) |r, i| {
            std.debug.print("  in[{d}] = {{ {e}, {e}, {e}, {e} }}\n", .{ i, r[0], r[1], r[2], r[3] });
        }
    }
};

test "src/math.zig agrees with the ozz it ports, operation by operation" {
    var prng = std.Random.DefaultPrng.init(seed);
    const rnd = prng.random();

    var in: [max_regs]Reg align(16) = undefined;
    var want: [max_regs]Reg align(16) = undefined;
    var got: [max_regs]Reg align(16) = undefined;

    var failed: usize = 0;
    for (cases, ids) |cs, id| {
        var c_in: usize = 0;
        var c_out: usize = 0;
        try std.testing.expectEqual(@as(c_int, 0), ref.zozzMathRefArity(id, &c_in, &c_out));
        try std.testing.expectEqual(cs.impl.in_regs, c_in);
        try std.testing.expectEqual(cs.impl.out_regs, c_out);
        if (cs.defined.len != 0) try std.testing.expectEqual(c_out, cs.defined.len);

        var worst: f32 = 0;
        var site: Site = .{};
        for (0..iterations) |iter| {
            @memset(std.mem.sliceAsBytes(in[0..]), 0);
            cs.fill(rnd, in[0..c_in], iter);
            @memset(std.mem.sliceAsBytes(want[0..]), 0);
            @memset(std.mem.sliceAsBytes(got[0..]), 0);

            const rc = ref.zozzMathRefEval(id, &in, c_in, &want, c_out);
            try std.testing.expectEqual(@as(c_int, 0), rc);
            cs.impl.eval(in[0..c_in], got[0..c_out]);

            for (0..c_out) |r| {
                const lanes = if (cs.defined.len == 0) 4 else cs.defined[r];
                for (0..lanes) |lane| {
                    const d = deviation(got[r][lane], want[r][lane]);
                    if (d > worst) {
                        worst = d;
                        site = .{
                            .iter = iter,
                            .reg = r,
                            .lane = lane,
                            .got = got[r][lane],
                            .want = want[r][lane],
                            .in_count = c_in,
                            .in = in,
                        };
                    }
                }
            }
        }
        if (!(worst <= cs.tol)) {
            site.report(cs.name, worst, cs.tol);
            failed += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), failed);
}
