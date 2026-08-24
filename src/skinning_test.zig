//! Behavioural tests for matrix-palette skinning
//! (`ozz::geometry::SkinningJob`).
//!
//! Every expectation here is computed independently, by multiplying the
//! column-major matrix by the vertex in Zig, rather than by comparing the job
//! against itself. That is the only way a skinning test says anything: a
//! vertex "moved" is worthless, a vertex that landed exactly where the matrix
//! puts it is the whole contract.
//!
//! Buffers are tightly packed (3 floats per vertex, 12-byte stride). ozz
//! measures every span in BYTES against its stride, so the counts below are
//! float counts and the strides are byte counts — mixing the two is the
//! mistake this layout makes visible.

const std = @import("std");
const zozz = @import("zozz.zig");

const float3_stride = 3 * @sizeOf(f32);

/// A column-major transform: rotation of `angle` about Z, then translation.
/// `m[0..4]` is the first COLUMN, so the translation lives in `m[12..15]`.
fn rotateZThenTranslate(angle: f32, t: [3]f32) zozz.Mat4 {
    const cos = @cos(angle);
    const sin = @sin(angle);
    return .{ .m = .{
        cos,  sin,  0,    0,
        -sin, cos,  0,    0,
        0,    0,    1,    0,
        t[0], t[1], t[2], 1,
    } };
}

/// A column-major diagonal scale with a translation.
fn scaleThenTranslate(s: [3]f32, t: [3]f32) zozz.Mat4 {
    return .{ .m = .{
        s[0], 0,    0,    0,
        0,    s[1], 0,    0,
        0,    0,    s[2], 0,
        t[0], t[1], t[2], 1,
    } };
}

/// Applies `m` to a POINT: the translation column counts.
fn transformPoint(m: zozz.Mat4, v: [3]f32) [3]f32 {
    return .{
        m.m[0] * v[0] + m.m[4] * v[1] + m.m[8] * v[2] + m.m[12],
        m.m[1] * v[0] + m.m[5] * v[1] + m.m[9] * v[2] + m.m[13],
        m.m[2] * v[0] + m.m[6] * v[1] + m.m[10] * v[2] + m.m[14],
    };
}

/// Applies `m` to a DIRECTION: the translation column does not.
fn transformVector(m: zozz.Mat4, v: [3]f32) [3]f32 {
    return .{
        m.m[0] * v[0] + m.m[4] * v[1] + m.m[8] * v[2],
        m.m[1] * v[0] + m.m[5] * v[1] + m.m[9] * v[2],
        m.m[2] * v[0] + m.m[6] * v[1] + m.m[10] * v[2],
    };
}

fn expectVec3(expected: [3]f32, actual: [3]f32, tolerance: f32) !void {
    for (expected, actual) |e, a| try std.testing.expectApproxEqAbs(e, a, tolerance);
}

fn normalize(v: [3]f32) [3]f32 {
    const len = @sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
    return .{ v[0] / len, v[1] / len, v[2] / len };
}

test "a single-influence vertex lands exactly where its joint matrix puts it" {
    const gpa = std.testing.allocator;
    try zozz.setAllocator(gpa);
    defer zozz.resetAllocator();

    // Two joints doing visibly different things, so a job that silently used
    // joint 0 for everything would be caught.
    const joints = [_]zozz.Mat4{
        rotateZThenTranslate(std.math.pi / 2.0, .{ 10, 0, 0 }),
        scaleThenTranslate(.{ 2, 2, 2 }, .{ 0, -5, 1 }),
    };

    const vertex_count = 3;
    const in_positions = [_]f32{
        1, 0,  0,
        0, 1,  0,
        3, -2, 4,
    };
    // Vertices 0 and 2 ride joint 0; vertex 1 rides joint 1.
    const indices = [_]u16{ 0, 1, 0 };

    var out_positions: [vertex_count * 3]f32 = undefined;
    try (zozz.skinning.Job{
        .vertex_count = vertex_count,
        .influences_count = 1,
        .joint_matrices = &joints,
        .joint_indices = &indices,
        .joint_indices_stride = 1 * @sizeOf(u16),
        .in_positions = .{ .data = &in_positions, .stride = float3_stride },
        .out_positions = .{ .data = &out_positions, .stride = float3_stride },
    }).run();

    for (0..vertex_count) |v| {
        const source: [3]f32 = in_positions[v * 3 ..][0..3].*;
        const expected = transformPoint(joints[indices[v]], source);
        try expectVec3(expected, out_positions[v * 3 ..][0..3].*, 1e-5);
    }

    // And one worked by hand, so the loop above cannot pass by reproducing
    // the same wrong multiplication twice: (1, 0, 0) turned a quarter turn
    // about Z is (0, 1, 0), then translated by (10, 0, 0) is (10, 1, 0).
    try expectVec3(.{ 10, 1, 0 }, out_positions[0..3].*, 1e-5);
}

