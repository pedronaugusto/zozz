//===----------------------------------------------------------------------===//
// zozz — pose blending: weighted, additive and per-joint partial blending,
// all one job (ozz::animation::BlendingJob).
//
// Conventions, ownership and thread safety are documented in zozz_core.h.
//===----------------------------------------------------------------------===//

#ifndef ZOZZ_BLENDING_H_
#define ZOZZ_BLENDING_H_

#include "zozz.h"

#ifdef __cplusplus
extern "C" {
#endif

//===----------------------------------------------------------------------===//
// Per-joint weights, for partial blending
//===----------------------------------------------------------------------===//

/// A per-joint SoA weight buffer for partial blending. ozz's own
/// BlendingJob::Layer::joint_weights is a span over the same SoA layout as a
/// pose (one SimdFloat4 per 4 joints, matching ZozzSoaPose's layout), so this
/// mirrors ZozzSoaPose rather than a raw pointer: an opaque handle built once
/// via zozzSoaWeightsFromArray and reused across zozzBlendingRun calls to
/// avoid re-packing floats into SIMD lanes every frame.
typedef struct ZozzSoaWeights ZozzSoaWeights;

/// Allocates a weight buffer sized for `num_joints` (rounded up to a SoA
/// block), every joint initialised to a weight of 1.0 — the same "fully
/// weighted" meaning ozz gives an ABSENT joint_weights span.
ZOZZ_API ZozzResult zozzSoaWeightsCreate(int num_joints,
                                         ZozzSoaWeights** out);

ZOZZ_API void zozzSoaWeightsDestroy(ZozzSoaWeights* weights);

/// Packs `count` (at least zozzSoaWeightsCreate's `num_joints`) flat per-joint
/// weights into SoA blocks. Values are not clamped: ozz treats a negative
/// weight as 0, and a value above 1 is valid wherever normalisation
/// elsewhere allows it. Every value must be finite.
ZOZZ_API ZozzResult zozzSoaWeightsFromArray(ZozzSoaWeights* weights,
                                            const float* in, size_t count);

//===----------------------------------------------------------------------===//
// Blending
//===----------------------------------------------------------------------===//

/// One blend input: a pose, its weight, and an optional partial-blend mask.
///
/// BlendingJob::Layer crosses as this flat struct rather than two raw spans:
/// `transform` is the exact SoA buffer a sampling job wrote, so a layer just
/// borrows a ZozzSoaPose. Members are borrowed for the call only —
/// zozzBlendingRun reads every layer before returning and keeps no pointer.
typedef struct ZozzBlendingLayer {
  /// Blending weight. Negative values are treated as 0 by ozz; normalisation
  /// happens during the blend, so any non-negative range is valid.
  float weight;
  /// SoA local-space transforms for this layer, e.g. a sampling job's
  /// output. Must have at least as many joints as `rest_pose` in
  /// zozzBlendingRun.
  const ZozzSoaPose* transform;
  /// Optional per-joint weight mask. NULL disables partial blending for this
  /// layer (every joint weighs `weight`).
  const ZozzSoaWeights* joint_weights;
} ZozzBlendingLayer;

/// Blends `layers` and adds `additive_layers` into `out`. `layers` are
/// normalised and mixed; `additive_layers` add over the result. Either array
/// may be NULL if its paired count is 0. A joint whose `layers` weight falls
/// below `threshold` (finite, > 0) is taken from `rest_pose` instead, which
/// sets the joint count `out` must be sized to. Validate() governs remaining
/// rules; a rejection yields ZOZZ_RESULT_JOB_INVALID.
ZOZZ_API ZozzResult zozzBlendingRun(const ZozzBlendingLayer* layers,
                                    size_t num_layers,
                                    const ZozzBlendingLayer* additive_layers,
                                    size_t num_additive_layers,
                                    const ZozzSoaPose* rest_pose,
                                    float threshold, ZozzSoaPose* out);

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // ZOZZ_BLENDING_H_
