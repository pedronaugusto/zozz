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
// it crosses this boundary as caller-owned storage stepped with
// `next` / `valid` / `get`.
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
// A built track stores its keyframes as three parallel, uncompressed arrays —
// ratio, value and interpolation mode, index-aligned — rather than the
// compressed streams behind a runtime Animation. Sampling above only produces
// an interpolated value at an arbitrary ratio; these read back what the track
// holds, the way a curve editor or a diff against another track needs.
//
// All three are BORROWED views of ozz's own storage — Track::ratios(),
// values() and steps() — valid while the track is alive. Each reports its
// count through `out_count`; a NULL track yields NULL and a count of 0.
// Documented in full for FloatTrack; the four others repeat the same shape.
//===----------------------------------------------------------------------===//

/// Number of keyframes `track` holds. 0 for an empty or NULL track.
ZOZZ_API int zozzFloatTrackNumKeyframes(const ZozzFloatTrack* track);

/// Each keyframe's ratio, ascending. `*out_count` is the keyframe count.
ZOZZ_API const float* zozzFloatTrackRatios(const ZozzFloatTrack* track,
                                           size_t* out_count);

/// Each keyframe's authored value, index-aligned with zozzFloatTrackRatios:
/// element i is the value AT keyframe i, not an interpolated sample.
/// `*out_count` is the keyframe count.
ZOZZ_API const float* zozzFloatTrackValues(const ZozzFloatTrack* track,
                                           size_t* out_count);

/// ozz's packed interpolation bitset: one BIT per keyframe, bit i of byte
/// i / 8, least-significant bit first. `*out_count` is the BYTE count, not
/// the keyframe count. zozzTrackInterpolations decodes it.
ZOZZ_API const uint8_t* zozzFloatTrackSteps(const ZozzFloatTrack* track,
                                            size_t* out_count);