test "two influences summing to 1 interpolate between the two single-joint results" {
    const gpa = std.testing.allocator;
    try zozz.setAllocator(gpa);
    defer zozz.resetAllocator();

    const joints = [_]zozz.Mat4{
        rotateZThenTranslate(std.math.pi / 2.0, .{ 10, 0, 0 }),
        rotateZThenTranslate(-std.math.pi / 3.0, .{ -4, 7, 2 }),
    };

    const vertex_count = 4;
    const in_positions = [_]f32{
        1,   0,   0,
        0,   1,   0,
        3,   -2,  4,
        0.5, 0.5, -1,
    };
    // Weight on the FIRST joint, one per vertex; the second joint's weight is
    // recovered as 1 - w. The 0 and 1 ends are the interesting ones: they
    // must reproduce a single-joint result exactly.
    const first_weights = [_]f32{ 0, 0.25, 0.5, 1 };

    var indices: [vertex_count * 2]u16 = undefined;
    for (0..vertex_count) |v| {
        indices[v * 2 + 0] = 0;
        indices[v * 2 + 1] = 1;
    }

    var blended: [vertex_count * 3]f32 = undefined;
    try (zozz.skinning.Job{
        .vertex_count = vertex_count,
        .influences_count = 2,
        .joint_matrices = &joints,
        .joint_indices = &indices,
        .joint_indices_stride = 2 * @sizeOf(u16),
        .joint_weights = &first_weights,
        .joint_weights_stride = 1 * @sizeOf(f32),
        .in_positions = .{ .data = &in_positions, .stride = float3_stride },
        .out_positions = .{ .data = &blended, .stride = float3_stride },
    }).run();

    for (0..vertex_count) |v| {
        const source: [3]f32 = in_positions[v * 3 ..][0..3].*;
        const w = first_weights[v];
        const from_joint_0 = transformPoint(joints[0], source);
        const from_joint_1 = transformPoint(joints[1], source);

        // Skinning blends the MATRICES, not the results — but matrix
        // application is linear in the matrix, so the two are the same thing.
        // A consumer reasoning "my vertex sits somewhere on the segment
        // between where each joint would put it" is relying on exactly that.
        var expected: [3]f32 = undefined;
        for (&expected, from_joint_0, from_joint_1) |*e, a, b| {
            e.* = w * a + (1 - w) * b;
        }
        try expectVec3(expected, blended[v * 3 ..][0..3].*, 1e-5);
    }
}

/// Runs one vertex through the job at a given influence count, padding the
/// influences past the first with joint 1 at weight 0.
fn skinPadded(
    comptime influences: u32,
    joints: []const zozz.Mat4,
    source: [3]f32,
) ![3]f32 {
    var indices: [influences]u16 = undefined;
    indices[0] = 0;
    for (indices[1..]) |*i| i.* = 1;

    // influences - 1 weights: all of joint 0's weight, nothing for the rest.
    // The last influence's weight is not stored; it is recovered as
    // 1 - sum(the others), which is 0 here.
    var weights: [if (influences > 1) influences - 1 else 1]f32 = @splat(0);
    if (influences > 1) weights[0] = 1;

    var out: [3]f32 = undefined;
    try (zozz.skinning.Job{
        .vertex_count = 1,
        .influences_count = influences,
        .joint_matrices = joints,
        .joint_indices = &indices,
        .joint_indices_stride = influences * @sizeOf(u16),
        .joint_weights = if (influences > 1) weights[0 .. influences - 1] else null,
        .joint_weights_stride = if (influences > 1) (influences - 1) * @sizeOf(f32) else 0,
        .in_positions = .{ .data = &source, .stride = float3_stride },
        .out_positions = .{ .data = &out, .stride = float3_stride },
    }).run();
    return out;
}

