//===----------------------------------------------------------------------===//
// zozz — ozz's own allocation sites, driven with an allocation refused.
//
// Each scenario installs an ozz allocator that refuses the allocation it
// names, runs one ozz call, and reports whether ozz returned its failure (a
// null object, a false, an empty load) rather than writing through the null
// block: libs/patches/ozz-checked-allocation.patch's evidence. Only sites
// where no standard container allocates at the refused point are driven; a
// container has no failure path and stops the process (docs/design.md).
//
// Test-only. Not part of the zozz library or its ABI.
//===----------------------------------------------------------------------===//

#ifndef ZOZZ_TEST_ALLOCATION_H_
#define ZOZZ_TEST_ALLOCATION_H_

#ifdef __cplusplus
extern "C" {
#endif

/// What a scenario builds or loads: a skeleton, an animation, a float track.
typedef enum ZozzTestObject {
  ZOZZ_TEST_SKELETON = 0,
  ZOZZ_TEST_ANIMATION = 1,
  ZOZZ_TEST_FLOAT_TRACK = 2,
} ZozzTestObject;

/// Builds `object` with the allocation of the object itself refused (its
/// ozz::New, through make_unique). 1 when the builder returned null.
int zozzTestBuildRefusingNew(int object);

/// Builds `object` with its buffer refused: the builder's last allocation at
/// the alignment Allocate asks for. 1 when the builder returned null.
int zozzTestBuildRefusingBuffer(int object);

/// Loads a saved `object` with every allocation refused. 1 when the load
/// left the object empty.
int zozzTestLoadRefusingAll(int object);

/// Writes a suppressed log line with every allocation refused. 1 when it
/// returned.
int zozzTestLogRefusingAll(void);

/// Grows an ozz::io::MemoryStream that holds data, with the allocation
/// refused. 1 when the write reported nothing written and the data is kept.
int zozzTestStreamRefusingGrowth(void);

/// Builds a skeleton with no joints, refusing nothing: it allocates no
/// buffer, so a null one is not a failure. 1 when the builder returned it.
int zozzTestBuildEmptySkeleton(void);

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // ZOZZ_TEST_ALLOCATION_H_
