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
#include "zozz_track.h"

#ifdef __cplusplus
extern "C" {
#endif

//===----------------------------------------------------------------------===//
// Interpolation
//===----------------------------------------------------------------------===//

typedef enum ZozzTrackInterpolation {
  /// The value at this key holds constant up to the next key.
  ZOZZ_TRACK_INTERPOLATION_STEP = 0,
  /// The value is linearly interpolated between this key and the next.
  ZOZZ_TRACK_INTERPOLATION_LINEAR = 1,
} ZozzTrackInterpolation;

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

//===----------------------------------------------------------------------===//
// RawFloatTrack
//
// Every Raw*Track below repeats this same five-entry-point shape, one per
// value type. `ratio` is a track-local position in [0, 1] (checked at push,
// since unlike a raw animation's duration this range is fixed rather than
// caller-chosen); ordering across keys is a data-shape property and is
// checked at Build/Optimize instead, exactly like a raw animation's key
// times.
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

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // ZOZZ_RAWTRACK_H_
