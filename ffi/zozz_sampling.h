//===----------------------------------------------------------------------===//
// zozz — sampling a clip into a pose, and flattening a pose to model space.
//
// Conventions, ownership and thread safety are documented in zozz_core.h.
//===----------------------------------------------------------------------===//

#ifndef ZOZZ_SAMPLING_H_
#define ZOZZ_SAMPLING_H_

#include <stddef.h>

#include "zozz_animation.h"
#include "zozz_core.h"
#include "zozz_pose.h"
#include "zozz_skeleton.h"

#ifdef __cplusplus
extern "C" {
#endif

/// Per-instance scratch that lets forward sampling exploit frame coherency.
/// Not shareable between two animations sampled in the same frame.
typedef struct ZozzSamplingContext ZozzSamplingContext;

/// Creates a context able to sample any animation of at most `max_tracks`
/// tracks. Size it from zozzSkeletonNumJoints, not from one clip, if the
/// context will be reused across clips.
ZOZZ_API ZozzResult zozzSamplingContextCreate(int max_tracks,
                                              ZozzSamplingContext** out);

ZOZZ_API void zozzSamplingContextDestroy(ZozzSamplingContext* context);

/// Drops cached keyframe state. Required before reusing a context with a
/// different animation that may have been allocated at a recycled address.
ZOZZ_API void zozzSamplingContextInvalidate(ZozzSamplingContext* context);

ZOZZ_API int zozzSamplingContextMaxTracks(const ZozzSamplingContext* context);

/// Samples `animation` at `ratio` (unit interval, clamped) into `out`.
///
/// `out` must hold at least as many joints as the animation has tracks.
/// Joints beyond the animation's track count are left untouched — seed them
/// with zozzSoaPoseSetRestPose if the animation is partial.
ZOZZ_API ZozzResult zozzSample(const ZozzAnimation* animation,
                               ZozzSamplingContext* context, float ratio,
                               ZozzSoaPose* out);

/// Walks the hierarchy, converting local-space SoA transforms to model-space
/// AoS matrices. `root` is an optional pre-multiplied root matrix (NULL for
/// identity). `count` must be at least the skeleton's joint count.
ZOZZ_API ZozzResult zozzLocalToModel(const ZozzSkeleton* skeleton,
                                     const ZozzSoaPose* locals,
                                     const ZozzFloat4x4* root,
                                     ZozzFloat4x4* out, size_t count);

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // ZOZZ_SAMPLING_H_
