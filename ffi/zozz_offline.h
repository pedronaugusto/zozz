//===----------------------------------------------------------------------===//
// zozz — offline builders: RawSkeleton -> Skeleton, RawAnimation -> Animation:
// ozz's offline pipeline, behind the same handle rules as everywhere else,
// and the seam a cook tool uses for .ozz archives from source data.
//
// Joint order: built skeletons store joints DEPTH-FIRST. Adding joints
// depth-first (each right after its subtree predecessor) makes built index
// equal insertion index; otherwise zozzSkeletonJointName maps one to the
// other. A raw animation knows no skeleton: track i pairs with built joint i
// by convention, caller-owned. Empty tracks bake IDENTITY keys (ozz's
// AnimationBuilder), never the rest pose, which the builder never sees;
// "unanimated = rest pose" needs authored rest-pose keys or a seeded output
// pose. Pinned by test. Conventions/ownership/thread safety: zozz_core.h.
//===----------------------------------------------------------------------===//

#ifndef ZOZZ_OFFLINE_H_
#define ZOZZ_OFFLINE_H_

#include <stddef.h>
#include <stdint.h>

#include "zozz.h"

#ifdef __cplusplus
extern "C" {
#endif

//===----------------------------------------------------------------------===//
// Raw skeleton
//===----------------------------------------------------------------------===//

/// A skeleton under construction: a flat list of (parent, name, rest) joints.
typedef struct ZozzRawSkeleton ZozzRawSkeleton;

ZOZZ_API ZozzResult zozzRawSkeletonCreate(ZozzRawSkeleton** out);

ZOZZ_API void zozzRawSkeletonDestroy(ZozzRawSkeleton* raw);

/// Appends a joint. `parent` is ZOZZ_NO_PARENT for a root, else the insertion
/// index of an already-added joint. `name` must be non-NULL (ozz requires
/// unique names for retargeting; zozz does not enforce uniqueness). `rest` is
/// the joint's local rest transform; all components must be finite. On
/// success writes the joint's insertion index to `out_index` (may be NULL).
ZOZZ_API ZozzResult zozzRawSkeletonAddJoint(ZozzRawSkeleton* raw,
                                            int32_t parent, const char* name,
                                            const ZozzTransform* rest,
                                            int32_t* out_index);

ZOZZ_API int zozzRawSkeletonNumJoints(const ZozzRawSkeleton* raw);

//===----------------------------------------------------------------------===//
// Raw skeleton read-back
//
// A joint here is addressed by INSERTION index — the index
// zozzRawSkeletonAddJoint returned through `out_index` — never by a position
// in the depth-first tree zozzSkeletonBuild produces. The two coincide only
// when joints were added in depth-first order to begin with (see the module
// comment above); otherwise a built skeleton's own zozzSkeletonJointName is
// what maps a built index back to a name.
//===----------------------------------------------------------------------===//

/// Borrowed, NUL-terminated name of the joint at insertion index `joint`, or
/// NULL if `raw` is NULL or `joint` is out of range.
ZOZZ_API const char* zozzRawSkeletonJointName(const ZozzRawSkeleton* raw,
                                              int32_t joint);

/// Parent's insertion index, or ZOZZ_NO_PARENT for a root. Returns
/// ZOZZ_NO_PARENT for an out-of-range `joint` too — check against
/// zozzRawSkeletonNumJoints first if the distinction matters.
ZOZZ_API int32_t zozzRawSkeletonJointParent(const ZozzRawSkeleton* raw,
                                            int32_t joint);

/// The local-space rest transform authored for the joint at insertion index
/// `joint` — exactly the `rest` last passed to zozzRawSkeletonAddJoint for it.
ZOZZ_API ZozzResult zozzRawSkeletonJointRest(const ZozzRawSkeleton* raw,
                                             int32_t joint, ZozzTransform* out);

/// Breadth-first traversal of the authored hierarchy (ZozzJointVisitor,
/// zozz_utils.h); `joint`/`parent` are insertion indices, not the built
/// indices zozzSkeletonIterateJointsDepthFirst reports. `parent` is
/// ZOZZ_NO_PARENT for a root. NOT a single global level order with
/// multiple roots or uneven depths: a grandchild of the first root can
/// visit before a child of the second.
ZOZZ_API ZozzResult zozzRawSkeletonIterateJointsBreadthFirst(
    const ZozzRawSkeleton* raw, ZozzJointVisitor visitor, void* user);

/// Validates and builds a runtime skeleton. The raw skeleton is not consumed
/// and may be built again or extended further.
ZOZZ_API ZozzResult zozzSkeletonBuild(const ZozzRawSkeleton* raw,
                                      ZozzSkeleton** out);

//===----------------------------------------------------------------------===//
// Raw animation
//===----------------------------------------------------------------------===//

/// An animation under construction: per-track keyed T/R/S channels.
typedef struct ZozzRawAnimation ZozzRawAnimation;

/// Creates a raw animation with a fixed track count and duration (seconds,
/// finite, > 0). `name` may be NULL for an unnamed clip.
ZOZZ_API ZozzResult zozzRawAnimationCreate(int num_tracks, float duration,
                                           const char* name,
                                           ZozzRawAnimation** out);

ZOZZ_API void zozzRawAnimationDestroy(ZozzRawAnimation* raw);

ZOZZ_API int zozzRawAnimationNumTracks(const ZozzRawAnimation* raw);

ZOZZ_API float zozzRawAnimationDuration(const ZozzRawAnimation* raw);

/// Appends one translation key to `track`. `time` must be finite and within
/// [0, duration]; `value` must be finite. Keys must be pushed in
/// non-decreasing time order per channel — violations surface at
/// zozzAnimationBuild as ZOZZ_RESULT_INVALID_DATA.
ZOZZ_API ZozzResult zozzRawAnimationPushTranslation(ZozzRawAnimation* raw,
                                                    int track, float time,
                                                    const float value[3]);

/// Appends one rotation key: a quaternion in (x, y, z, w) order — w LAST.
ZOZZ_API ZozzResult zozzRawAnimationPushRotation(ZozzRawAnimation* raw,
                                                 int track, float time,
                                                 const float value[4]);

/// Appends one scale key.
ZOZZ_API ZozzResult zozzRawAnimationPushScale(ZozzRawAnimation* raw, int track,
                                              float time,
                                              const float value[3]);

/// Validates and builds a compressed runtime animation. The raw animation is
/// not consumed.
ZOZZ_API ZozzResult zozzAnimationBuild(const ZozzRawAnimation* raw,
                                       ZozzAnimation** out);

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // ZOZZ_OFFLINE_H_
