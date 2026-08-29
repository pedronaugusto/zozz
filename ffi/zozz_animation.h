//===----------------------------------------------------------------------===//
// zozz — animation clip loading and queries.
//
// Conventions, ownership and thread safety are documented in zozz_core.h.
//===----------------------------------------------------------------------===//

#ifndef ZOZZ_ANIMATION_H_
#define ZOZZ_ANIMATION_H_

#include <stddef.h>
#include <stdint.h>

#include "zozz.h"

#ifdef __cplusplus
extern "C" {
#endif

/// A compressed animation clip. Immutable once loaded.
typedef struct ZozzAnimation ZozzAnimation;

ZOZZ_API ZozzResult zozzAnimationLoadFile(const char* path,
                                          ZozzAnimation** out);

ZOZZ_API ZozzResult zozzAnimationLoadMemory(const void* data, size_t size,
                                            ZozzAnimation** out);

ZOZZ_API void zozzAnimationDestroy(ZozzAnimation* animation);

/// Duration in seconds. Always > 0 for a well-formed clip.
ZOZZ_API float zozzAnimationDuration(const ZozzAnimation* animation);

/// Number of animated joints. Must not exceed the skeleton's joint count.
ZOZZ_API int zozzAnimationNumTracks(const ZozzAnimation* animation);

/// Borrowed clip name; "" when unnamed, never NULL for a valid handle.
ZOZZ_API const char* zozzAnimationName(const ZozzAnimation* animation);

/// Number of SoA blocks matching the track count: (numTracks + 3) / 4.
ZOZZ_API int zozzAnimationNumSoaTracks(const ZozzAnimation* animation);

/// Estimated size of the clip's compressed keyframe data, in bytes.
ZOZZ_API size_t zozzAnimationSize(const ZozzAnimation* animation);

/// Number of distinct time points shared across the clip's keyframes.
ZOZZ_API int zozzAnimationNumTimepoints(const ZozzAnimation* animation);

/// Writes the clip's time points, in seconds and ascending order. `count`
/// must be at least zozzAnimationNumTimepoints, else
/// ZOZZ_RESULT_BUFFER_TOO_SMALL.
ZOZZ_API ZozzResult zozzAnimationTimepoints(const ZozzAnimation* animation,
                                           float* out, size_t count);

/// Which of the three compressed keyframe streams a control-stream query
/// refers to.
typedef enum ZozzKeyframeChannel {
  ZOZZ_KEYFRAME_CHANNEL_TRANSLATION = 0,
  ZOZZ_KEYFRAME_CHANNEL_ROTATION = 1,
  ZOZZ_KEYFRAME_CHANNEL_SCALE = 2,
} ZozzKeyframeChannel;

/// Element counts of one channel's control streams, for sizing the buffers the
/// four readers below fill.
typedef struct ZozzKeyframesCtrl {
  /// Indices into the clip's time points. One or two bytes per keyframe,
  /// whichever the time-point count needs -- ozz decides that per clip, and a
  /// reader has to derive it the same way from zozzAnimationNumTimepoints.
  size_t num_ratio_bytes;
  /// Offset from the previous keyframe of the same track, per keyframe.
  size_t num_previouses;
  /// Cached iframe entries, group-varint encoded.
  size_t num_iframe_entry_bytes;
  /// Two uint32 per iframe: offset into the entries, and the latest key index.
  size_t num_iframe_desc;
  /// Seconds between iframes, used to index the descriptors.
  float iframe_interval;
} ZozzKeyframesCtrl;

ZOZZ_API ZozzResult zozzAnimationKeyframesCtrl(const ZozzAnimation* animation,
                                               ZozzKeyframeChannel channel,
                                               ZozzKeyframesCtrl* out);

ZOZZ_API ZozzResult zozzAnimationKeyframeRatios(const ZozzAnimation* animation,
                                                ZozzKeyframeChannel channel,
                                                uint8_t* out, size_t count);

ZOZZ_API ZozzResult zozzAnimationKeyframePreviouses(
    const ZozzAnimation* animation, ZozzKeyframeChannel channel, uint16_t* out,
    size_t count);

ZOZZ_API ZozzResult zozzAnimationKeyframeIframeEntries(
    const ZozzAnimation* animation, ZozzKeyframeChannel channel, uint8_t* out,
    size_t count);

ZOZZ_API ZozzResult zozzAnimationKeyframeIframeDesc(
    const ZozzAnimation* animation, ZozzKeyframeChannel channel, uint32_t* out,
    size_t count);

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // ZOZZ_ANIMATION_H_
