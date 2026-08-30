//===----------------------------------------------------------------------===//
// zozz — skeleton loading and queries.
//
// Conventions, ownership and thread safety are documented in zozz_core.h.
//===----------------------------------------------------------------------===//

#ifndef ZOZZ_SKELETON_H_
#define ZOZZ_SKELETON_H_

#include <stddef.h>
#include <stdint.h>

#include "zozz.h"

#ifdef __cplusplus
extern "C" {
#endif

/// A joint hierarchy with rest pose. Immutable once loaded.
typedef struct ZozzSkeleton ZozzSkeleton;

/// Loads a skeleton from a .ozz file produced by an ozz offline tool.
ZOZZ_API ZozzResult zozzSkeletonLoadFile(const char* path, ZozzSkeleton** out);

/// Loads a skeleton from a memory image of a .ozz file. The buffer is read
/// during the call only and is not retained.
ZOZZ_API ZozzResult zozzSkeletonLoadMemory(const void* data, size_t size,
                                           ZozzSkeleton** out);

ZOZZ_API void zozzSkeletonDestroy(ZozzSkeleton* skeleton);

ZOZZ_API int zozzSkeletonNumJoints(const ZozzSkeleton* skeleton);

/// Number of SoA blocks: (num_joints + 3) / 4.
ZOZZ_API int zozzSkeletonNumSoaJoints(const ZozzSkeleton* skeleton);

/// Borrowed, NUL-terminated joint name, or NULL if `joint` is out of range.
ZOZZ_API const char* zozzSkeletonJointName(const ZozzSkeleton* skeleton,
                                           int joint);

/// Parent index, or ZOZZ_NO_PARENT for a root. Returns ZOZZ_NO_PARENT for an
/// out-of-range `joint` as well — check against zozzSkeletonNumJoints first if
/// the distinction matters.
#define ZOZZ_NO_PARENT (-1)
ZOZZ_API int16_t zozzSkeletonJointParent(const ZozzSkeleton* skeleton,
                                         int joint);

/// Hard joint-count ceiling, ozz's own Skeleton::kMaxJoints. It is also the
/// value ozz gives LocalToModelJob::to by default, meaning "to the last
/// joint" -- zozz_abi.cpp static_asserts both against ozz.
#define ZOZZ_MAX_JOINTS 1024

/// Writes the rest pose as AoS local transforms. `count` must be at least
/// zozzSkeletonNumJoints, else ZOZZ_RESULT_BUFFER_TOO_SMALL.
ZOZZ_API ZozzResult zozzSkeletonRestPose(const ZozzSkeleton* skeleton,
                                         ZozzTransform* out, size_t count);

/// Copies ozz's own joint_rest_poses into `out`, no transpose. This is how a
/// pose is seeded before sampling an animation that drives only some of the
/// skeleton's joints: the joints the animation misses keep the rest pose.
/// `blocks` must be at least zozzSkeletonNumSoaJoints and `out` 16-byte
/// aligned, else ZOZZ_RESULT_BUFFER_TOO_SMALL / ZOZZ_RESULT_INVALID_ARGUMENT.
ZOZZ_API ZozzResult zozzSkeletonRestPoseSoa(const ZozzSkeleton* skeleton,
                                            ZozzSoaTransform* out,
                                            size_t blocks);

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // ZOZZ_SKELETON_H_
