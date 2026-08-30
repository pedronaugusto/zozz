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

#ifndef __cplusplus
#include <stdbool.h>
#endif

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

/// ozz::animation::offline::RawSkeleton::Validate(): true when the joint
/// count is within ozz::animation::Skeleton::kMaxJoints. False for a NULL
/// handle. zozzRawSkeletonAddJoint already refuses the joint that would
/// exceed the limit, so only a skeleton filled by an importer
/// (zozz_gltf.h) or read back from an archive can fail. zozzSkeletonBuild
/// turns the same answer into ZOZZ_RESULT_INVALID_DATA.
ZOZZ_API bool zozzRawSkeletonValidate(const ZozzRawSkeleton* raw);

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

//===----------------------------------------------------------------------===//
// Raw animation read-back
//
// The read twin of the three Push entry points above, so a clip that arrived
// from an importer, an optimizer or an archive can be inspected, edited and
// written back out — not only built. One key type per channel, laid out as
// ozz lays its own out: a RawAnimation stores three vectors of whole
// keyframes per track (raw_animation.h), so these are arrays of structs,
// where a runtime track stores parallel spans and zozz_track.h's read-back
// hands back parallel arrays. The shape follows ozz's storage in both cases.
//
// Names match ozz's own members: `translations`, `rotations`, `scales`.
//===----------------------------------------------------------------------===//

/// One authored translation key: ozz's RawAnimation::TranslationKey.
typedef struct ZozzRawTranslationKey {
  /// Seconds, within [0, duration].
  float time;
  float value[3];
} ZozzRawTranslationKey;

/// One authored rotation key: ozz's RawAnimation::RotationKey. `value` is a
/// quaternion in (x, y, z, w) order — w LAST, as everywhere in this ABI.
typedef struct ZozzRawRotationKey {
  float time;
  float value[4];
} ZozzRawRotationKey;

/// One authored scale key: ozz's RawAnimation::ScaleKey.
typedef struct ZozzRawScaleKey {
  float time;
  float value[3];
} ZozzRawScaleKey;

/// ozz::animation::offline::RawAnimation::Validate(): duration positive,
/// every key time within [0, duration], key times strictly ascending per
/// channel. False for a NULL handle.
///
/// The same answer zozzAnimationBuild reports as ZOZZ_RESULT_INVALID_DATA,
/// available before the build.
ZOZZ_API bool zozzRawAnimationValidate(const ZozzRawAnimation* raw);

/// ozz::animation::offline::RawAnimation::size(): the estimated size of the
/// authored data in bytes, ozz's own accounting. 0 for a NULL handle. This
/// is the OFFLINE footprint; the built runtime clip's is
/// zozzAnimationSize.
ZOZZ_API size_t zozzRawAnimationSize(const ZozzRawAnimation* raw);

/// Borrowed, NUL-terminated clip name — whatever was passed to
/// zozzRawAnimationCreate, or "" if that was NULL. NULL only for a NULL
/// handle. Valid until the handle is destroyed.
ZOZZ_API const char* zozzRawAnimationName(const ZozzRawAnimation* raw);

/// Renames the clip. `name` may be NULL, which clears it to "". The string is
/// copied. AnimationBuilder copies the name into the runtime clip it
/// produces, which is what makes it worth setting on one that arrived from an
/// importer or an optimizer unnamed.
ZOZZ_API ZozzResult zozzRawAnimationSetName(ZozzRawAnimation* raw,
                                            const char* name);

/// Retimes the clip: `duration` in seconds, finite and > 0, else
/// ZOZZ_RESULT_INVALID_ARGUMENT. ozz keeps duration as a plain field and this
/// exposes it as one — SHORTENING a clip does not move or drop the keys past
/// the new end, it leaves them out of range, which zozzRawAnimationValidate
/// then reports and zozzAnimationBuild refuses. Clear the channel and push
/// the retimed keys to do it properly.
ZOZZ_API ZozzResult zozzRawAnimationSetDuration(ZozzRawAnimation* raw,
                                                float duration);

/// Number of keys on `track`'s translation channel, or 0 if `raw` is NULL or
/// `track` is out of range — the count the matching read-back below needs.
ZOZZ_API int zozzRawAnimationNumTranslations(const ZozzRawAnimation* raw,
                                             int track);

ZOZZ_API int zozzRawAnimationNumRotations(const ZozzRawAnimation* raw,
                                          int track);

ZOZZ_API int zozzRawAnimationNumScales(const ZozzRawAnimation* raw, int track);

/// Copies `track`'s translation keys into `out`, in authored order. `count`
/// is the capacity of `out` in keys and must be at least
/// zozzRawAnimationNumTranslations, else ZOZZ_RESULT_BUFFER_TOO_SMALL and
/// nothing is written. Caller-owned memory, exactly as the runtime track
/// read-back in zozz_track.h works; this never allocates.
ZOZZ_API ZozzResult zozzRawAnimationTranslations(const ZozzRawAnimation* raw,
                                                 int track,
                                                 ZozzRawTranslationKey* out,
                                                 size_t count);

ZOZZ_API ZozzResult zozzRawAnimationRotations(const ZozzRawAnimation* raw,
                                              int track,
                                              ZozzRawRotationKey* out,
                                              size_t count);

ZOZZ_API ZozzResult zozzRawAnimationScales(const ZozzRawAnimation* raw,
                                           int track, ZozzRawScaleKey* out,
                                           size_t count);

/// Drops every key on `track`'s translation channel, leaving the other two
/// alone. The track itself remains — a clip's track count is fixed at
/// creation, and an empty channel bakes an identity key at build (see this
/// header's module comment). Rewriting a channel is clear-then-push: ozz has
/// no key removal by index either, since its vectors are the storage.
ZOZZ_API ZozzResult zozzRawAnimationClearTranslations(ZozzRawAnimation* raw,
                                                      int track);

ZOZZ_API ZozzResult zozzRawAnimationClearRotations(ZozzRawAnimation* raw,
                                                   int track);

ZOZZ_API ZozzResult zozzRawAnimationClearScales(ZozzRawAnimation* raw,
                                                int track);

/// All three channels of `track` at once.
ZOZZ_API ZozzResult zozzRawAnimationClearTrack(ZozzRawAnimation* raw,
                                               int track);

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // ZOZZ_OFFLINE_H_
