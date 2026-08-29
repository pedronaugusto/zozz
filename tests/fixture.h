//===----------------------------------------------------------------------===//
// zozz — synthetic test assets.
//
// The package ships no .ozz files. Instead, the tests build a small skeleton
// and clip through ozz's own offline builders and serialise them in memory, so
// the suite is self-contained, carries no third-party asset provenance, and is
// always version-matched to the vendored runtime.
//
// It also earns a second keep: exercising the offline builders proves they
// compile and link here, which is the foundation any future glTF -> .ozz cook
// will stand on.
//
// Test-only. Not part of the zozz library or its ABI.
//===----------------------------------------------------------------------===//

#ifndef ZOZZ_TEST_FIXTURE_H_
#define ZOZZ_TEST_FIXTURE_H_

#include <stddef.h>

#include "zozz.h"

#ifdef __cplusplus
extern "C" {
#endif

/// Joints in the synthetic skeleton: root -> spine -> {arm_l, arm_r}.
#define ZOZZ_FIXTURE_JOINTS 4

/// Duration of the synthetic clip, in seconds.
#define ZOZZ_FIXTURE_DURATION 1.0f

/// Serialises a synthetic skeleton as a .ozz archive image.
/// Free the result with zozzFixtureFree.
ZozzResult zozzFixtureSkeleton(void** out_data, size_t* out_size);

/// Serialises a synthetic clip animating all ZOZZ_FIXTURE_JOINTS joints.
/// The root joint translates along +X over the clip, so a sample at ratio 0
/// and one at ratio 1 are guaranteed to differ.
ZozzResult zozzFixtureAnimation(void** out_data, size_t* out_size);

void zozzFixtureFree(void* data);

/// Calls zozzSkeletonLoadMemory(data, size, ...) with ozz's std::cerr
/// redirected into an in-memory buffer for exactly that one call, then
/// restores it and destroys whatever handle the load produced (if any) --
/// a test on this path never wants to keep the result, only to see whether
/// ozz wrote anything to its log while producing it.
///
/// This exists only because ozz::log::Err()/Out() hand back a std::ostream,
/// which cannot cross the C boundary (see zozz_core.h's "Log verbosity"), so
/// a Zig test has no other way to observe whether zozzSetLogLevel actually
/// changed what ozz's runtime writes.
///
/// Returns the number of bytes ozz wrote to std::cerr during the call.
size_t zozzFixtureCapturedSkeletonLoadBytes(const void* data, size_t size);

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // ZOZZ_TEST_FIXTURE_H_
