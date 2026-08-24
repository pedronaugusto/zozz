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
/// discarding whatever allocation it already held — the effect of
/// zozzSamplingContextDestroy + zozzSamplingContextCreate without giving up
/// the handle, for a host that cycles one context across differently-sized
/// skeletons instead of destroying and recreating it each time. Also
/// invalidates the context, exactly like zozzSamplingContextInvalidate.
///
/// ozz's own Resize has no way to report an allocation failure (it is void),
/// so as with zozzSamplingContextCreate, ZOZZ_RESULT_OUT_OF_MEMORY here is
/// best-effort: an undersized context afterwards is the only observable
/// symptom the underlying call leaves to check.
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
//===----------------------------------------------------------------------===//

/// Walks the hierarchy, converting local-space SoA transforms to model-space
/// AoS matrices. `root` is an optional pre-multiplied root matrix (NULL for
/// identity). `count` must be at least the skeleton's joint count.
ZOZZ_API ZozzResult zozzLocalToModel(const ZozzSkeleton* skeleton,
                                     const ZozzSoaPose* locals,
                                     const ZozzFloat4x4* root,
                                     ZozzFloat4x4* out, size_t count);

/// Same as zozzLocalToModel, but restricted to the joint range [from, to]
/// ("to" included), which lets a host re-run only the chain an IK correction
/// touched instead of the whole skeleton. `input` and `out` must still cover
/// every joint regardless of the range — ancestors outside it are read, not
/// written, and a descendant's parent may be one of them.
///
/// `from` is ZOZZ_NO_PARENT to start at the root, and any joint index
/// otherwise; pass zozzSkeletonNumJoints (or larger) as `to` to update
/// through the last joint. If `from_excluded` is non-zero, `from` itself is
/// left untouched in `out` and must already hold a valid model-space matrix
/// there, since its children are expressed relative to it — this is the
/// combination that updates a corrected chain without recomputing the joint
/// the correction was already applied to.
ZOZZ_API ZozzResult zozzLocalToModelRange(const ZozzSkeleton* skeleton,
                                          const ZozzSoaPose* locals,
                                          const ZozzFloat4x4* root, int from,
                                          int to, int from_excluded,
                                          ZozzFloat4x4* out, size_t count);

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // ZOZZ_SAMPLING_H_
