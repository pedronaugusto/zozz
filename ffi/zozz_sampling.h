//===----------------------------------------------------------------------===//
// zozz — the sampling context, the sampling job, and local-to-model.
//
// Conventions, ownership and thread safety are documented in zozz_core.h.
//===----------------------------------------------------------------------===//

#ifndef ZOZZ_SAMPLING_H_
#define ZOZZ_SAMPLING_H_

#include <stddef.h>

#include "zozz.h"

#ifdef __cplusplus
extern "C" {
#endif

//===----------------------------------------------------------------------===//
// Sampling
//===----------------------------------------------------------------------===//

/// Per-instance scratch that lets forward sampling exploit frame coherency.
/// Not shareable between two animations sampled in the same frame.
typedef struct ZozzSamplingContext ZozzSamplingContext;

/// Creates a context able to sample any animation of at most `max_tracks`
/// tracks. Size it from zozzSkeletonNumJoints, not from one clip, if the
/// context will be reused across clips.
ZOZZ_API ZozzResult zozzSamplingContextCreate(int max_tracks,
                                              ZozzSamplingContext** out);

ZOZZ_API void zozzSamplingContextDestroy(ZozzSamplingContext* context);

/// Resizes `context` in place to support at most `max_tracks` tracks,
/// discarding any prior allocation without giving up the handle, and
/// invalidating it like zozzSamplingContextInvalidate. ozz's own Resize cannot
/// report an allocation failure (it is void), so ZOZZ_RESULT_OUT_OF_MEMORY here
/// is best-effort: an undersized context afterwards is the only observable
/// symptom.
ZOZZ_API ZozzResult zozzSamplingContextResize(ZozzSamplingContext* context,
                                              int max_tracks);

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

//===----------------------------------------------------------------------===//
// Local-to-model
//
// The range parameters are ozz's LocalToModelJob fields, sentinels included,
// not a private "unrestricted" sentinel a wrapper has to translate: INT_MAX
// for `to` overflowed ozz's `Min(to + 1, num_joints)`, so the walk ended
// before it began and the job wrote NOTHING while reporting success.
//
// `from` is ZOZZ_NO_PARENT (ozz's default) to start at the roots, else a joint
// index below zozzSkeletonNumJoints. `to` is a joint index, or ZOZZ_MAX_JOINTS
// (ozz's default) for the last joint; it may exceed the joint count, which is
// how ozz spells "to the end". ozz checks neither bound, so zozz does: an
// out-of-range one is ZOZZ_RESULT_INVALID_ARGUMENT, never a silent no-op.
//===----------------------------------------------------------------------===//

/// Walks [`from`, `to`] of the hierarchy, `to` included, converting local-space
/// SoA transforms to model-space AoS matrices. `root` pre-multiplies every
/// result (NULL for identity). `count` must cover EVERY joint whatever the
/// range: ancestors outside it are read to place the ones inside it. With
/// `from_excluded` non-zero, `from` keeps its existing matrix in `out` -- which
/// must already be valid -- and only its children are updated.
ZOZZ_API ZozzResult zozzLocalToModel(const ZozzSkeleton* skeleton,
                                     const ZozzSoaPose* locals,
                                     const ZozzFloat4x4* root, int from,
                                     int to, int from_excluded,
                                     ZozzFloat4x4* out, size_t count);

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // ZOZZ_SAMPLING_H_
