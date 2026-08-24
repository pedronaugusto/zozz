//===----------------------------------------------------------------------===//
// zozz — offline builders: RawSkeleton -> Skeleton, RawAnimation -> Animation.
//
// Author a skeleton or an animation at runtime and build it into the same
// runtime objects the loaders produce. This is ozz's offline pipeline
// (RawSkeleton -> SkeletonBuilder, RawAnimation -> AnimationBuilder) behind
// the same handle rules as everything else; it is also the seam a cook tool
// uses to produce .ozz archives from source data.
//
// Joint order: the built skeleton stores joints in DEPTH-FIRST order of the
// authored hierarchy. If zozzRawSkeletonAddJoint is called in an order that is
// itself a depth-first traversal (every joint immediately after its subtree
// predecessor), built joint indices equal insertion indices; otherwise they
// are reindexed and zozzSkeletonJointName is the mapping. A raw animation
// knows no skeleton: track i pairs with built-skeleton joint i by convention,
// and the caller owns that correspondence.
//
// Empty tracks: a track with no keys bakes IDENTITY keys (ozz's
// AnimationBuilder behaviour) — not the skeleton's rest pose, which the
// builder never sees. A consumer whose contract is "unanimated joints hold
// the rest pose" must author rest-pose keys, or seed the output pose and
// sample a fully-authored clip. Pinned by test.
//
// Conventions, ownership and thread safety are documented in zozz_core.h.
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
/// index of a previously added joint. `name` must be non-NULL (ozz requires
/// unique names for retargeting; zozz does not enforce uniqueness). `rest` is
/// the joint's local rest transform; all components must be finite. On
/// success writes the joint's insertion index to `out_index` (may be NULL).
ZOZZ_API ZozzResult zozzRawSkeletonAddJoint(ZozzRawSkeleton* raw,
                                            int32_t parent, const char* name,
                                            const ZozzTransform* rest,
                                            int32_t* out_index);

ZOZZ_API int zozzRawSkeletonNumJoints(const ZozzRawSkeleton* raw);

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
