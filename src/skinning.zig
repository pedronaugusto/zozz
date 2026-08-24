//! Matrix-palette skinning: transforming vertex positions, and optionally
//! normals and tangents, by a per-vertex weighted blend of joint matrices.

const std = @import("std");
const c = @import("c.zig");
const err = @import("error.zig");
const math = @import("math.zig");

/// A flat, read-only vertex-attribute buffer: 3 floats per vertex, plus the
/// byte stride from one vertex's attribute to the next.
pub const Channel = struct {
    data: []const f32,
    stride: usize,
};

/// The writable counterpart of `Channel`.
pub const MutChannel = struct {
    data: []f32,
    stride: usize,
};

/// Mirrors `ozz::geometry::SkinningJob`. None of these slices are retained
/// past `run`.
pub const Job = struct {
    vertex_count: u32,
    /// Joints influencing each vertex. Must be greater than 0.
    influences_count: u32,

    /// One matrix per joint, already pre-multiplied with the inverse bind
    /// pose. Indexed by `joint_indices`.
    joint_matrices: []const math.Mat4,
    /// Used instead of `joint_matrices` to transform normals/tangents when it
    /// carries non-uniform scale or shear. Null uses `joint_matrices`.
    joint_inverse_transpose_matrices: ?[]const math.Mat4 = null,

    /// `influences_count` indices per vertex, indexing `joint_matrices`.
    joint_indices: []const u16,
    joint_indices_stride: usize,
    /// `(influences_count - 1)` weights per vertex; the last influence's
    /// weight is recovered from the others summing to 1. Null only when
    /// `influences_count == 1`.
    joint_weights: ?[]const f32 = null,
    joint_weights_stride: usize = 0,

    in_positions: Channel,
    /// Requires `out_normals`.
    in_normals: ?Channel = null,
    /// Requires `in_normals` and `out_tangents`.
    in_tangents: ?Channel = null,

    out_positions: MutChannel,
    /// Required iff `in_normals` is set. Not normalized by this job.
    out_normals: ?MutChannel = null,
    /// Required iff `in_tangents` is set. Not normalized by this job.
    out_tangents: ?MutChannel = null,

    /// Runs the skinning job.
    pub fn run(self: Job) err.Error!void {
        const in_normals = if (self.in_normals) |ch| ch.data else null;
        const in_tangents = if (self.in_tangents) |ch| ch.data else null;
        const out_normals = if (self.out_normals) |ch| ch.data else null;
        const out_tangents = if (self.out_tangents) |ch| ch.data else null;

        var raw = c.SkinningJob{
            .vertex_count = @intCast(self.vertex_count),
            .influences_count = @intCast(self.influences_count),

            .joint_matrices = self.joint_matrices.ptr,
            .joint_matrices_count = self.joint_matrices.len,

            .joint_inverse_transpose_matrices = ptrOrNull(math.Mat4, self.joint_inverse_transpose_matrices),
            .joint_inverse_transpose_matrices_count = lenOr0(math.Mat4, self.joint_inverse_transpose_matrices),

            .joint_indices = self.joint_indices.ptr,
            .joint_indices_count = self.joint_indices.len,
            .joint_indices_stride = self.joint_indices_stride,

            .joint_weights = ptrOrNull(f32, self.joint_weights),
            .joint_weights_count = lenOr0(f32, self.joint_weights),
            .joint_weights_stride = self.joint_weights_stride,

            .in_positions = self.in_positions.data.ptr,
            .in_positions_count = self.in_positions.data.len,
            .in_positions_stride = self.in_positions.stride,

            .in_normals = ptrOrNull(f32, in_normals),
            .in_normals_count = lenOr0(f32, in_normals),
            .in_normals_stride = if (self.in_normals) |ch| ch.stride else 0,

            .in_tangents = ptrOrNull(f32, in_tangents),
            .in_tangents_count = lenOr0(f32, in_tangents),
            .in_tangents_stride = if (self.in_tangents) |ch| ch.stride else 0,

            .out_positions = self.out_positions.data.ptr,
            .out_positions_count = self.out_positions.data.len,
            .out_positions_stride = self.out_positions.stride,

            .out_normals = mutPtrOrNull(f32, out_normals),
            .out_normals_count = mutLenOr0(f32, out_normals),
            .out_normals_stride = if (self.out_normals) |ch| ch.stride else 0,

            .out_tangents = mutPtrOrNull(f32, out_tangents),
            .out_tangents_count = mutLenOr0(f32, out_tangents),
            .out_tangents_stride = if (self.out_tangents) |ch| ch.stride else 0,
        };
        try err.check(c.zozzSkinningJobRun(&raw));
    }
};

fn ptrOrNull(comptime T: type, slice: ?[]const T) ?[*]const T {
    return if (slice) |s| s.ptr else null;
}

fn mutPtrOrNull(comptime T: type, slice: ?[]T) ?[*]T {
    return if (slice) |s| s.ptr else null;
}

fn lenOr0(comptime T: type, slice: ?[]const T) usize {
    return if (slice) |s| s.len else 0;
}

fn mutLenOr0(comptime T: type, slice: ?[]T) usize {
    return if (slice) |s| s.len else 0;
}

/// Deprecated: call `Job.run` instead — `(job).run()`.
pub fn run(job: Job) err.Error!void {
    return job.run();
}