test "the influence-count variants agree on a vertex that only one joint moves" {
    const gpa = std.testing.allocator;
    try zozz.setAllocator(gpa);
    defer zozz.resetAllocator();

    // ozz specialises the skinning loop per influence count (1, 2, 3, 4, and
    // a generic path beyond) — five separate bodies of code that must all
    // compute the same thing. Padding with zero-weight influences is what a
    // host does when it partitions a mesh by influence count, so the variants
    // agreeing is the assumption that partitioning rests on.
    const joints = [_]zozz.Mat4{
        rotateZThenTranslate(std.math.pi / 2.0, .{ 10, 0, 0 }),
        // Wildly different, so any leakage of the padding influences shows up.
        scaleThenTranslate(.{ -3, 8, 0.25 }, .{ 100, -100, 50 }),
    };
    const source: [3]f32 = .{ 3, -2, 4 };
    const expected = transformPoint(joints[0], source);

    inline for ([_]u32{ 1, 2, 3, 4, 5 }) |influences| {
        const got = try skinPadded(influences, &joints, source);
        try expectVec3(expected, got, 1e-4);
    }
}

test "normals are transformed as directions, and the inverse-transpose set is used when given" {
    const gpa = std.testing.allocator;
    try zozz.setAllocator(gpa);
    defer zozz.resetAllocator();

    // A joint that both rotates and translates a long way.
    const rotating = [_]zozz.Mat4{rotateZThenTranslate(std.math.pi / 2.0, .{ 100, 200, 300 })};
    const indices = [_]u16{0};

    const in_positions = [_]f32{ 1, 0, 0 };
    const in_normals = [_]f32{ 1, 0, 0 };
    var out_positions: [3]f32 = undefined;
    var out_normals: [3]f32 = undefined;

    try (zozz.skinning.Job{
        .vertex_count = 1,
        .influences_count = 1,
        .joint_matrices = &rotating,
        .joint_indices = &indices,
        .joint_indices_stride = @sizeOf(u16),
        .in_positions = .{ .data = &in_positions, .stride = float3_stride },
        .in_normals = .{ .data = &in_normals, .stride = float3_stride },
        .out_positions = .{ .data = &out_positions, .stride = float3_stride },
        .out_normals = .{ .data = &out_normals, .stride = float3_stride },
    }).run();

    // The position picks up the translation; the normal must not. A normal
    // that moved by (100, 200, 300) would be meaningless, and this is the
    // single most consequential difference between the two channels.
    try expectVec3(transformPoint(rotating[0], .{ 1, 0, 0 }), out_positions, 1e-4);
    try expectVec3(.{ 0, 1, 0 }, out_normals, 1e-5);
    try expectVec3(transformVector(rotating[0], .{ 1, 0, 0 }), out_normals, 1e-5);

    // Non-uniform scale is where the two matrix sets stop agreeing. Scaling
    // X by 4 shears a 45-degree normal the WRONG way through the plain
    // matrix; the inverse transpose (1/4 on X) is what keeps it perpendicular
    // to the scaled surface.
    const stretching = [_]zozz.Mat4{scaleThenTranslate(.{ 4, 1, 1 }, .{ 0, 0, 0 })};
    const inverse_transpose = [_]zozz.Mat4{scaleThenTranslate(.{ 0.25, 1, 1 }, .{ 0, 0, 0 })};
    const diagonal_normal = [_]f32{ 1, 1, 0 };

    var without: [3]f32 = undefined;
    try (zozz.skinning.Job{
        .vertex_count = 1,
        .influences_count = 1,
        .joint_matrices = &stretching,
        .joint_indices = &indices,
        .joint_indices_stride = @sizeOf(u16),
        .in_positions = .{ .data = &in_positions, .stride = float3_stride },
        .in_normals = .{ .data = &diagonal_normal, .stride = float3_stride },
        .out_positions = .{ .data = &out_positions, .stride = float3_stride },
        .out_normals = .{ .data = &without, .stride = float3_stride },
    }).run();

    var with: [3]f32 = undefined;
    try (zozz.skinning.Job{
        .vertex_count = 1,
        .influences_count = 1,
        .joint_matrices = &stretching,
        .joint_inverse_transpose_matrices = &inverse_transpose,
        .joint_indices = &indices,
        .joint_indices_stride = @sizeOf(u16),
        .in_positions = .{ .data = &in_positions, .stride = float3_stride },
        .in_normals = .{ .data = &diagonal_normal, .stride = float3_stride },
        .out_positions = .{ .data = &out_positions, .stride = float3_stride },
        .out_normals = .{ .data = &with, .stride = float3_stride },
    }).run();

    // Output normals are NOT normalized by the job (documented), so compare
    // directions rather than components.
    try expectVec3(normalize(.{ 4, 1, 0 }), normalize(without), 1e-5);
    try expectVec3(normalize(.{ 0.25, 1, 0 }), normalize(with), 1e-5);

    // The positions are untouched by which set was used — only vectors take
    // the alternate path.
    try expectVec3(transformPoint(stretching[0], .{ 1, 0, 0 }), out_positions, 1e-5);
}
