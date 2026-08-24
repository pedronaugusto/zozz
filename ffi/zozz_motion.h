//===----------------------------------------------------------------------===//
// zozz — root-motion blending.
//
// Mirrors ozz's motion_blending_job.h. There is no motion-SAMPLING entry
// point here: ozz 0.17.0 ships no motion_sampling_job.h in the runtime, so
// root-motion deltas are consumed at runtime only through blending. Motion
// EXTRACTION is bound, just not in this file — see zozzMotionExtractorRun in
// zozz_optimizer.h, which pulls root motion out of an authored clip into the
// tracks this header's zozzMotionBlend then recombines at runtime.
//
// Pulled into zozz.h — the umbrella — so a consumer needs only that one
// include; this header stands on its own only because zozz.h pulls it in.
//===----------------------------------------------------------------------===//

#ifndef ZOZZ_MOTION_H_
#define ZOZZ_MOTION_H_

#include "zozz.h"

#ifdef __cplusplus
extern "C" {
#endif

/// One weighted input to zozzMotionBlend.
typedef struct ZozzMotionBlendLayer {
  /// Blending weight. Zero or negative is excluded from the blend, matching
  /// ozz; NaN is rejected.
  float weight;
  /// Borrowed for the call only, not retained afterward. Must not be NULL.
  const ZozzTransform* delta;
} ZozzMotionBlendLayer;

/// Blends `count` motion-delta layers into a single normalized delta:
/// direction-and-length-separated lerp for translation, shortest-arc NLerp
/// for rotation, identity scale. `count` may be 0, which yields the identity
/// transform. `layers`, and every layer's `delta`, need to stay alive only
/// for the call.
ZOZZ_API ZozzResult zozzMotionBlend(const ZozzMotionBlendLayer* layers,
                                    size_t count, ZozzTransform* out);

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // ZOZZ_MOTION_H_
