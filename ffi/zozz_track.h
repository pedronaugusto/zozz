//===----------------------------------------------------------------------===//
// zozz — runtime user tracks.
//
// A track is a keyframed curve over a single value (float, a 2/3/4-component
// vector, or quaternion) for game-authored signals like "footstep intensity"
// that ride alongside a clip but are not a joint transform. ozz templates the
// runtime type over five value types; this header declares one entry-point set
// per type, with no generic "Track" handle.
//
// Edge triggering (below) is the one piece here that is not a plain call:
// ozz's own iterator is a stateful C++ object with a private constructor, so
// it crosses this boundary as an opaque, explicitly-destroyed handle stepped
// with `next` / `valid` / `get` rather than as a value.
//===----------------------------------------------------------------------===//

#ifndef ZOZZ_TRACK_H_
#define ZOZZ_TRACK_H_

#include "zozz.h"

#ifndef __cplusplus
#include <stdbool.h>
#endif

#ifdef __cplusplus
extern "C" {
#endif

//===----------------------------------------------------------------------===//
// Opaque handles — one per track value type. Immutable once loaded.
//===----------------------------------------------------------------------===//

typedef struct ZozzFloatTrack ZozzFloatTrack;
typedef struct ZozzFloat2Track ZozzFloat2Track;
typedef struct ZozzFloat3Track ZozzFloat3Track;
typedef struct ZozzFloat4Track ZozzFloat4Track;
typedef struct ZozzQuaternionTrack ZozzQuaternionTrack;

//===----------------------------------------------------------------------===//
// FloatTrack
//===----------------------------------------------------------------------===//

ZOZZ_API ZozzResult zozzFloatTrackLoadFile(const char* path,
                                           ZozzFloatTrack** out);

ZOZZ_API ZozzResult zozzFloatTrackLoadMemory(const void* data, size_t size,
                                             ZozzFloatTrack** out);

ZOZZ_API void zozzFloatTrackDestroy(ZozzFloatTrack* track);

/// Borrowed, NUL-terminated track name; "" if unnamed or `track` is NULL.
ZOZZ_API const char* zozzFloatTrackName(const ZozzFloatTrack* track);

/// Samples `track` at `ratio` (0 is the start of the track, 1 is the end;
/// out-of-range values are clamped by ozz). Empty tracks sample as 0.
ZOZZ_API ZozzResult zozzFloatTrackSample(const ZozzFloatTrack* track,
                                         float ratio, float* out);

//===----------------------------------------------------------------------===//
// Keyframe read-back
//
// A built track stores its authored keyframes as three parallel, uncompressed
// arrays — ratio, value and interpolation mode, index-aligned — rather than
// the compressed streams behind a runtime Animation. zozzFloatTrackSample and
// its siblings above only ever produce an interpolated value at an arbitrary
// ratio; these read back what the track actually holds, the way a curve
// editor or a diff against another track needs.
//
// Every entry point below repeats the same shape once per value type, so it
// is documented in full here for FloatTrack and only by name for the rest.
//===----------------------------------------------------------------------===//

/// Number of keyframes `track` holds. 0 for an empty or NULL track.
ZOZZ_API int zozzFloatTrackNumKeyframes(const ZozzFloatTrack* track);

/// Writes each keyframe's ratio, ascending. `count` must be at least
/// zozzFloatTrackNumKeyframes, else ZOZZ_RESULT_BUFFER_TOO_SMALL.
ZOZZ_API ZozzResult zozzFloatTrackRatios(const ZozzFloatTrack* track,
                                         float* out, size_t count);

/// Writes each keyframe's authored value, index-aligned with
/// zozzFloatTrackRatios: `out[i]` is the value AT keyframe i, not an
/// interpolated sample. `count` must be at least zozzFloatTrackNumKeyframes,
/// else ZOZZ_RESULT_BUFFER_TOO_SMALL.
ZOZZ_API ZozzResult zozzFloatTrackValues(const ZozzFloatTrack* track,
                                         float* out, size_t count);

/// Writes each keyframe's interpolation mode, index-aligned with
/// zozzFloatTrackRatios. ozz packs this as one bit per key (Track::steps(),
/// bit i of byte i/8, least-significant bit first) rather than as this array;
/// this decodes it to one ZozzTrackInterpolation per key so a host never has
/// to index the bitset itself. `count` must be at least
/// zozzFloatTrackNumKeyframes, else ZOZZ_RESULT_BUFFER_TOO_SMALL.
ZOZZ_API ZozzResult zozzFloatTrackSteps(const ZozzFloatTrack* track,
                                        ZozzTrackInterpolation* out,
                                        size_t count);

//===----------------------------------------------------------------------===//
// Float2Track
//===----------------------------------------------------------------------===//

ZOZZ_API ZozzResult zozzFloat2TrackLoadFile(const char* path,
                                            ZozzFloat2Track** out);

ZOZZ_API ZozzResult zozzFloat2TrackLoadMemory(const void* data, size_t size,
                                              ZozzFloat2Track** out);

ZOZZ_API void zozzFloat2TrackDestroy(ZozzFloat2Track* track);

ZOZZ_API const char* zozzFloat2TrackName(const ZozzFloat2Track* track);

ZOZZ_API ZozzResult zozzFloat2TrackSample(const ZozzFloat2Track* track,
                                          float ratio, float out[2]);

/// See zozzFloatTrackNumKeyframes.
ZOZZ_API int zozzFloat2TrackNumKeyframes(const ZozzFloat2Track* track);

/// See zozzFloatTrackRatios.
ZOZZ_API ZozzResult zozzFloat2TrackRatios(const ZozzFloat2Track* track,
                                          float* out, size_t count);

/// See zozzFloatTrackValues. One row per keyframe.
ZOZZ_API ZozzResult zozzFloat2TrackValues(const ZozzFloat2Track* track,
                                          float out[][2], size_t count);

/// See zozzFloatTrackSteps.
ZOZZ_API ZozzResult zozzFloat2TrackSteps(const ZozzFloat2Track* track,
                                         ZozzTrackInterpolation* out,
                                         size_t count);

//===----------------------------------------------------------------------===//
// Float3Track
//===----------------------------------------------------------------------===//

ZOZZ_API ZozzResult zozzFloat3TrackLoadFile(const char* path,
                                            ZozzFloat3Track** out);

ZOZZ_API ZozzResult zozzFloat3TrackLoadMemory(const void* data, size_t size,
                                              ZozzFloat3Track** out);

ZOZZ_API void zozzFloat3TrackDestroy(ZozzFloat3Track* track);

ZOZZ_API const char* zozzFloat3TrackName(const ZozzFloat3Track* track);

ZOZZ_API ZozzResult zozzFloat3TrackSample(const ZozzFloat3Track* track,
                                          float ratio, float out[3]);

/// See zozzFloatTrackNumKeyframes.
ZOZZ_API int zozzFloat3TrackNumKeyframes(const ZozzFloat3Track* track);

/// See zozzFloatTrackRatios.
ZOZZ_API ZozzResult zozzFloat3TrackRatios(const ZozzFloat3Track* track,
                                          float* out, size_t count);

/// See zozzFloatTrackValues. One row per keyframe.
ZOZZ_API ZozzResult zozzFloat3TrackValues(const ZozzFloat3Track* track,
                                          float out[][3], size_t count);

/// See zozzFloatTrackSteps.
ZOZZ_API ZozzResult zozzFloat3TrackSteps(const ZozzFloat3Track* track,
                                         ZozzTrackInterpolation* out,
                                         size_t count);

//===----------------------------------------------------------------------===//
// Float4Track
//===----------------------------------------------------------------------===//

ZOZZ_API ZozzResult zozzFloat4TrackLoadFile(const char* path,
                                            ZozzFloat4Track** out);

ZOZZ_API ZozzResult zozzFloat4TrackLoadMemory(const void* data, size_t size,
                                              ZozzFloat4Track** out);

ZOZZ_API void zozzFloat4TrackDestroy(ZozzFloat4Track* track);

ZOZZ_API const char* zozzFloat4TrackName(const ZozzFloat4Track* track);

ZOZZ_API ZozzResult zozzFloat4TrackSample(const ZozzFloat4Track* track,
                                          float ratio, float out[4]);

/// See zozzFloatTrackNumKeyframes.
ZOZZ_API int zozzFloat4TrackNumKeyframes(const ZozzFloat4Track* track);

/// See zozzFloatTrackRatios.
ZOZZ_API ZozzResult zozzFloat4TrackRatios(const ZozzFloat4Track* track,
                                          float* out, size_t count);

/// See zozzFloatTrackValues. One row per keyframe.
ZOZZ_API ZozzResult zozzFloat4TrackValues(const ZozzFloat4Track* track,
                                          float out[][4], size_t count);

/// See zozzFloatTrackSteps.
ZOZZ_API ZozzResult zozzFloat4TrackSteps(const ZozzFloat4Track* track,
                                         ZozzTrackInterpolation* out,
                                         size_t count);

//===----------------------------------------------------------------------===//
// QuaternionTrack
//
// `out` is a quaternion in (x, y, z, w) order — w LAST, matching
// ZozzTransform.rotation and every other quaternion in this ABI. The same
// order applies to zozzQuaternionTrackValues' keyframe read-back below.
//===----------------------------------------------------------------------===//

ZOZZ_API ZozzResult zozzQuaternionTrackLoadFile(const char* path,
                                                ZozzQuaternionTrack** out);

ZOZZ_API ZozzResult zozzQuaternionTrackLoadMemory(const void* data,
                                                  size_t size,
                                                  ZozzQuaternionTrack** out);

ZOZZ_API void zozzQuaternionTrackDestroy(ZozzQuaternionTrack* track);

ZOZZ_API const char* zozzQuaternionTrackName(const ZozzQuaternionTrack* track);

ZOZZ_API ZozzResult zozzQuaternionTrackSample(const ZozzQuaternionTrack* track,
                                              float ratio, float out[4]);

/// See zozzFloatTrackNumKeyframes.
ZOZZ_API int zozzQuaternionTrackNumKeyframes(const ZozzQuaternionTrack* track);

/// See zozzFloatTrackRatios.
ZOZZ_API ZozzResult zozzQuaternionTrackRatios(const ZozzQuaternionTrack* track,
                                              float* out, size_t count);

/// See zozzFloatTrackValues. One row per keyframe.
ZOZZ_API ZozzResult zozzQuaternionTrackValues(const ZozzQuaternionTrack* track,
                                              float out[][4], size_t count);

/// See zozzFloatTrackSteps.
ZOZZ_API ZozzResult zozzQuaternionTrackSteps(const ZozzQuaternionTrack* track,
                                             ZozzTrackInterpolation* out,
                                             size_t count);

//===----------------------------------------------------------------------===//
// Track edge triggering
//
// Detects where a FloatTrack's value crosses a threshold over a [from, to]
// ratio range (FloatTrack only — a scalar threshold isn't meaningful for
// other value types). Evaluation is lazy: each edge is computed the first time
// the iterator reaches it.
//
// zozzFloatTrackTriggeringJobRun allocates the iterator through the installed
// allocator; it must be destroyed explicitly, like any other handle. It
// borrows `track`, which must stay alive and unchanged for as long as the
// iterator is used, including every Next call. Usage: Run to get an iterator,
// loop while Valid, Get each edge, Next to advance, then Destroy.
//===----------------------------------------------------------------------===//

typedef struct ZozzTrackTriggeringIterator ZozzTrackTriggeringIterator;

/// One detected threshold crossing.
typedef struct ZozzTrackEdge {
  /// Ratio at which the track value crossed the threshold.
  float ratio;
  /// True for a rising edge (value became greater than the threshold), false
  /// for a falling edge (value became less than or equal to the threshold).
  bool rising;
} ZozzTrackEdge;

/// Runs edge-triggering over [from, to] of `track` for `threshold`
/// crossings; any finite range/order works. `*out` is a new iterator at the
/// first edge on success, or past-end if `from == to` or none exists; step
/// with zozzTrackTriggeringIteratorNext. **Cyclic: the loop seam is an edge
/// too** — ratio 1 wraps to ratio 0, so a value still off-threshold at the
/// end fires one more edge, landing at `from`, not the end.
ZOZZ_API ZozzResult zozzFloatTrackTriggeringJobRun(
    const ZozzFloatTrack* track, float from, float to, float threshold,
    ZozzTrackTriggeringIterator** out);

ZOZZ_API void zozzTrackTriggeringIteratorDestroy(
    ZozzTrackTriggeringIterator* iterator);

/// True if `iterator` refers to a real edge (safe to pass to
/// zozzTrackTriggeringIteratorGet); false once the sequence is exhausted, or
/// if `iterator` is NULL.
ZOZZ_API bool zozzTrackTriggeringIteratorValid(
    const ZozzTrackTriggeringIterator* iterator);

/// Advances to the next edge. Returns ZOZZ_RESULT_INVALID_ARGUMENT, without
/// advancing, if `iterator` is NULL or already past the end — there is
/// nothing to advance to.
ZOZZ_API ZozzResult zozzTrackTriggeringIteratorNext(
    ZozzTrackTriggeringIterator* iterator);

/// Reads the edge `iterator` currently refers to. Returns
/// ZOZZ_RESULT_INVALID_ARGUMENT if `iterator` is NULL or past the end.
ZOZZ_API ZozzResult zozzTrackTriggeringIteratorGet(
    const ZozzTrackTriggeringIterator* iterator, ZozzTrackEdge* out);

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // ZOZZ_TRACK_H_
