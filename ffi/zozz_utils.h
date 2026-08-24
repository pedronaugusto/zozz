//===----------------------------------------------------------------------===//
// zozz — skeleton and animation utilities: single-joint rest-pose access,
// hierarchy traversal, name lookup, and per-track keyframe counts.
//
// Mirrors ozz's own skeleton_utils.h and animation_utils.h. Pulled into
// zozz.h — the umbrella — so a consumer needs only that one include; this
// header stands on its own only because zozz.h pulls it in.
//===----------------------------------------------------------------------===//

#ifndef ZOZZ_UTILS_H_
#define ZOZZ_UTILS_H_

#include "zozz.h"

#ifdef __cplusplus
extern "C" {
#endif

//===----------------------------------------------------------------------===//
// Skeleton utilities
//===----------------------------------------------------------------------===//

/// Local-space rest transform of a single joint, without reading the rest of
/// the skeleton. `joint` must be in [0, zozzSkeletonNumJoints).
ZOZZ_API ZozzResult zozzSkeletonJointRestPoseLocal(const ZozzSkeleton* skeleton,
                                                   int joint,
                                                   ZozzTransform* out);

/// Rest pose in model space, computed by walking the joint hierarchy once.
/// `count` must be at least zozzSkeletonNumJoints, else
/// ZOZZ_RESULT_BUFFER_TOO_SMALL. `out` must be 16-byte aligned, like
/// zozzLocalToModel's output.
ZOZZ_API ZozzResult zozzSkeletonRestPoseModelSpace(const ZozzSkeleton* skeleton,
                                                   ZozzFloat4x4* out,
                                                   size_t count);

/// Writes 1 to `*out` if `joint` has no children — it is the last joint, or
/// the next joint's parent is not `joint` — 0 otherwise. `joint` must be in
/// [0, zozzSkeletonNumJoints).
ZOZZ_API ZozzResult zozzSkeletonJointIsLeaf(const ZozzSkeleton* skeleton,
                                           int joint, int* out);

/// Finds a joint by exact, case-sensitive name. Returns its index, or -1 if
/// `skeleton` or `name` is NULL, or no joint matches.
ZOZZ_API int zozzSkeletonFindJoint(const ZozzSkeleton* skeleton,
                                   const char* name);

/// Visits one joint of a traversal. `parent` is ZOZZ_NO_PARENT when `joint`
/// is a root of the traversal. Must not throw or unwind: nothing on this
/// side of the call can propagate an exception across it, and a Zig
/// implementation must stash any error in `user` and re-raise it after the
/// call returns rather than crossing the boundary with it.
typedef void (*ZozzJointVisitor)(int joint, int parent, void* user);

/// Depth-first traversal of the joints at or below `from`. Pass
/// ZOZZ_NO_PARENT to traverse the whole hierarchy, including every root when
/// the skeleton has more than one. `from` must be ZOZZ_NO_PARENT or a valid
/// joint index.
ZOZZ_API ZozzResult zozzSkeletonIterateJointsDepthFirst(
    const ZozzSkeleton* skeleton, int from, ZozzJointVisitor visitor,
    void* user);

/// Depth-first traversal of the whole hierarchy in reverse: every joint
/// before its parent, leaves before roots.
ZOZZ_API ZozzResult zozzSkeletonIterateJointsDepthFirstReverse(
    const ZozzSkeleton* skeleton, ZozzJointVisitor visitor, void* user);

//===----------------------------------------------------------------------===//
// Animation utilities
//===----------------------------------------------------------------------===//

/// Counts translation keyframes. `track` selects one track in
/// [0, zozzAnimationNumTracks), or -1 to count every track's keys together.
ZOZZ_API ZozzResult zozzAnimationCountTranslationKeys(
    const ZozzAnimation* animation, int track, int* out);

/// Counts rotation keyframes. See zozzAnimationCountTranslationKeys.
ZOZZ_API ZozzResult zozzAnimationCountRotationKeys(
    const ZozzAnimation* animation, int track, int* out);

/// Counts scale keyframes. See zozzAnimationCountTranslationKeys.
ZOZZ_API ZozzResult zozzAnimationCountScaleKeys(const ZozzAnimation* animation,
                                                int track, int* out);

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // ZOZZ_UTILS_H_
