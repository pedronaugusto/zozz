//===----------------------------------------------------------------------===//
// zozz — matrix-palette skinning.
//
// Conventions, ownership and thread safety are documented in zozz_core.h.
//===----------------------------------------------------------------------===//

#ifndef ZOZZ_SKINNING_H_
#define ZOZZ_SKINNING_H_

#include <stddef.h>
#include <stdint.h>

#include "zozz.h"

#ifdef __cplusplus
extern "C" {
#endif

/// Transforms vertex positions, and optionally normals and tangents, by a
/// per-vertex weighted blend of joint matrices ("matrix palette skinning").
///
/// Every buffer below is a flat array with its own element count and byte
/// stride, so array-of-structs and struct-of-arrays vertex layouts both work
/// without a repacking pass. None of them are retained past the call. A
/// buffer's element count is independent of vertex_count and is re-checked
/// against it, so a short buffer is refused rather than read past its end. A
/// NULL pointer paired with a non-zero count is always refused, required or
/// optional: it claims memory that is not there.
///
/// Required: joint_matrices, joint_indices, in_positions, out_positions.
/// joint_weights is required unless influences_count == 1, in which case the
/// sole influence's implicit weight is 1 and joint_weights is never read.
/// in_normals/out_normals are optional but must be given together; the same
/// holds for in_tangents/out_tangents, which additionally require normals. A
/// field that is not provided must have both its pointer NULL and its count
/// 0.
typedef struct ZozzSkinningJob {
  /// Vertices to transform. Every buffer below must hold at least this many.
  int vertex_count;
  /// Joints influencing each vertex. Must be greater than 0.
  int influences_count;

  /// Palette: one matrix per joint, already pre-multiplied with the inverse
  /// bind-pose matrix. Indexed by joint_indices.
  const ZozzFloat4x4* joint_matrices;
  size_t joint_matrices_count;

  /// Optional. Inverse-transpose of joint_matrices, used instead of it to
  /// transform normals/tangents when joint_matrices carries non-uniform
  /// scale or shear. NULL uses joint_matrices for that too.
  const ZozzFloat4x4* joint_inverse_transpose_matrices;
  size_t joint_inverse_transpose_matrices_count;

  /// influences_count indices per vertex, indexing joint_matrices.
  const uint16_t* joint_indices;
  size_t joint_indices_count;
  size_t joint_indices_stride;

  /// (influences_count - 1) weights per vertex; the last influence's weight
  /// is recovered from the others summing to 1. Optional (NULL/0) only when
  /// influences_count == 1.
  const float* joint_weights;
  size_t joint_weights_count;
  size_t joint_weights_stride;

  /// 3 floats per vertex.
  const float* in_positions;
  size_t in_positions_count;
  size_t in_positions_stride;

  /// Optional, 3 floats per vertex. Requires out_normals.
  const float* in_normals;
  size_t in_normals_count;
  size_t in_normals_stride;

  /// Optional, 3 floats per vertex. Requires in_normals and out_tangents.
  const float* in_tangents;
  size_t in_tangents_count;
  size_t in_tangents_stride;

  /// 3 floats per vertex.
  float* out_positions;
  size_t out_positions_count;
  size_t out_positions_stride;

  /// Required iff in_normals is provided. Not normalized by this job — the
  /// caller decides whether that is needed downstream.
  float* out_normals;
  size_t out_normals_count;
  size_t out_normals_stride;

  /// Required iff in_tangents is provided. Not normalized by this job.
  float* out_tangents;
  size_t out_tangents_count;
  size_t out_tangents_stride;
} ZozzSkinningJob;

/// Runs the job. Returns ZOZZ_RESULT_INVALID_ARGUMENT if `job` is NULL, or if
/// any buffer's pointer is NULL while its count is non-zero. Returns
/// ZOZZ_RESULT_JOB_INVALID if the job's own Validate() rejects it — a buffer
/// too short for vertex_count, or normals/tangents provided on one side of
/// in/out but not the other.
ZOZZ_API ZozzResult zozzSkinningJobRun(const ZozzSkinningJob* job);

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // ZOZZ_SKINNING_H_
