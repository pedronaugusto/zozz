//===----------------------------------------------------------------------===//
// zozz — runtime user tracks.
//
// A track is a keyframed curve over a single value (float, a 2/3/4-component
// vector, or a quaternion), independent of the skeletal animation pipeline —
// the shape ozz uses for game-authored signals like "footstep intensity" or
// "look-at weight" that ride alongside a clip but are not a joint transform.
// ozz templates the runtime type over five value types; this header declares
// one concrete set of entry points per type; there is no generic "Track"
// handle.
//
// Edge triggering (below) detects where a FloatTrack crosses a threshold and
// is the one piece here that is not a plain call: ozz's own iterator is a
// stateful C++ object with a private constructor, so it crosses this
// boundary as an opaque, explicitly-destroyed handle stepped with `next` /
// `valid` / `get` rather than as a value.
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

//===----------------------------------------------------------------------===//
// QuaternionTrack
//
// `out` is a quaternion in (x, y, z, w) order — w LAST, matching
// ZozzTransform.rotation and every other quaternion in this ABI.
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

//===----------------------------------------------------------------------===//
// Track edge triggering
//
// Detects where a FloatTrack's value crosses a threshold over a [from, to]
// ratio range (only FloatTrack is supported — comparing other value types to
// a scalar threshold isn't meaningful). Evaluation is lazy: each edge is
// computed the first time the iterator reaches it.
//
// zozzFloatTrackTriggeringJobRun allocates the iterator through the installed
// allocator; it is a handle like any other and must be destroyed explicitly.
// It borrows `track` — `track` must stay alive and unchanged for as long as
// the iterator is used, including every call to
// zozzTrackTriggeringIteratorNext.
//
// Usage:
//   ZozzTrackTriggeringIterator* it;
//   ZozzResult result =
//       zozzFloatTrackTriggeringJobRun(track, 0.f, 1.f, 0.5f, &it);
//   if (result == ZOZZ_RESULT_OK) {
//     while (zozzTrackTriggeringIteratorValid(it)) {
//       ZozzTrackEdge edge;
//       zozzTrackTriggeringIteratorGet(it, &edge);
//       // ... use edge ...
//       zozzTrackTriggeringIteratorNext(it);
//     }
//     zozzTrackTriggeringIteratorDestroy(it);
//   }
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

/// Runs edge-triggering over the ratio range [from, to] of `track`, detecting
/// crossings of `threshold`. `from`, `to` and `threshold` may be any finite
/// values, in any order and any range; see TrackTriggeringJob in ozz for the
/// looping/reversal rules that follow from that. On success, `*out` is a new
/// iterator already positioned at the first edge (or already past the end if
/// `from == to` or no edge exists) — step it with
/// zozzTrackTriggeringIteratorNext.
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
