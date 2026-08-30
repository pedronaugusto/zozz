//===----------------------------------------------------------------------===//
// zozz — BlendingJob over caller-owned layers.
//
// No allocation and no per-call copy: ZozzBlendingLayer is
// BlendingJob::Layer's layout, asserted in zozz_abi.cpp, so the caller's array
// IS the job's span.
//===----------------------------------------------------------------------===//

#include <cmath>

#include "ozz/animation/runtime/blending_job.h"
#include "zozz_internal.h"

namespace {

using ozz::animation::BlendingJob;

/// Everything about a layer that ozz's Validate() cannot see: a null pose, and
/// a buffer ozz would read with an aligned SIMD load.
bool ValidLayer(const ZozzBlendingLayer& layer) {
  if (layer.transform == nullptr) return false;
  if (!zozz::IsAligned16(layer.transform)) return false;
  if (layer.joint_weights != nullptr && !zozz::IsAligned16(layer.joint_weights)) {
    return false;
  }
  return true;
}

ozz::span<const BlendingJob::Layer> AsLayers(const ZozzBlendingLayer* layers,
                                             size_t count) {
  return ozz::span<const BlendingJob::Layer>(
      reinterpret_cast<const BlendingJob::Layer*>(layers), count);
}

}  // namespace

extern "C" {

ZozzResult zozzBlendingRun(const ZozzBlendingLayer* layers, size_t num_layers,
                           const ZozzBlendingLayer* additive_layers,
                           size_t num_additive_layers,
                           const ZozzSoaTransform* rest_pose, float threshold,
                           ZozzSoaTransform* out, size_t blocks) {
  if (rest_pose == nullptr || out == nullptr || blocks == 0) {
    return ZOZZ_RESULT_INVALID_ARGUMENT;
  }
  if (num_layers > 0 && layers == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  if (num_additive_layers > 0 && additive_layers == nullptr) {
    return ZOZZ_RESULT_INVALID_ARGUMENT;
  }
  if (!std::isfinite(threshold)) return ZOZZ_RESULT_INVALID_ARGUMENT;

  // A NULL transform reads as an empty span, which Validate() refuses -- but
  // it refuses it as "a layer is too short", which is the same verdict for a
  // different mistake. Naming this one keeps the two apart.
  if (!zozz::IsAligned16(rest_pose) || !zozz::IsAligned16(out)) {
    return ZOZZ_RESULT_INVALID_ARGUMENT;
  }
  for (size_t i = 0; i < num_layers; ++i) {
    if (!ValidLayer(layers[i])) return ZOZZ_RESULT_INVALID_ARGUMENT;
  }
  for (size_t i = 0; i < num_additive_layers; ++i) {
    if (!ValidLayer(additive_layers[i])) return ZOZZ_RESULT_INVALID_ARGUMENT;
  }

  BlendingJob job;
  job.threshold = threshold;
  job.layers = AsLayers(layers, num_layers);
  job.additive_layers = AsLayers(additive_layers, num_additive_layers);
  job.rest_pose = zozz::AsSpan(rest_pose, blocks);
  job.output = zozz::AsSpan(out, blocks);

  if (!job.Validate()) return ZOZZ_RESULT_JOB_INVALID;
  if (!job.Run()) return ZOZZ_RESULT_JOB_INVALID;
  return ZOZZ_RESULT_OK;
}

}  // extern "C"
