//===----------------------------------------------------------------------===//
// zozz — offline animation processing: optimizer, sampling utilities,
// additive builder, motion extractor. See ffi/zozz_optimizer.h.
//
// Validation split, uniformly with zozz_offline.cpp: argument-shape problems
// (range, NaN, NULL, aliased in/out handles) fail with
// ZOZZ_RESULT_INVALID_ARGUMENT at the call that receives them; data-shape
// problems that only ozz's own Validate()/operator() can judge fail with
// ZOZZ_RESULT_INVALID_DATA. A joint-count disagreement between an animation
// and a skeleton gets the more specific ZOZZ_RESULT_SKELETON_MISMATCH instead
// of falling through to INVALID_DATA — checked eagerly here even where ozz's
// own operator() would also catch it internally, for the clearer result code
// and so the caller-controllable case never reaches ozz's internal assert.
//===----------------------------------------------------------------------===//

#include <cmath>
#include <cstdint>
#include <cstring>

#include "ozz/animation/offline/additive_animation_builder.h"
#include "ozz/animation/offline/animation_optimizer.h"
#include "ozz/animation/offline/motion_extractor.h"
#include "ozz/animation/offline/raw_animation_utils.h"
#include "ozz/animation/runtime/skeleton.h"
#include "ozz/base/containers/vector.h"
#include "ozz/base/maths/transform.h"
#include "ozz/base/span.h"
#include "zozz_internal.h"

namespace {

bool Finite3(const float* v) {
  return std::isfinite(v[0]) && std::isfinite(v[1]) && std::isfinite(v[2]);
}

bool Finite4(const float* v) { return Finite3(v) && std::isfinite(v[3]); }

bool FiniteTransform(const ZozzTransform& t) {
  return Finite3(t.translation) && Finite4(t.rotation) && Finite3(t.scale);
}

ozz::math::Transform ToOzz(const ZozzTransform& t) {
  ozz::math::Transform out;
  out.translation = {t.translation[0], t.translation[1], t.translation[2]};
  out.rotation = {t.rotation[0], t.rotation[1], t.rotation[2], t.rotation[3]};
  out.scale = {t.scale[0], t.scale[1], t.scale[2]};
  return out;
}

ZozzTransform FromOzz(const ozz::math::Transform& t) {
  ZozzTransform out;
  out.translation[0] = t.translation.x;
  out.translation[1] = t.translation.y;
  out.translation[2] = t.translation.z;
  out.rotation[0] = t.rotation.x;
  out.rotation[1] = t.rotation.y;
  out.rotation[2] = t.rotation.z;
  out.rotation[3] = t.rotation.w;
  out.scale[0] = t.scale.x;
  out.scale[1] = t.scale.y;
  out.scale[2] = t.scale.z;
  return out;
}

bool FiniteSetting(const ZozzOptimizerSetting& s) {
  return std::isfinite(s.tolerance) && s.tolerance >= 0.f &&
        std::isfinite(s.distance) && s.distance >= 0.f;
}

bool ValidReference(ZozzMotionReference r) {
  return r == ZOZZ_MOTION_REFERENCE_ABSOLUTE ||
        r == ZOZZ_MOTION_REFERENCE_SKELETON ||
        r == ZOZZ_MOTION_REFERENCE_ANIMATION;
}

ozz::animation::offline::MotionExtractor::Reference ToOzz(
    ZozzMotionReference r) {
  switch (r) {
    case ZOZZ_MOTION_REFERENCE_SKELETON:
      return ozz::animation::offline::MotionExtractor::Reference::kSkeleton;
    case ZOZZ_MOTION_REFERENCE_ANIMATION:
      return ozz::animation::offline::MotionExtractor::Reference::kAnimation;
    case ZOZZ_MOTION_REFERENCE_ABSOLUTE:
      break;
  }
  return ozz::animation::offline::MotionExtractor::Reference::kAbsolute;
}

ZozzMotionReference FromOzz(
    ozz::animation::offline::MotionExtractor::Reference r) {
  switch (r) {
    case ozz::animation::offline::MotionExtractor::Reference::kSkeleton:
      return ZOZZ_MOTION_REFERENCE_SKELETON;
    case ozz::animation::offline::MotionExtractor::Reference::kAnimation:
      return ZOZZ_MOTION_REFERENCE_ANIMATION;
    case ozz::animation::offline::MotionExtractor::Reference::kAbsolute:
      break;
  }
  return ZOZZ_MOTION_REFERENCE_ABSOLUTE;
}

ozz::animation::offline::MotionExtractor::Settings ToOzz(
    const ZozzMotionSettings& s) {
  return {s.x, s.y, s.z, ToOzz(s.reference), s.bake, s.loop};
}

ZozzMotionSettings FromOzz(
    const ozz::animation::offline::MotionExtractor::Settings& s) {
  return {s.x, s.y, s.z, FromOzz(s.reference), s.bake, s.loop};
}

/// Resets all three motion-extraction outputs to empty. Shared by every
/// failure path in zozzMotionExtractorRun, mirroring the "clear every
/// out-parameter before the first failure return" rule for a function with
/// more than one out-parameter to clear.
void ResetMotionOutputs(ZozzRawFloat3Track* motion_position,
                        ZozzRawQuaternionTrack* motion_rotation,
                        ZozzRawAnimation* output) {
  output->impl = ozz::animation::offline::RawAnimation();
  motion_position->impl = ozz::animation::offline::RawFloat3Track();
  motion_rotation->impl = ozz::animation::offline::RawQuaternionTrack();
}

}  // namespace

