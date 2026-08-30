//===----------------------------------------------------------------------===//
// zozz — pose blending: weighted, additive and per-joint partial blending,
// all one job (ozz::animation::BlendingJob).
//
// Conventions, ownership and thread safety are documented in zozz_core.h.
//===----------------------------------------------------------------------===//

#ifndef ZOZZ_BLENDING_H_
#define ZOZZ_BLENDING_H_

#include <stddef.h>

#include "zozz.h"

#ifdef __cplusplus
extern "C" {
#endif

//===----------------------------------------------------------------------===//
// Layers
//
// ZozzBlendingLayer is ozz::animation::BlendingJob::Layer laid out field for
// field: a float, then two {pointer, count} pairs where ozz has two
// ozz::span. zozz_abi.cpp asserts the size, the alignment and all five
// offsets against ozz's own type, and zozzBlendingRun then hands the caller's
// array straight to the job.
//
// That is the whole point of the shape. Building ozz::vector<Layer> per call
// meant two heap allocations on the frame path of a job ozz itself runs
// without any.
//===----------------------------------------------------------------------===//

/// One blend input: a pose, its weight, and an optional partial-blend mask.
/// Every buffer is borrowed for the zozzBlendingRun call only.
typedef struct ZozzBlendingLayer {
  /// Blending weight. Negative values are treated as 0 by ozz; normalisation
  /// happens during the blend, so any non-negative range is valid.
  float weight;
  /// SoA local-space transforms for this layer, e.g. a sampling job's output.
  const ZozzSoaTransform* transform;
  /// Length of `transform`, in SoA blocks. At least `blocks` of the run.
  size_t num_transform;
  /// Optional per-joint weight mask, one register per four joints, as
  /// zozzSoaWeightsPack writes it. NULL weighs every joint at `weight`.
  const ZozzSimdFloat4* joint_weights;
  /// Length of `joint_weights`, in SoA blocks. 0 when it is NULL.
  size_t num_joint_weights;
} ZozzBlendingLayer;

/// Blends `layers` and adds `additive_layers` into `out`. `layers` are
/// normalised and mixed; `additive_layers` add over the result. Either array
/// may be NULL if its paired count is 0. A joint whose `layers` weight falls
/// below `threshold` (finite, > 0) is taken from `rest_pose` instead. `blocks`
/// is the SoA length of `rest_pose` and of `out`. Validate() governs the
/// remaining rules; a rejection yields ZOZZ_RESULT_JOB_INVALID.
ZOZZ_API ZozzResult zozzBlendingRun(const ZozzBlendingLayer* layers,
                                    size_t num_layers,
                                    const ZozzBlendingLayer* additive_layers,
                                    size_t num_additive_layers,
                                    const ZozzSoaTransform* rest_pose,
                                    float threshold, ZozzSoaTransform* out,
                                    size_t blocks);

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // ZOZZ_BLENDING_H_