/// Decodes any of the five tracks' steps bitset into one
/// ZozzTrackInterpolation per keyframe — the one place the bit order above is
/// read. `bytes` is what that track's Steps call reported, `num_keys` what
/// its NumKeyframes returned. ZOZZ_RESULT_BUFFER_TOO_SMALL if `count` is
/// under `num_keys`; ZOZZ_RESULT_INVALID_ARGUMENT, writing nothing, if
/// `bytes` cannot hold `num_keys` bits. `num_keys` 0 is a no-op.
ZOZZ_API ZozzResult zozzTrackInterpolations(const uint8_t* steps, size_t bytes,
                                            size_t num_keys,
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
ZOZZ_API const float* zozzFloat2TrackRatios(const ZozzFloat2Track* track,
                                            size_t* out_count);

/// See zozzFloatTrackValues. One row per keyframe.
ZOZZ_API const float (*zozzFloat2TrackValues(const ZozzFloat2Track* track,
                                             size_t* out_count))[2];

/// See zozzFloatTrackSteps.
ZOZZ_API const uint8_t* zozzFloat2TrackSteps(const ZozzFloat2Track* track,
                                             size_t* out_count);

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
ZOZZ_API const float* zozzFloat3TrackRatios(const ZozzFloat3Track* track,
                                            size_t* out_count);

/// See zozzFloatTrackValues. One row per keyframe.
ZOZZ_API const float (*zozzFloat3TrackValues(const ZozzFloat3Track* track,
                                             size_t* out_count))[3];

/// See zozzFloatTrackSteps.
ZOZZ_API const uint8_t* zozzFloat3TrackSteps(const ZozzFloat3Track* track,
                                             size_t* out_count);

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
ZOZZ_API const float* zozzFloat4TrackRatios(const ZozzFloat4Track* track,
                                            size_t* out_count);

/// See zozzFloatTrackValues. One row per keyframe.
ZOZZ_API const float (*zozzFloat4TrackValues(const ZozzFloat4Track* track,
                                             size_t* out_count))[4];

/// See zozzFloatTrackSteps.
ZOZZ_API const uint8_t* zozzFloat4TrackSteps(const ZozzFloat4Track* track,
                                             size_t* out_count);

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
ZOZZ_API const float* zozzQuaternionTrackRatios(
    const ZozzQuaternionTrack* track, size_t* out_count);

/// See zozzFloatTrackValues. One row per keyframe.
ZOZZ_API const float (*zozzQuaternionTrackValues(
    const ZozzQuaternionTrack* track, size_t* out_count))[4];

/// See zozzFloatTrackSteps.
ZOZZ_API const uint8_t* zozzQuaternionTrackSteps(
    const ZozzQuaternionTrack* track, size_t* out_count);

//===----------------------------------------------------------------------===//
// Track edge triggering
//
// Detects where a FloatTrack's value crosses a threshold over a [from, to]
// ratio range (FloatTrack only — a scalar threshold isn't meaningful for
// other value types). Evaluation is lazy: each edge is computed the first time
// the iterator reaches it.
//
// The iterator is CALLER-OWNED storage, as it is in ozz, where the job and its
// iterator are ordinary stack objects. Declare a ZozzTrackTriggeringIterator,
// hand its address to Run, loop while Valid, Get each edge, Next to advance.
// There is nothing to destroy. It borrows `track`, which must stay alive and
// unchanged for as long as the iterator is used, including every Next call.
//===----------------------------------------------------------------------===//

/// Bytes of caller storage one triggering session needs. ozz's job holds the
/// query and its iterator holds a pointer back to that job, so the two live
/// or die together and this is the size of both plus the two guard words
/// below. Deliberately a little larger than ozz 0.17.0 needs, because the
/// number is in a public header; the static_assert in zozz_abi.cpp is what
/// makes it correct, and zozzAbiLayout reports what was compiled.
#define ZOZZ_TRACK_TRIGGERING_ITERATOR_SIZE 96

/// One triggering session's storage. OPAQUE: read it only through the calls
/// below. It contains a pointer into ITSELF, so it must not be copied or moved
/// once Run has initialised it — every call checks the address it was
/// initialised at, along with a guard word, and answers
/// ZOZZ_RESULT_INVALID_ARGUMENT for storage that was moved or never run.
typedef struct ZOZZ_ALIGN16 ZozzTrackTriggeringIterator {
  unsigned char storage[ZOZZ_TRACK_TRIGGERING_ITERATOR_SIZE];
} ZozzTrackTriggeringIterator;

/// One detected threshold crossing.
typedef struct ZozzTrackEdge {
  /// Ratio at which the track value crossed the threshold.
  float ratio;
  /// True for a rising edge (value became greater than the threshold), false
  /// for a falling edge (value became less than or equal to the threshold).
  bool rising;
} ZozzTrackEdge;

/// Initialises `out` and positions it on the first edge of [from, to] of
/// `track` for `threshold` crossings; any finite range/order works. Past-end
/// if `from == to` or no edge exists; step with
/// zozzTrackTriggeringIteratorNext. **Cyclic: the loop seam is an edge too**
/// — ratio 1 wraps to ratio 0, so a value still off-threshold at the end
/// fires one more edge, landing at `from`, not the end.
ZOZZ_API ZozzResult zozzFloatTrackTriggeringJobRun(
    const ZozzFloatTrack* track, float from, float to, float threshold,
    ZozzTrackTriggeringIterator* out);

/// True if `iterator` refers to a real edge (safe to pass to
/// zozzTrackTriggeringIteratorGet); false once the sequence is exhausted, if
/// `iterator` is NULL, or if its storage was never run or has been moved.
ZOZZ_API bool zozzTrackTriggeringIteratorValid(
    const ZozzTrackTriggeringIterator* iterator);

/// Advances to the next edge. Returns ZOZZ_RESULT_INVALID_ARGUMENT, without
/// advancing, if `iterator` is NULL, was never run, has been moved, or is
/// already past the end — there is nothing to advance to.
ZOZZ_API ZozzResult zozzTrackTriggeringIteratorNext(
    ZozzTrackTriggeringIterator* iterator);

/// Reads the edge `iterator` currently refers to. Returns
/// ZOZZ_RESULT_INVALID_ARGUMENT if `iterator` is NULL, was never run, has
/// been moved, or is past the end.
ZOZZ_API ZozzResult zozzTrackTriggeringIteratorGet(
    const ZozzTrackTriggeringIterator* iterator, ZozzTrackEdge* out);

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // ZOZZ_TRACK_H_
