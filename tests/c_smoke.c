//===----------------------------------------------------------------------===//
// zozz — C-level smoke test.
//
// Proves the boundary in ffi/zozz.h stands on its own as a C contract: it
// compiles as C11, links without libc++ symbols leaking into the caller, and
// behaves correctly with a host allocator that knows nothing about Zig.
//
// Deliberately dependency-free — no test framework, no asset files.
//===----------------------------------------------------------------------===//

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "zozz.h"

static int failures = 0;

#define CHECK(cond)                                                     \
  do {                                                                  \
    if (!(cond)) {                                                      \
      fprintf(stderr, "%s:%d: FAIL %s\n", __FILE__, __LINE__, #cond);   \
      ++failures;                                                       \
    }                                                                   \
  } while (0)

//===----------------------------------------------------------------------===//
// A host allocator that counts, so the seam is proven to actually be in use
// rather than silently bypassed.
//===----------------------------------------------------------------------===//

typedef struct Counters {
  size_t allocations;
  size_t frees;
} Counters;

static void* count_allocate(void* user, size_t size, size_t alignment) {
  Counters* counters = (Counters*)user;
  ++counters->allocations;

  // Store the base pointer just before the aligned block so free() can
  // recover it. Mirrors what a real host with an aligned-alloc-less runtime
  // has to do.
  const size_t prefix = alignment > sizeof(void*) ? alignment : sizeof(void*);
  void* base = malloc(prefix + size);
  if (base == NULL) return NULL;

  char* payload = (char*)base + prefix;
  memcpy(payload - sizeof(void*), &base, sizeof(void*));
  return payload;
}

static void count_deallocate(void* user, void* block) {
  if (block == NULL) return;
  Counters* counters = (Counters*)user;
  ++counters->frees;

  void* base = NULL;
  memcpy(&base, (char*)block - sizeof(void*), sizeof(void*));
  free(base);
}

//===----------------------------------------------------------------------===//

static void test_version(void) {
  const uint32_t v = zozzVersion();
  CHECK(((v >> 16) & 0xFF) == ZOZZ_VERSION_MAJOR);
  CHECK(((v >> 8) & 0xFF) == ZOZZ_VERSION_MINOR);
  CHECK((v & 0xFF) == ZOZZ_VERSION_PATCH);
  CHECK(zozzOzzVersion() != 0);
}

static void test_result_names(void) {
  for (int i = 0; i <= (int)ZOZZ_RESULT_SKELETON_MISMATCH; ++i) {
    const char* name = zozzResultName((ZozzResult)i);
    CHECK(name != NULL);
    CHECK(strlen(name) > 0);
  }
}

static void test_abi_layout(void) {
  ZozzAbiLayout layout;
  memset(&layout, 0, sizeof(layout));
  zozzAbiLayout(&layout);

  CHECK(layout.layout_size == (uint32_t)sizeof(ZozzAbiLayout));
  CHECK(layout.transform_size == (uint32_t)sizeof(ZozzTransform));
  CHECK(layout.float4x4_size == (uint32_t)sizeof(ZozzFloat4x4));
  CHECK(layout.float4x4_align == 16);
  CHECK(layout.allocator_size == (uint32_t)sizeof(ZozzAllocator));
  CHECK(layout.result_count == (uint32_t)ZOZZ_RESULT_INVALID_DATA + 1u);
}

static void test_allocator_rejects_incomplete(void) {
  ZozzAllocator bad;
  bad.allocate = NULL;
  bad.deallocate = count_deallocate;
  bad.user = NULL;
  CHECK(zozzSetAllocator(&bad) == ZOZZ_RESULT_INVALID_ARGUMENT);
}

static void test_bad_input(void) {
  ZozzSkeleton* skeleton = (ZozzSkeleton*)0x1;
  const char garbage[64] = "not an ozz archive, not even close, honestly";

  CHECK(zozzSkeletonLoadMemory(garbage, sizeof(garbage), &skeleton) ==
        ZOZZ_RESULT_BAD_FORMAT);
  // The out-parameter must be cleared even on failure.
  CHECK(skeleton == NULL);

  CHECK(zozzSkeletonLoadMemory(NULL, 0, &skeleton) ==
        ZOZZ_RESULT_INVALID_ARGUMENT);
  CHECK(zozzSkeletonLoadFile("/nonexistent/zozz.ozz", &skeleton) ==
        ZOZZ_RESULT_FILE_NOT_FOUND);
  CHECK(zozzSkeletonLoadFile(NULL, &skeleton) == ZOZZ_RESULT_INVALID_ARGUMENT);

  ZozzAnimation* animation = (ZozzAnimation*)0x1;
  CHECK(zozzAnimationLoadMemory(garbage, sizeof(garbage), &animation) ==
        ZOZZ_RESULT_BAD_FORMAT);
  CHECK(animation == NULL);

  // Destroying NULL is defined and must not crash.
  zozzSkeletonDestroy(NULL);
  zozzAnimationDestroy(NULL);
  zozzSoaPoseDestroy(NULL);
  zozzSamplingContextDestroy(NULL);
  zozzSamplingContextInvalidate(NULL);
}

static void test_pose_round_trip(void) {
  ZozzSoaPose* pose = NULL;
  CHECK(zozzSoaPoseCreate(5, &pose) == ZOZZ_RESULT_OK);
  CHECK(pose != NULL);
  if (pose == NULL) return;

  CHECK(zozzSoaPoseNumJoints(pose) == 5);

  ZozzTransform written[5];
  for (int i = 0; i < 5; ++i) {
    const float f = (float)(i + 1);
    written[i].translation[0] = f;
    written[i].translation[1] = -f;
    written[i].translation[2] = f * 0.5f;
    written[i].rotation[0] = 0.f;
    written[i].rotation[1] = 0.f;
    written[i].rotation[2] = 0.f;
    written[i].rotation[3] = 1.f;
    written[i].scale[0] = f;
    written[i].scale[1] = f;
    written[i].scale[2] = f;
  }

  CHECK(zozzSoaPoseFromLocalTransforms(pose, written, 5) == ZOZZ_RESULT_OK);

  ZozzTransform read_back[5];
  memset(read_back, 0, sizeof(read_back));
  CHECK(zozzSoaPoseToLocalTransforms(pose, read_back, 5) == ZOZZ_RESULT_OK);

  for (int i = 0; i < 5; ++i) {
    for (int k = 0; k < 3; ++k) {
      CHECK(read_back[i].translation[k] == written[i].translation[k]);
      CHECK(read_back[i].scale[k] == written[i].scale[k]);
    }
    CHECK(read_back[i].rotation[3] == 1.f);
  }

  // Undersized buffers are refused, not truncated.
  CHECK(zozzSoaPoseToLocalTransforms(pose, read_back, 2) ==
        ZOZZ_RESULT_BUFFER_TOO_SMALL);

  zozzSoaPoseDestroy(pose);
}

static void test_sampling_context(void) {
  ZozzSamplingContext* context = NULL;
  CHECK(zozzSamplingContextCreate(20, &context) == ZOZZ_RESULT_OK);
  CHECK(context != NULL);
  CHECK(zozzSamplingContextMaxTracks(context) >= 20);
  zozzSamplingContextInvalidate(context);
  zozzSamplingContextDestroy(context);

  CHECK(zozzSamplingContextCreate(0, &context) == ZOZZ_RESULT_INVALID_ARGUMENT);
  CHECK(zozzSamplingContextCreate(-1, &context) == ZOZZ_RESULT_INVALID_ARGUMENT);
}

int main(void) {
  Counters counters = {0, 0};
  ZozzAllocator allocator;
  allocator.allocate = count_allocate;
  allocator.deallocate = count_deallocate;
  allocator.user = &counters;

  test_version();
  test_result_names();
  test_abi_layout();
  test_allocator_rejects_incomplete();

  CHECK(zozzSetAllocator(&allocator) == ZOZZ_RESULT_OK);

  test_bad_input();
  test_pose_round_trip();
  test_sampling_context();

  // The seam must actually have been used, and everything taken must have
  // been given back.
  CHECK(counters.allocations > 0);
  CHECK(counters.allocations == counters.frees);

  CHECK(zozzSetAllocator(NULL) == ZOZZ_RESULT_OK);

  if (failures != 0) {
    fprintf(stderr, "zozz c smoke: %d check(s) failed\n", failures);
    return 1;
  }
  printf("zozz c smoke: ok (%zu allocations balanced)\n", counters.allocations);
  return 0;
}