//===----------------------------------------------------------------------===//
// Handle types (global namespace — they must match the C tag names)
//===----------------------------------------------------------------------===//

struct ZozzAnimationOptimizer {
  ozz::animation::offline::AnimationOptimizer impl;
};

struct ZozzFixedRateSamplingTime {
  ZozzFixedRateSamplingTime(float duration, float frequency)
      : impl(duration, frequency) {}
  ozz::animation::offline::FixedRateSamplingTime impl;
};

struct ZozzMotionExtractor {
  ozz::animation::offline::MotionExtractor impl;
};

extern "C" {

//===----------------------------------------------------------------------===//
// Animation optimizer
//===----------------------------------------------------------------------===//

ZozzResult zozzAnimationOptimizerCreate(ZozzAnimationOptimizer** out) {
  if (out == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  *out = nullptr;
  ZozzAnimationOptimizer* optimizer = zozz::New<ZozzAnimationOptimizer>();
  if (optimizer == nullptr) return ZOZZ_RESULT_OUT_OF_MEMORY;
  *out = optimizer;
  return ZOZZ_RESULT_OK;
}

void zozzAnimationOptimizerDestroy(ZozzAnimationOptimizer* optimizer) {
  zozz::Delete(optimizer);
}

ZozzResult zozzAnimationOptimizerSetSetting(
    ZozzAnimationOptimizer* optimizer, const ZozzOptimizerSetting* setting) {
  if (optimizer == nullptr || setting == nullptr) {
    return ZOZZ_RESULT_INVALID_ARGUMENT;
  }
  if (!FiniteSetting(*setting)) return ZOZZ_RESULT_INVALID_ARGUMENT;
  optimizer->impl.setting.tolerance = setting->tolerance;
  optimizer->impl.setting.distance = setting->distance;
  return ZOZZ_RESULT_OK;
}

ZozzResult zozzAnimationOptimizerGetSetting(
    const ZozzAnimationOptimizer* optimizer, ZozzOptimizerSetting* out) {
  if (out == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  *out = ZozzOptimizerSetting{};
  if (optimizer == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  out->tolerance = optimizer->impl.setting.tolerance;
  out->distance = optimizer->impl.setting.distance;
  return ZOZZ_RESULT_OK;
}

ZozzResult zozzAnimationOptimizerSetJointOverride(
    ZozzAnimationOptimizer* optimizer, int32_t joint,
    const ZozzOptimizerSetting* setting) {
  if (optimizer == nullptr || setting == nullptr) {
    return ZOZZ_RESULT_INVALID_ARGUMENT;
  }
  if (joint < 0) return ZOZZ_RESULT_INVALID_ARGUMENT;
  if (!FiniteSetting(*setting)) return ZOZZ_RESULT_INVALID_ARGUMENT;
  optimizer->impl.joints_setting_override[joint] =
      ozz::animation::offline::AnimationOptimizer::Setting(setting->tolerance,
                                                            setting->distance);
  return ZOZZ_RESULT_OK;
}

ZozzResult zozzAnimationOptimizerClearJointOverride(
    ZozzAnimationOptimizer* optimizer, int32_t joint) {
  if (optimizer == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  if (joint < 0) return ZOZZ_RESULT_INVALID_ARGUMENT;
  optimizer->impl.joints_setting_override.erase(joint);
  return ZOZZ_RESULT_OK;
}

ZozzResult zozzAnimationOptimizerRun(const ZozzAnimationOptimizer* optimizer,
                                     const ZozzRawAnimation* input,
                                     const ZozzSkeleton* skeleton,
                                     ZozzRawAnimation* output) {
  if (optimizer == nullptr || input == nullptr || skeleton == nullptr ||
      output == nullptr) {
    return ZOZZ_RESULT_INVALID_ARGUMENT;
  }
  if (input == output) return ZOZZ_RESULT_INVALID_ARGUMENT;
  if (input->impl.num_tracks() != skeleton->impl.num_joints()) {
    output->impl = ozz::animation::offline::RawAnimation();
    return ZOZZ_RESULT_SKELETON_MISMATCH;
  }
  const bool ok = optimizer->impl(input->impl, skeleton->impl, &output->impl);
  return ok ? ZOZZ_RESULT_OK : ZOZZ_RESULT_INVALID_DATA;
}

//===----------------------------------------------------------------------===//
// Raw-animation sampling and re-timing utilities
//===----------------------------------------------------------------------===//

ZozzResult zozzRawAnimationSampleTrack(const ZozzRawAnimation* raw,
                                       int32_t track, float time,
                                       ZozzTransform* out) {
  if (raw == nullptr || out == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  if (track < 0 || track >= static_cast<int32_t>(raw->impl.tracks.size())) {
    return ZOZZ_RESULT_INVALID_ARGUMENT;
  }
  if (!std::isfinite(time)) return ZOZZ_RESULT_INVALID_ARGUMENT;

  ozz::math::Transform transform;
  if (!ozz::animation::offline::SampleTrack(raw->impl.tracks[track], time,
                                            &transform)) {
    return ZOZZ_RESULT_INVALID_DATA;
  }
  *out = FromOzz(transform);
  return ZOZZ_RESULT_OK;
}

ZozzResult zozzRawAnimationSample(const ZozzRawAnimation* raw, float time,
                                  ZozzTransform* out, size_t count) {
  if (raw == nullptr || out == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  if (!std::isfinite(time)) return ZOZZ_RESULT_INVALID_ARGUMENT;
  if (count < raw->impl.tracks.size()) return ZOZZ_RESULT_BUFFER_TOO_SMALL;

  ozz::vector<ozz::math::Transform> scratch(count);
  const bool ok = ozz::animation::offline::SampleAnimation(
      raw->impl, time,
      ozz::span<ozz::math::Transform>(scratch.data(), scratch.size()));
  if (!ok) return ZOZZ_RESULT_INVALID_DATA;

  for (size_t i = 0; i < count; ++i) out[i] = FromOzz(scratch[i]);
  return ZOZZ_RESULT_OK;
}

ZozzResult zozzRawAnimationExtractTimePoints(const ZozzRawAnimation* raw,
                                             float* out, size_t count,
                                             size_t* out_count) {
  if (raw == nullptr || out_count == nullptr) {
    return ZOZZ_RESULT_INVALID_ARGUMENT;
  }
  *out_count = 0;

  const std::pair<bool, ozz::vector<float>> result =
      ozz::animation::offline::ExtractTimePoints(raw->impl);
  if (!result.first) return ZOZZ_RESULT_INVALID_DATA;

  const size_t n = result.second.size();
  if (out == nullptr) {
    *out_count = n;
    return ZOZZ_RESULT_OK;
  }
  if (count < n) return ZOZZ_RESULT_BUFFER_TOO_SMALL;
  for (size_t i = 0; i < n; ++i) out[i] = result.second[i];
  *out_count = n;
  return ZOZZ_RESULT_OK;
}

ZozzResult zozzRawAnimationSampleTrackModelSpace(
    const ZozzRawAnimation* raw, const ZozzSkeleton* skeleton, int32_t joint,
    ZozzModelSpaceSample* out, size_t count, size_t* out_count) {
  if (raw == nullptr || skeleton == nullptr || out_count == nullptr) {
    return ZOZZ_RESULT_INVALID_ARGUMENT;
  }
  *out_count = 0;
  if (joint < 0) return ZOZZ_RESULT_INVALID_ARGUMENT;
  // Checked eagerly, ahead of the call below, for the same reason the file
  // header explains for zozzAnimationOptimizerRun: the more specific
  // SKELETON_MISMATCH beats letting a joint-count disagreement fall through
  // to the generic INVALID_DATA that ozz's own bool would otherwise collapse
  // it into alongside "the animation itself is malformed".
  if (raw->impl.num_tracks() != skeleton->impl.num_joints()) {
    return ZOZZ_RESULT_SKELETON_MISMATCH;
  }
  if (joint >= skeleton->impl.num_joints()) return ZOZZ_RESULT_INVALID_ARGUMENT;

  const std::pair<bool, ozz::vector<std::pair<float, ozz::math::Float4x4>>>
      result = ozz::animation::offline::SampleTrackModelSpace(
          raw->impl, skeleton->impl, joint);
  if (!result.first) return ZOZZ_RESULT_INVALID_DATA;

  const size_t n = result.second.size();
  if (out == nullptr) {
    *out_count = n;
    return ZOZZ_RESULT_OK;
  }
  if (count < n) return ZOZZ_RESULT_BUFFER_TOO_SMALL;
  for (size_t i = 0; i < n; ++i) {
    out[i].time = result.second[i].first;
    std::memcpy(out[i].transform.m, &result.second[i].second,
               sizeof(out[i].transform.m));
  }
  *out_count = n;
  return ZOZZ_RESULT_OK;
}

ZozzResult zozzFixedRateSamplingTimeCreate(float duration, float frequency,
                                           ZozzFixedRateSamplingTime** out) {
  if (out == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  *out = nullptr;
  // duration and frequency feed `ceil(1 + duration * frequency)` cast to
  // size_t (raw_animation_utils.cc): a negative product would wrap to a huge
  // count instead of failing cleanly, so both factors are range-checked
  // rather than just the product.
  if (!std::isfinite(duration) || duration < 0.f) {
    return ZOZZ_RESULT_INVALID_ARGUMENT;
  }
  if (!std::isfinite(frequency) || frequency <= 0.f) {
    return ZOZZ_RESULT_INVALID_ARGUMENT;
  }
  ZozzFixedRateSamplingTime* self =
      zozz::New<ZozzFixedRateSamplingTime>(duration, frequency);
  if (self == nullptr) return ZOZZ_RESULT_OUT_OF_MEMORY;
  *out = self;
  return ZOZZ_RESULT_OK;
}

void zozzFixedRateSamplingTimeDestroy(ZozzFixedRateSamplingTime* self) {
  zozz::Delete(self);
}

size_t zozzFixedRateSamplingTimeNumKeys(
    const ZozzFixedRateSamplingTime* self) {
  return self == nullptr ? 0 : self->impl.num_keys();
}

ZozzResult zozzFixedRateSamplingTimeAt(const ZozzFixedRateSamplingTime* self,
                                       size_t key, float* out) {
  if (self == nullptr || out == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  *out = 0.f;
  if (key >= self->impl.num_keys()) return ZOZZ_RESULT_INVALID_ARGUMENT;
  *out = self->impl.time(key);
  return ZOZZ_RESULT_OK;
}

//===----------------------------------------------------------------------===//
// Additive animation builder
//===----------------------------------------------------------------------===//

ZozzResult zozzAdditiveAnimationBuilderRun(const ZozzRawAnimation* input,
                                           ZozzRawAnimation* output) {
  if (input == nullptr || output == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  if (input == output) return ZOZZ_RESULT_INVALID_ARGUMENT;

  const ozz::animation::offline::AdditiveAnimationBuilder builder;
  const bool ok = builder(input->impl, &output->impl);
  return ok ? ZOZZ_RESULT_OK : ZOZZ_RESULT_INVALID_DATA;
}

ZozzResult zozzAdditiveAnimationBuilderRunWithReference(
    const ZozzRawAnimation* input, const ZozzTransform* reference_pose,
    size_t reference_pose_count, ZozzRawAnimation* output) {
  if (input == nullptr || output == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  if (input == output) return ZOZZ_RESULT_INVALID_ARGUMENT;
  if (reference_pose == nullptr && reference_pose_count > 0) {
    return ZOZZ_RESULT_INVALID_ARGUMENT;
  }

  ozz::vector<ozz::math::Transform> scratch(reference_pose_count);
  for (size_t i = 0; i < reference_pose_count; ++i) {
    if (!FiniteTransform(reference_pose[i])) return ZOZZ_RESULT_INVALID_ARGUMENT;
    scratch[i] = ToOzz(reference_pose[i]);
  }

  const ozz::animation::offline::AdditiveAnimationBuilder builder;
  const bool ok = builder(
      input->impl,
      ozz::span<const ozz::math::Transform>(scratch.data(), scratch.size()),
      &output->impl);
  return ok ? ZOZZ_RESULT_OK : ZOZZ_RESULT_INVALID_DATA;
}

//===----------------------------------------------------------------------===//
// Motion extractor
//===----------------------------------------------------------------------===//

ZozzResult zozzMotionExtractorCreate(ZozzMotionExtractor** out) {
  if (out == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  *out = nullptr;
  ZozzMotionExtractor* extractor = zozz::New<ZozzMotionExtractor>();
  if (extractor == nullptr) return ZOZZ_RESULT_OUT_OF_MEMORY;
  *out = extractor;
  return ZOZZ_RESULT_OK;
}

void zozzMotionExtractorDestroy(ZozzMotionExtractor* extractor) {
  zozz::Delete(extractor);
}

ZozzResult zozzMotionExtractorSetRootJoint(ZozzMotionExtractor* extractor,
                                           int32_t joint) {
  if (extractor == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  if (joint < 0) return ZOZZ_RESULT_INVALID_ARGUMENT;
  extractor->impl.root_joint = joint;
  return ZOZZ_RESULT_OK;
}

int32_t zozzMotionExtractorGetRootJoint(const ZozzMotionExtractor* extractor) {
  return extractor == nullptr ? 0 : extractor->impl.root_joint;
}

ZozzResult zozzMotionExtractorSetPositionSettings(
    ZozzMotionExtractor* extractor, const ZozzMotionSettings* settings) {
  if (extractor == nullptr || settings == nullptr) {
    return ZOZZ_RESULT_INVALID_ARGUMENT;
  }
  if (!ValidReference(settings->reference)) return ZOZZ_RESULT_INVALID_ARGUMENT;
  extractor->impl.position_settings = ToOzz(*settings);
  return ZOZZ_RESULT_OK;
}

ZozzResult zozzMotionExtractorGetPositionSettings(
    const ZozzMotionExtractor* extractor, ZozzMotionSettings* out) {
  if (out == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  *out = ZozzMotionSettings{};
  if (extractor == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  *out = FromOzz(extractor->impl.position_settings);
  return ZOZZ_RESULT_OK;
}

ZozzResult zozzMotionExtractorSetRotationSettings(
    ZozzMotionExtractor* extractor, const ZozzMotionSettings* settings) {
  if (extractor == nullptr || settings == nullptr) {
    return ZOZZ_RESULT_INVALID_ARGUMENT;
  }
  if (!ValidReference(settings->reference)) return ZOZZ_RESULT_INVALID_ARGUMENT;
  extractor->impl.rotation_settings = ToOzz(*settings);
  return ZOZZ_RESULT_OK;
}

ZozzResult zozzMotionExtractorGetRotationSettings(
    const ZozzMotionExtractor* extractor, ZozzMotionSettings* out) {
  if (out == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  *out = ZozzMotionSettings{};
  if (extractor == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  *out = FromOzz(extractor->impl.rotation_settings);
  return ZOZZ_RESULT_OK;
}

ZozzResult zozzMotionExtractorRun(const ZozzMotionExtractor* extractor,
                                  const ZozzRawAnimation* input,
                                  const ZozzSkeleton* skeleton,
                                  ZozzRawFloat3Track* motion_position,
                                  ZozzRawQuaternionTrack* motion_rotation,
                                  ZozzRawAnimation* output) {
  if (extractor == nullptr || input == nullptr || skeleton == nullptr ||
      motion_position == nullptr || motion_rotation == nullptr ||
      output == nullptr) {
    return ZOZZ_RESULT_INVALID_ARGUMENT;
  }
  if (input == output) return ZOZZ_RESULT_INVALID_ARGUMENT;
  if (input->impl.num_tracks() != skeleton->impl.num_joints()) {
    ResetMotionOutputs(motion_position, motion_rotation, output);
    return ZOZZ_RESULT_SKELETON_MISMATCH;
  }

  const bool ok =
      extractor->impl(input->impl, skeleton->impl, &motion_position->impl,
                      &motion_rotation->impl, &output->impl);
  if (!ok) {
    ResetMotionOutputs(motion_position, motion_rotation, output);
    return ZOZZ_RESULT_INVALID_DATA;
  }
  return ZOZZ_RESULT_OK;
}

}  // extern "C"
