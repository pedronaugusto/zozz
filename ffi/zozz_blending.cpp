//===----------------------------------------------------------------------===//
// zozz — the per-joint weight buffer, and BlendingJob.
//===----------------------------------------------------------------------===//

#include <cmath>

#include "ozz/animation/runtime/blending_job.h"
#include "ozz/base/containers/vector.h"
#include "zozz_internal.h"

namespace {

/// Distributes `num_joints` flat weights into SoA blocks, one float per
/// lane. Unused lanes in a trailing partial block are padded with 1.0 — the
/// same "fully weighted" default zozzSoaWeightsCreate starts every joint at.
void PackWeights(const float* in, ozz::math::SimdFloat4* out, int num_joints) {
  const int blocks = zozz::SoaBlocks(num_joints);
  for (int b = 0; b < blocks; ++b) {
    const int base = b * 4;
    const int lanes = num_joints - base < 4 ? num_joints - base : 4;
    float lane[4] = {1.f, 1.f, 1.f, 1.f};
    for (int l = 0; l < lanes; ++l) lane[l] = in[base + l];
    out[b] = ozz::math::simd_float4::LoadPtrU(lane);
  }
}

using ozz::animation::BlendingJob;

/// Fills `job_layers` from `layers`. Returns false on the first layer with a
/// NULL transform, leaving `job_layers` partially filled — the caller
/// discards it either way.
bool FillLayers(const ZozzBlendingLayer* layers, size_t count,
                ozz::vector<BlendingJob::Layer>* job_layers) {
  job_layers->resize(count);
  for (size_t i = 0; i < count; ++i) {
    const ZozzBlendingLayer& src = layers[i];
    if (src.transform == nullptr) return false;

    BlendingJob::Layer& dst = (*job_layers)[i];
    dst.weight = src.weight;
    dst.transform = ozz::span<const ozz::math::SoaTransform>(
        src.transform->data,
        static_cast<size_t>(src.transform->num_soa_joints));
    if (src.joint_weights != nullptr) {
      dst.joint_weights = ozz::span<const ozz::math::SimdFloat4>(
          src.joint_weights->data,
          static_cast<size_t>(src.joint_weights->num_soa_joints));
    }
  }
  return true;
}

}  // namespace

struct ZozzSoaWeights {
  ozz::math::SimdFloat4* data;
  int num_joints;
  int num_soa_joints;
};

extern "C" {

ZozzResult zozzSoaWeightsCreate(int num_joints, ZozzSoaWeights** out) {
  if (out == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  *out = nullptr;
  if (num_joints <= 0 || num_joints > zozz::kMaxJoints) {
    return ZOZZ_RESULT_INVALID_ARGUMENT;
  }

  const int blocks = zozz::SoaBlocks(num_joints);
  ozz::memory::Allocator* allocator = ozz::memory::default_allocator();
  void* storage = allocator->Allocate(sizeof(ozz::math::SimdFloat4) * blocks,
                                      alignof(ozz::math::SimdFloat4));
  if (storage == nullptr) return ZOZZ_RESULT_OUT_OF_MEMORY;

  ZozzSoaWeights* weights = zozz::New<ZozzSoaWeights>();
  if (weights == nullptr) {
    allocator->Deallocate(storage);
    return ZOZZ_RESULT_OUT_OF_MEMORY;
  }

  weights->data = static_cast<ozz::math::SimdFloat4*>(storage);
  weights->num_joints = num_joints;
  weights->num_soa_joints = blocks;
  for (int b = 0; b < blocks; ++b) {
    weights->data[b] = ozz::math::simd_float4::one();
  }

  *out = weights;
  return ZOZZ_RESULT_OK;
}

void zozzSoaWeightsDestroy(ZozzSoaWeights* weights) {
  if (weights == nullptr) return;
  ozz::memory::default_allocator()->Deallocate(weights->data);
  zozz::Delete(weights);
}

ZozzResult zozzSoaWeightsFromArray(ZozzSoaWeights* weights, const float* in,
                                   size_t count) {
  if (weights == nullptr || in == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  if (count < static_cast<size_t>(weights->num_joints)) {
    return ZOZZ_RESULT_BUFFER_TOO_SMALL;
  }
  for (int i = 0; i < weights->num_joints; ++i) {
    if (!std::isfinite(in[i])) return ZOZZ_RESULT_INVALID_ARGUMENT;
  }

  PackWeights(in, weights->data, weights->num_joints);
  return ZOZZ_RESULT_OK;
}

ZozzResult zozzBlendingRun(const ZozzBlendingLayer* layers, size_t num_layers,
                          const ZozzBlendingLayer* additive_layers,
                          size_t num_additive_layers,
                          const ZozzSoaPose* rest_pose, float threshold,
                          ZozzSoaPose* out) {
  if (rest_pose == nullptr || out == nullptr) {
    return ZOZZ_RESULT_INVALID_ARGUMENT;
  }
  if (num_layers > 0 && layers == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  if (num_additive_layers > 0 && additive_layers == nullptr) {
    return ZOZZ_RESULT_INVALID_ARGUMENT;
  }
  if (!std::isfinite(threshold)) return ZOZZ_RESULT_INVALID_ARGUMENT;

  ozz::vector<BlendingJob::Layer> job_layers;
  ozz::vector<BlendingJob::Layer> job_additive_layers;
  if (!FillLayers(layers, num_layers, &job_layers)) {
    return ZOZZ_RESULT_INVALID_ARGUMENT;
  }
  if (!FillLayers(additive_layers, num_additive_layers,
                  &job_additive_layers)) {
    return ZOZZ_RESULT_INVALID_ARGUMENT;
  }

  BlendingJob job;
  job.threshold = threshold;
  job.layers = ozz::span<const BlendingJob::Layer>(job_layers.data(),
                                                    job_layers.size());
  job.additive_layers = ozz::span<const BlendingJob::Layer>(
      job_additive_layers.data(), job_additive_layers.size());
  job.rest_pose = ozz::span<const ozz::math::SoaTransform>(
      rest_pose->data, static_cast<size_t>(rest_pose->num_soa_joints));
  job.output = ozz::span<ozz::math::SoaTransform>(
      out->data, static_cast<size_t>(out->num_soa_joints));

  if (!job.Validate()) return ZOZZ_RESULT_JOB_INVALID;
  if (!job.Run()) return ZOZZ_RESULT_JOB_INVALID;
  return ZOZZ_RESULT_OK;
}

}  // extern "C"
