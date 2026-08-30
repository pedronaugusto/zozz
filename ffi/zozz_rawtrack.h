//===----------------------------------------------------------------------===//
// zozz — raw tracks: the authoring side of ozz's five user-channel track
// value types (float, float2, float3, float4, quaternion), plus building them
// into runtime tracks and optimizing them.
//
// A raw track animates a single variable that is not a joint transform — a
// blend weight, a light intensity, a custom float4 — over a track-local
// [0, 1] ratio rather than a duration in seconds, so it carries no
// discrepancy with whatever animation it is meant to accompany.
//
// Included from zozz.h; not meant to be included on its own, though its own
// `#include "zozz.h"` makes that safe too.
//===----------------------------------------------------------------------===//

#ifndef ZOZZ_RAWTRACK_H_
#define ZOZZ_RAWTRACK_H_

#include <stddef.h>
#include <stdint.h>

#include "zozz.h"

#ifdef __cplusplus
extern "C" {
#endif

//===----------------------------------------------------------------------===//
// Interpolation
//
// Declared before the #include below rather than after: zozz_track.h's own
// keyframe read-back (zozzFloatTrackSteps and its equivalents) reports this
// same enum, and reaches it through the mutual-inclusion this header and
// zozz_track.h already rely on — that only resolves one direction, so this
// definition has to come first textually.
//===----------------------------------------------------------------------===//

typedef enum ZozzTrackInterpolation {
  /// The value at this key holds constant up to the next key.
  ZOZZ_TRACK_INTERPOLATION_STEP = 0,
  /// The value is linearly interpolated between this key and the next.
  ZOZZ_TRACK_INTERPOLATION_LINEAR = 1,
} ZozzTrackInterpolation;


//===----------------------------------------------------------------------===//
// Keyframes
//
// One struct per value type, laid out as ozz lays its own out: a raw track
// stores a vector of whole RawTrackKeyframes (raw_track.h), so the read-back
// below is an array of structs — where a RUNTIME track stores parallel spans
// and zozz_track.h's read-back hands back parallel arrays. The shape follows
// ozz's storage on both sides rather than picking one and converting.
//===----------------------------------------------------------------------===//

typedef struct ZozzRawFloatKeyframe {
  ZozzTrackInterpolation interpolation;
  /// Track-local position, within [0, 1].
  float ratio;
  float value;
} ZozzRawFloatKeyframe;

typedef struct ZozzRawFloat2Keyframe {
  ZozzTrackInterpolation interpolation;
  /// Track-local position, within [0, 1].
  float ratio;
  float value[2];
} ZozzRawFloat2Keyframe;

typedef struct ZozzRawFloat3Keyframe {
  ZozzTrackInterpolation interpolation;
  /// Track-local position, within [0, 1].
  float ratio;
  float value[3];
} ZozzRawFloat3Keyframe;

typedef struct ZozzRawFloat4Keyframe {
  ZozzTrackInterpolation interpolation;
  /// Track-local position, within [0, 1].
  float ratio;
  float value[4];
} ZozzRawFloat4Keyframe;

typedef struct ZozzRawQuaternionKeyframe {
  ZozzTrackInterpolation interpolation;
  /// Track-local position, within [0, 1].
  float ratio;
  /// A quaternion in (x, y, z, w) order — w LAST.
  float value[4];
} ZozzRawQuaternionKeyframe;

//===----------------------------------------------------------------------===//
// Runtime track handles
//
// TrackBuilder's output. These are the exact same opaque types zozz_track.h
// declares, which is what this header includes them from rather than
// redeclaring: zozz_track.h is also where they get loaded, named, sampled and
// edge-triggered. Destroying one built here is still zozz's job, since it was
// allocated through zozz's installed allocator — see zozzFloatTrackDestroy
// and friends there.
//===----------------------------------------------------------------------===//

#include "zozz_track.h"

//===----------------------------------------------------------------------===//
// RawFloatTrack
//
// Every Raw*Track below repeats the same shape, one per value type: create,
// destroy, push, build and optimize, then the read-back and editing half —
// validate, name, rename, keyframes, clear.
//
// `ratio` is a track-local position in [0, 1] (checked at push, since unlike
// a raw animation's duration this range is fixed rather than caller-chosen);
// ordering across keys is a data-shape property and is checked at
// Build/Optimize instead, exactly like a raw animation's key times.
//===----------------------------------------------------------------------===//

ZOZZ_API ZozzResult zozzRawFloatTrackCreate(ZozzRawFloatTrack** out);
ZOZZ_API void zozzRawFloatTrackDestroy(ZozzRawFloatTrack* raw);
ZOZZ_API int zozzRawFloatTrackNumKeyframes(const ZozzRawFloatTrack* raw);

/// Appends one keyframe. `ratio` must be finite and within [0, 1]; `value`
/// must be finite. Keys must be pushed in non-decreasing ratio order —
/// violations surface at Build/Optimize as ZOZZ_RESULT_INVALID_DATA.
ZOZZ_API ZozzResult zozzRawFloatTrackPushKeyframe(
    ZozzRawFloatTrack* raw, ZozzTrackInterpolation interpolation, float ratio,
    float value);

/// Validates and builds a runtime track. The raw track is not consumed.
ZOZZ_API ZozzResult zozzFloatTrackBuild(const ZozzRawFloatTrack* raw,
                                       ZozzFloatTrack** out);

/// Key-frame reduction within `tolerance` (see ZozzOptimizerSetting for the
/// same idea applied to a whole animation). `output` must be a distinct,
/// already-created raw track; its previous contents are discarded even on
/// failure. Fails with ZOZZ_RESULT_INVALID_DATA if `input` does not pass
/// validation.
ZOZZ_API ZozzResult zozzRawFloatTrackOptimize(const ZozzRawFloatTrack* input,
                                              float tolerance,
                                              ZozzRawFloatTrack* output);

/// ozz::animation::offline::RawTrack::Validate(): keyframe ratios strictly
/// ascending and all within [0, 1]. False for a NULL handle. The same answer
/// Build and Optimize report as ZOZZ_RESULT_INVALID_DATA, available before
/// either, so a cook tool can name the malformed track rather than the failed
/// build.
ZOZZ_API bool zozzRawFloatTrackValidate(const ZozzRawFloatTrack* raw);

/// Borrowed, NUL-terminated track name — "" for an unnamed track, NULL only
/// for a NULL handle. Valid until the handle is destroyed or renamed.
/// TrackBuilder copies this into the runtime track it produces, which is what
/// makes it worth setting.
ZOZZ_API const char* zozzRawFloatTrackName(const ZozzRawFloatTrack* raw);

/// Renames the track. `name` may be NULL, which clears it to "". The string
/// is copied.
ZOZZ_API ZozzResult zozzRawFloatTrackSetName(ZozzRawFloatTrack* raw,
                                             const char* name);

/// Copies every keyframe into `out`, in authored order. `count` is the
/// capacity of `out` in keyframes and must be at least
/// zozzRawFloatTrackNumKeyframes, else ZOZZ_RESULT_BUFFER_TOO_SMALL and
/// nothing is written. Caller-owned memory; this never allocates.
ZOZZ_API ZozzResult zozzRawFloatTrackKeyframes(const ZozzRawFloatTrack* raw,
                                               ZozzRawFloatKeyframe* out,
                                               size_t count);

/// Drops every keyframe, keeping the name. Editing a track means clearing it
/// and pushing its replacement keys; ozz has no key removal by index either —
/// its vector is the storage.
ZOZZ_API ZozzResult zozzRawFloatTrackClear(ZozzRawFloatTrack* raw);

//===----------------------------------------------------------------------===//
// RawFloat2Track
//===----------------------------------------------------------------------===//

ZOZZ_API ZozzResult zozzRawFloat2TrackCreate(ZozzRawFloat2Track** out);
ZOZZ_API void zozzRawFloat2TrackDestroy(ZozzRawFloat2Track* raw);
ZOZZ_API int zozzRawFloat2TrackNumKeyframes(const ZozzRawFloat2Track* raw);
ZOZZ_API ZozzResult zozzRawFloat2TrackPushKeyframe(
    ZozzRawFloat2Track* raw, ZozzTrackInterpolation interpolation, float ratio,
    const float value[2]);
ZOZZ_API ZozzResult zozzFloat2TrackBuild(const ZozzRawFloat2Track* raw,
                                        ZozzFloat2Track** out);
ZOZZ_API ZozzResult zozzRawFloat2TrackOptimize(const ZozzRawFloat2Track* input,
                                               float tolerance,
                                               ZozzRawFloat2Track* output);

/// See zozzRawFloatTrackValidate.
ZOZZ_API bool zozzRawFloat2TrackValidate(const ZozzRawFloat2Track* raw);

/// See zozzRawFloatTrackName.
ZOZZ_API const char* zozzRawFloat2TrackName(const ZozzRawFloat2Track* raw);

/// See zozzRawFloatTrackSetName.
ZOZZ_API ZozzResult zozzRawFloat2TrackSetName(ZozzRawFloat2Track* raw,
                                              const char* name);

/// See zozzRawFloatTrackKeyframes.
ZOZZ_API ZozzResult zozzRawFloat2TrackKeyframes(const ZozzRawFloat2Track* raw,
                                                ZozzRawFloat2Keyframe* out,
                                                size_t count);

/// See zozzRawFloatTrackClear.
ZOZZ_API ZozzResult zozzRawFloat2TrackClear(ZozzRawFloat2Track* raw);

//===----------------------------------------------------------------------===//
// RawFloat3Track
//===----------------------------------------------------------------------===//

ZOZZ_API ZozzResult zozzRawFloat3TrackCreate(ZozzRawFloat3Track** out);
ZOZZ_API void zozzRawFloat3TrackDestroy(ZozzRawFloat3Track* raw);
ZOZZ_API int zozzRawFloat3TrackNumKeyframes(const ZozzRawFloat3Track* raw);
ZOZZ_API ZozzResult zozzRawFloat3TrackPushKeyframe(
    ZozzRawFloat3Track* raw, ZozzTrackInterpolation interpolation, float ratio,
    const float value[3]);
ZOZZ_API ZozzResult zozzFloat3TrackBuild(const ZozzRawFloat3Track* raw,
                                        ZozzFloat3Track** out);
ZOZZ_API ZozzResult zozzRawFloat3TrackOptimize(const ZozzRawFloat3Track* input,
                                               float tolerance,
                                               ZozzRawFloat3Track* output);

/// See zozzRawFloatTrackValidate.
ZOZZ_API bool zozzRawFloat3TrackValidate(const ZozzRawFloat3Track* raw);

/// See zozzRawFloatTrackName.
ZOZZ_API const char* zozzRawFloat3TrackName(const ZozzRawFloat3Track* raw);

/// See zozzRawFloatTrackSetName.
ZOZZ_API ZozzResult zozzRawFloat3TrackSetName(ZozzRawFloat3Track* raw,
                                              const char* name);

/// See zozzRawFloatTrackKeyframes.
ZOZZ_API ZozzResult zozzRawFloat3TrackKeyframes(const ZozzRawFloat3Track* raw,
                                                ZozzRawFloat3Keyframe* out,
                                                size_t count);

/// See zozzRawFloatTrackClear.
ZOZZ_API ZozzResult zozzRawFloat3TrackClear(ZozzRawFloat3Track* raw);

//===----------------------------------------------------------------------===//
// RawFloat4Track
//===----------------------------------------------------------------------===//

ZOZZ_API ZozzResult zozzRawFloat4TrackCreate(ZozzRawFloat4Track** out);
ZOZZ_API void zozzRawFloat4TrackDestroy(ZozzRawFloat4Track* raw);
ZOZZ_API int zozzRawFloat4TrackNumKeyframes(const ZozzRawFloat4Track* raw);
ZOZZ_API ZozzResult zozzRawFloat4TrackPushKeyframe(
    ZozzRawFloat4Track* raw, ZozzTrackInterpolation interpolation, float ratio,
    const float value[4]);
ZOZZ_API ZozzResult zozzFloat4TrackBuild(const ZozzRawFloat4Track* raw,
                                        ZozzFloat4Track** out);
ZOZZ_API ZozzResult zozzRawFloat4TrackOptimize(const ZozzRawFloat4Track* input,
                                               float tolerance,
                                               ZozzRawFloat4Track* output);

/// See zozzRawFloatTrackValidate.
ZOZZ_API bool zozzRawFloat4TrackValidate(const ZozzRawFloat4Track* raw);

/// See zozzRawFloatTrackName.
ZOZZ_API const char* zozzRawFloat4TrackName(const ZozzRawFloat4Track* raw);

/// See zozzRawFloatTrackSetName.
ZOZZ_API ZozzResult zozzRawFloat4TrackSetName(ZozzRawFloat4Track* raw,
                                              const char* name);

/// See zozzRawFloatTrackKeyframes.
ZOZZ_API ZozzResult zozzRawFloat4TrackKeyframes(const ZozzRawFloat4Track* raw,
                                                ZozzRawFloat4Keyframe* out,
                                                size_t count);

/// See zozzRawFloatTrackClear.
ZOZZ_API ZozzResult zozzRawFloat4TrackClear(ZozzRawFloat4Track* raw);

//===----------------------------------------------------------------------===//
// RawQuaternionTrack
//
// `value` is a quaternion in (x, y, z, w) order — w LAST, matching every
// other rotation in this ABI.
//===----------------------------------------------------------------------===//

ZOZZ_API ZozzResult zozzRawQuaternionTrackCreate(ZozzRawQuaternionTrack** out);
ZOZZ_API void zozzRawQuaternionTrackDestroy(ZozzRawQuaternionTrack* raw);
ZOZZ_API int zozzRawQuaternionTrackNumKeyframes(
    const ZozzRawQuaternionTrack* raw);
ZOZZ_API ZozzResult zozzRawQuaternionTrackPushKeyframe(
    ZozzRawQuaternionTrack* raw, ZozzTrackInterpolation interpolation,
    float ratio, const float value[4]);
ZOZZ_API ZozzResult zozzQuaternionTrackBuild(const ZozzRawQuaternionTrack* raw,
                                             ZozzQuaternionTrack** out);
ZOZZ_API ZozzResult zozzRawQuaternionTrackOptimize(
    const ZozzRawQuaternionTrack* input, float tolerance,
    ZozzRawQuaternionTrack* output);

/// See zozzRawFloatTrackValidate.
ZOZZ_API bool zozzRawQuaternionTrackValidate(const ZozzRawQuaternionTrack* raw);

/// See zozzRawFloatTrackName.
ZOZZ_API const char* zozzRawQuaternionTrackName(
    const ZozzRawQuaternionTrack* raw);

/// See zozzRawFloatTrackSetName.
ZOZZ_API ZozzResult zozzRawQuaternionTrackSetName(ZozzRawQuaternionTrack* raw,
                                                  const char* name);

/// See zozzRawFloatTrackKeyframes.
ZOZZ_API ZozzResult zozzRawQuaternionTrackKeyframes(
    const ZozzRawQuaternionTrack* raw,
    ZozzRawQuaternionKeyframe* out,
    size_t count);

/// See zozzRawFloatTrackClear.
ZOZZ_API ZozzResult zozzRawQuaternionTrackClear(ZozzRawQuaternionTrack* raw);

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // ZOZZ_RAWTRACK_H_
