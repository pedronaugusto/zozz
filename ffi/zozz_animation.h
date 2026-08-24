//===----------------------------------------------------------------------===//
// zozz — animation clips: compressed, sampleable keyframe data.
//
// Conventions, ownership and thread safety are documented in zozz_core.h.
//===----------------------------------------------------------------------===//

#ifndef ZOZZ_ANIMATION_H_
#define ZOZZ_ANIMATION_H_

#include <stddef.h>

#include "zozz_core.h"

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

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // ZOZZ_ANIMATION_H_
