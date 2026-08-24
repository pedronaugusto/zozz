//===----------------------------------------------------------------------===//
// zozz — sampling context, the sampling job, and local-to-model.
//===----------------------------------------------------------------------===//

#include <cstdint>

#include "ozz/animation/runtime/local_to_model_job.h"
#include "zozz_internal.h"

namespace {

/// ozz writes Float4x4 columns with aligned SIMD stores.
bool IsAligned16(const void* pointer) {
  return (reinterpret_cast<uintptr_t>(pointer) & 15u) == 0;
}

}  // namespace

extern "C" {

ZozzResult zozzSamplingContextCreate(int max_tracks,
                                     ZozzSamplingContext** out) {
  if (out == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  *out = nullptr;
  if (max_tracks <= 0 || max_tracks > zozz::kMaxJoints) {
    return ZOZZ_RESULT_INVALID_ARGUMENT;
  }

  ZozzSamplingContext* context = zozz::New<ZozzSamplingContext>();
  if (context == nullptr) return ZOZZ_RESULT_OUT_OF_MEMORY;

  context->impl.Resize(max_tracks);
  if (context->impl.max_tracks() < max_tracks) {
    // Resize allocates internally and cannot report failure; an undersized
    // context after the call is the only observable symptom.
    zozz::Delete(context);
    return ZOZZ_RESULT_OUT_OF_MEMORY;
  }

  *out = context;
  return ZOZZ_RESULT_OK;
}

void zozzSamplingContextDestroy(ZozzSamplingContext* context) {
  zozz::Delete(context);
}

ZozzResult zozzSamplingContextResize(ZozzSamplingContext* context,
                                     int max_tracks) {
  if (context == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  if (max_tracks <= 0 || max_tracks > zozz::kMaxJoints) {
    return ZOZZ_RESULT_INVALID_ARGUMENT;
  }

  context->impl.Resize(max_tracks);
  if (context->impl.max_tracks() < max_tracks) {
    // See zozzSamplingContextCreate: Resize allocates internally and cannot
    // report failure, so an undersized context after the call is the only
    // observable symptom.
    return ZOZZ_RESULT_OUT_OF_MEMORY;
  }

  return ZOZZ_RESULT_OK;
}

void zozzSamplingContextInvalidate(ZozzSamplingContext* context) {
  if (context == nullptr) return;
  context->impl.Invalidate();
}

int zozzSamplingContextMaxTracks(const ZozzSamplingContext* context) {
  return context == nullptr ? 0 : context->impl.max_tracks();
}

ZozzResult zozzSample(const ZozzAnimation* animation,
                      ZozzSamplingContext* context, float ratio,
                      ZozzSoaPose* out) {
  if (animation == nullptr || context == nullptr || out == nullptr) {
    return ZOZZ_RESULT_INVALID_ARGUMENT;
  }
  if (ratio != ratio) return ZOZZ_RESULT_INVALID_ARGUMENT;  // NaN

  const int tracks = animation->impl.num_tracks();
  if (out->num_joints < tracks) return ZOZZ_RESULT_BUFFER_TOO_SMALL;
  if (context->impl.max_tracks() < tracks) return ZOZZ_RESULT_BUFFER_TOO_SMALL;

  ozz::animation::SamplingJob job;
  job.animation = &animation->impl;
  job.context = &context->impl;
  job.ratio = ratio;
  job.output = ozz::span<ozz::math::SoaTransform>(
      out->data, static_cast<size_t>(out->num_soa_joints));

  if (!job.Validate()) return ZOZZ_RESULT_JOB_INVALID;
  if (!job.Run()) return ZOZZ_RESULT_JOB_INVALID;
  return ZOZZ_RESULT_OK;
}

ZozzResult zozzLocalToModel(const ZozzSkeleton* skeleton,
                            const ZozzSoaPose* locals,
                            const ZozzFloat4x4* root, ZozzFloat4x4* out,
                            size_t count) {
  if (skeleton == nullptr || locals == nullptr || out == nullptr) {
    return ZOZZ_RESULT_INVALID_ARGUMENT;
  }
  if (!IsAligned16(out)) return ZOZZ_RESULT_INVALID_ARGUMENT;
  if (root != nullptr && !IsAligned16(root)) return ZOZZ_RESULT_INVALID_ARGUMENT;

  const int joints = skeleton->impl.num_joints();
  if (locals->num_joints != joints) return ZOZZ_RESULT_SKELETON_MISMATCH;
  if (count < static_cast<size_t>(joints)) return ZOZZ_RESULT_BUFFER_TOO_SMALL;

  // ZozzFloat4x4 is layout- and alignment-compatible with ozz's Float4x4;
  // zozz_abi.cpp static_asserts both properties.
  ozz::animation::LocalToModelJob job;
  job.skeleton = &skeleton->impl;
  job.root = reinterpret_cast<const ozz::math::Float4x4*>(root);
  job.input = ozz::span<const ozz::math::SoaTransform>(
      locals->data, static_cast<size_t>(locals->num_soa_joints));
  job.output = ozz::span<ozz::math::Float4x4>(
      reinterpret_cast<ozz::math::Float4x4*>(out), static_cast<size_t>(joints));

  if (!job.Validate()) return ZOZZ_RESULT_JOB_INVALID;
  if (!job.Run()) return ZOZZ_RESULT_JOB_INVALID;
  return ZOZZ_RESULT_OK;
}

ZozzResult zozzLocalToModelRange(const ZozzSkeleton* skeleton,
                                 const ZozzSoaPose* locals,
                                 const ZozzFloat4x4* root, int from, int to,
                                 int from_excluded, ZozzFloat4x4* out,
                                 size_t count) {
  if (skeleton == nullptr || locals == nullptr || out == nullptr) {
    return ZOZZ_RESULT_INVALID_ARGUMENT;
  }
  if (!IsAligned16(out)) return ZOZZ_RESULT_INVALID_ARGUMENT;
  if (root != nullptr && !IsAligned16(root)) return ZOZZ_RESULT_INVALID_ARGUMENT;

  const int joints = skeleton->impl.num_joints();
  if (locals->num_joints != joints) return ZOZZ_RESULT_SKELETON_MISMATCH;
  if (count < static_cast<size_t>(joints)) return ZOZZ_RESULT_BUFFER_TOO_SMALL;

  // ZozzFloat4x4 is layout- and alignment-compatible with ozz's Float4x4;
  // zozz_abi.cpp static_asserts both properties.
  ozz::animation::LocalToModelJob job;
  job.skeleton = &skeleton->impl;
  job.root = reinterpret_cast<const ozz::math::Float4x4*>(root);
  job.from = from;
  job.to = to;
  job.from_excluded = from_excluded != 0;
  job.input = ozz::span<const ozz::math::SoaTransform>(
      locals->data, static_cast<size_t>(locals->num_soa_joints));
  job.output = ozz::span<ozz::math::Float4x4>(
      reinterpret_cast<ozz::math::Float4x4*>(out), static_cast<size_t>(joints));

  if (!job.Validate()) return ZOZZ_RESULT_JOB_INVALID;
  if (!job.Run()) return ZOZZ_RESULT_JOB_INVALID;
  return ZOZZ_RESULT_OK;
}

}  // extern "C"
