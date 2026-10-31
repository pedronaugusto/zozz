//===----------------------------------------------------------------------===//
// zozz — a refused load into an ozz object that held something.
//
// Load starts by freeing what the object held, and a load that refuses
// partway frees what it read: either way the object must report nothing,
// not sizes over freed memory. zozz always loads into a new object, so only
// ozz's own API reaches this: libs/patches/ozz-archive-invariants.patch's
// evidence that a refusal leaves the object empty.
//
// Test-only. Not part of the zozz library or its ABI.
//===----------------------------------------------------------------------===//

#ifndef ZOZZ_TEST_RELOAD_H_
#define ZOZZ_TEST_RELOAD_H_

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Loads the archive `held` into a new `object` (a ZozzTestObject), then
/// `refused` into the same one. The object's size after (joints, timepoints or
/// keys), or -1 when `held` did not load or `refused` was not refused.
long zozzTestReloadRefused(int object, const void* held, size_t held_size,
                           const void* refused, size_t refused_size);

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // ZOZZ_TEST_RELOAD_H_
