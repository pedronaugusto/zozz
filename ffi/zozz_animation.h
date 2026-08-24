//===----------------------------------------------------------------------===//
// zozz — animation clip loading and queries.
//
// Conventions, ownership and thread safety are documented in zozz_core.h.
//===----------------------------------------------------------------------===//

#ifndef ZOZZ_ANIMATION_H_
#define ZOZZ_ANIMATION_H_

#include <stddef.h>

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

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // ZOZZ_ANIMATION_H_
