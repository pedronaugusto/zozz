//===----------------------------------------------------------------------===//
// zozz — root-motion blending.
//===----------------------------------------------------------------------===//

#include "zozz_motion.h"

#include "ozz/animation/runtime/motion_blending_job.h"
#include "ozz/base/containers/vector.h"
#include "ozz/base/maths/transform.h"
#include "zozz_internal.h"

namespace {

ozz::math::Transform ToOzz(const ZozzTransform& t) {
  ozz::math::Transform out;
  out.translation = {t.translation[0], t.translation[1], t.translation[2]};
  out.rotation = {t.rotation[0], t.rotation[1], t.rotation[2], t.rotation[3]};
  out.scale = {t.scale[0], t.scale[1], t.scale[2]};
  return out;
}

void FromOzz(const ozz::math::Transform& in, ZozzTransform* out) {
  out->translation[0] = in.translation.x;
  out->translation[1] = in.translation.y;
  out->translation[2] = in.translation.z;
  out->rotation[0] = in.rotation.x;
  out->rotation[1] = in.rotation.y;
  out->rotation[2] = in.rotation.z;
  out->rotation[3] = in.rotation.w;
  out->scale[0] = in.scale.x;
  out->scale[1] = in.scale.y;
  out->scale[2] = in.scale.z;
}

}  // namespace

extern "C" {

ZozzResult zozzMotionBlend(const ZozzMotionBlendLayer* layers, size_t count,
                           ZozzTransform* out) {
  if (out == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  if (layers == nullptr && count != 0) return ZOZZ_RESULT_INVALID_ARGUMENT;

  for (size_t i = 0; i < count; ++i) {
    if (layers[i].delta == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
    // NaN check: a NaN weight is neither <= 0 nor > 0, so ozz's own "negative
    // is zero" clamp never catches it and it poisons the whole blend.
    if (layers[i].weight != layers[i].weight) {
      return ZOZZ_RESULT_INVALID_ARGUMENT;
    }
  }

  // Converted once up front rather than reinterpret_cast: ZozzTransform is
  // not asserted layout-compatible with ozz::math::Transform anywhere, and
  // this job runs at most once per skeleton instance per frame, so the copy
  // costs nothing that matters.
  ozz::vector<ozz::math::Transform> deltas(count);
  ozz::vector<ozz::animation::MotionBlendingJob::Layer> job_layers(count);
  for (size_t i = 0; i < count; ++i) {
    deltas[i] = ToOzz(*layers[i].delta);
    job_layers[i].weight = layers[i].weight;
    job_layers[i].delta = &deltas[i];
  }

  ozz::math::Transform result;
  ozz::animation::MotionBlendingJob job;
  job.layers = ozz::make_span(job_layers);
  job.output = &result;

  if (!job.Validate()) return ZOZZ_RESULT_JOB_INVALID;
  if (!job.Run()) return ZOZZ_RESULT_JOB_INVALID;

  FromOzz(result, out);
  return ZOZZ_RESULT_OK;
}

}  // extern "C"
