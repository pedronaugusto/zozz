//===----------------------------------------------------------------------===//
// zozz — matrix-palette skinning.
//===----------------------------------------------------------------------===//

#include "zozz_skinning.h"

#include "ozz/geometry/runtime/skinning_job.h"
#include "zozz_internal.h"

namespace {

/// A NULL pointer paired with a non-zero count claims memory that is not
/// there. ozz's own Validate() cannot catch this: a span reports only its
/// extent (size_bytes()), never whether the pointer backing it is real, so
/// this exact inconsistency is what would turn a passing Validate() into a
/// null dereference inside Run(). Every span-backed field is checked against
/// this before any ozz::span is built from it.
bool SpanIsSane(const void* pointer, size_t count) {
  return pointer != nullptr || count == 0;
}

}  // namespace

extern "C" {

ZozzResult zozzSkinningJobRun(const ZozzSkinningJob* job) {
  if (job == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;

  if (!SpanIsSane(job->joint_matrices, job->joint_matrices_count) ||
      !SpanIsSane(job->joint_inverse_transpose_matrices,
                 job->joint_inverse_transpose_matrices_count) ||
      !SpanIsSane(job->joint_indices, job->joint_indices_count) ||
      !SpanIsSane(job->joint_weights, job->joint_weights_count) ||
      !SpanIsSane(job->in_positions, job->in_positions_count) ||
      !SpanIsSane(job->in_normals, job->in_normals_count) ||
      !SpanIsSane(job->in_tangents, job->in_tangents_count) ||
      !SpanIsSane(job->out_positions, job->out_positions_count) ||
      !SpanIsSane(job->out_normals, job->out_normals_count) ||
      !SpanIsSane(job->out_tangents, job->out_tangents_count)) {
    return ZOZZ_RESULT_INVALID_ARGUMENT;
  }

  namespace m = ozz::math;

  ozz::geometry::SkinningJob ozz_job;
  ozz_job.vertex_count = job->vertex_count;
  ozz_job.influences_count = job->influences_count;

  // ZozzFloat4x4 is layout- and alignment-compatible with ozz's Float4x4;
  // zozz_abi.cpp static_asserts both properties.
  ozz_job.joint_matrices = ozz::span<const m::Float4x4>(
      reinterpret_cast<const m::Float4x4*>(job->joint_matrices),
      job->joint_matrices_count);
  ozz_job.joint_inverse_transpose_matrices = ozz::span<const m::Float4x4>(
      reinterpret_cast<const m::Float4x4*>(
          job->joint_inverse_transpose_matrices),
      job->joint_inverse_transpose_matrices_count);

  ozz_job.joint_indices = ozz::span<const uint16_t>(
      job->joint_indices, job->joint_indices_count);
  ozz_job.joint_indices_stride = job->joint_indices_stride;

  ozz_job.joint_weights =
      ozz::span<const float>(job->joint_weights, job->joint_weights_count);
  ozz_job.joint_weights_stride = job->joint_weights_stride;

  ozz_job.in_positions =
      ozz::span<const float>(job->in_positions, job->in_positions_count);
  ozz_job.in_positions_stride = job->in_positions_stride;
  ozz_job.in_normals =
      ozz::span<const float>(job->in_normals, job->in_normals_count);
  ozz_job.in_normals_stride = job->in_normals_stride;
  ozz_job.in_tangents =
      ozz::span<const float>(job->in_tangents, job->in_tangents_count);
  ozz_job.in_tangents_stride = job->in_tangents_stride;

  ozz_job.out_positions =
      ozz::span<float>(job->out_positions, job->out_positions_count);
  ozz_job.out_positions_stride = job->out_positions_stride;
  ozz_job.out_normals =
      ozz::span<float>(job->out_normals, job->out_normals_count);
  ozz_job.out_normals_stride = job->out_normals_stride;
  ozz_job.out_tangents =
      ozz::span<float>(job->out_tangents, job->out_tangents_count);
  ozz_job.out_tangents_stride = job->out_tangents_stride;

  // A job's Validate() returning false is a real error path, not an
  // assertion: it is what catches a buffer too short for vertex_count, or
  // normals/tangents supplied on one side of in/out but not the other.
  // ZOZZ_RESULT_JOB_INVALID names that specifically, apart from
  // ZOZZ_RESULT_INVALID_ARGUMENT above, which is this layer's own rejection
  // of a span whose pointer and count disagree about whether it is there.
  if (!ozz_job.Validate()) return ZOZZ_RESULT_JOB_INVALID;
  if (!ozz_job.Run()) return ZOZZ_RESULT_JOB_INVALID;
  return ZOZZ_RESULT_OK;
}

}  // extern "C"
