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

/// A per-joint SoA weight buffer, for partial blending.
///
/// ozz::animation::BlendingJob::Layer::joint_weights is a span over the same
/// SoA currency a pose is (one ozz::math::SimdFloat4 per 4 joints, matching
/// ZozzSoaPose's own block layout) rather than a plain float array, so this
/// mirrors ZozzSoaPose rather than taking a raw pointer: an opaque handle a
/// host builds once, with zozzSoaWeightsFromArray, and reuses across every
/// zozzBlendingRun call that wants the same partial mask, instead of
/// re-packing floats into SIMD lanes every frame.
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
/// BlendingJob::Layer crosses as this flat struct rather than two raw spans,
/// for the same reason zozz keeps poses opaque everywhere else: `transform`
/// is already the exact SoA buffer a sampling job wrote, so a layer just
/// borrows a ZozzSoaPose instead of asking the caller to unpack one. Its
/// members are borrowed for the call only — zozzBlendingRun reads every
/// layer before returning and keeps no pointer afterwards.
///
/// `joint_weights` is NULL exactly when ozz's own span would be empty: no
/// per-joint mask, every joint weighted at `weight`. This one optional field
/// is what makes blending, additive blending and partial blending a single
/// function instead of three — additive layers are simply
/// BlendingJob::additive_layers, passed through this same struct, and a
/// layer opts into partial blending by supplying one extra pointer.
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

/// Blends `layers` and adds `additive_layers` on top, into `out`.
///
/// `layers` are normalised and mixed; `additive_layers` are added over the
/// result — this is ozz::animation::BlendingJob's own two-pass split, not a
/// second pass zozz adds on top. Either array may be NULL when its paired
/// count is 0.
///
/// A joint whose accumulated `layers` weight falls below `threshold` (which
/// must be finite and greater than 0) is taken from `rest_pose` instead, so
/// `rest_pose` also sets the joint count every buffer here is measured
/// against; `out` must be at least that size.
///
/// The job's own Validate() is the source of truth for every other
/// consistency rule — layer count, span sizes, threshold range — so a
/// rejection there surfaces as ZOZZ_RESULT_JOB_INVALID rather than being
/// re-derived here.
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
