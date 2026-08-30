//===----------------------------------------------------------------------===//
// zozz — C-level smoke test.
//
// Proves the boundary in ffi/zozz.h stands on its own as a C contract: it
// compiles as C11, links without libc++ symbols leaking into the caller, and
// behaves correctly with a host allocator that knows nothing about Zig.
//
// Deliberately dependency-free — no test framework, no asset files.
//===----------------------------------------------------------------------===//

#include <math.h>
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
// A host-provided in-memory stream implementing every ZozzStream callback,
// so the same buffer can back a write archive and, once rewound, a read one
// — proving the archive round trip with no Zig in the picture.
//===----------------------------------------------------------------------===//

typedef struct MemStream {
  unsigned char* data;
  size_t size;
  size_t capacity;
  size_t pos;
} MemStream;

static int mem_opened(void* user) {
  (void)user;
  return 1;
}

static size_t mem_write(void* user, const void* src, size_t size) {
  MemStream* m = (MemStream*)user;
  if (m->pos + size > m->capacity) {
    size_t new_cap = m->capacity == 0 ? 256 : m->capacity * 2;
    while (new_cap < m->pos + size) new_cap *= 2;
    unsigned char* grown = (unsigned char*)realloc(m->data, new_cap);
    if (grown == NULL) return 0;
    m->data = grown;
    m->capacity = new_cap;
  }
  memcpy(m->data + m->pos, src, size);
  m->pos += size;
  if (m->pos > m->size) m->size = m->pos;
  return size;
}

static size_t mem_read(void* user, void* dst, size_t size) {
  MemStream* m = (MemStream*)user;
  const size_t available = m->pos < m->size ? m->size - m->pos : 0;
  const size_t n = size < available ? size : available;
  if (n != 0) memcpy(dst, m->data + m->pos, n);
  m->pos += n;
  return n;
}

static int mem_seek(void* user, int offset, ZozzSeekOrigin origin) {
  MemStream* m = (MemStream*)user;
  long base;
  switch (origin) {
    case ZOZZ_SEEK_ORIGIN_CURRENT:
      base = (long)m->pos;
      break;
    case ZOZZ_SEEK_ORIGIN_END:
      base = (long)m->size;
      break;
    case ZOZZ_SEEK_ORIGIN_SET:
      base = 0;
      break;
    default:
      return -1;
  }
  const long target = base + offset;
  if (target < 0 || (size_t)target > m->size) return -1;
  m->pos = (size_t)target;
  return 0;
}

static int mem_tell(void* user) {
  MemStream* m = (MemStream*)user;
  return (int)m->pos;
}

static void mem_stream_free(MemStream* m) {
  free(m->data);
  memset(m, 0, sizeof(*m));
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
  // Bounded by what the library reports, not by an enumerator spelled here: a
  // hand-written bound stops at whichever result was last when it was
  // written, and this one had stopped four results short.
  ZozzAbiLayout layout;
  zozzAbiLayout(&layout);
  CHECK(layout.result_count > 0);
  for (uint32_t i = 0; i < layout.result_count; ++i) {
    const char* name = zozzResultName((ZozzResult)i);
    CHECK(name != NULL);
    CHECK(strlen(name) > 0);
    CHECK(strcmp(name, "unknown result") != 0);
  }
  CHECK(strcmp(zozzResultName((ZozzResult)layout.result_count),
               "unknown result") == 0);
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
  CHECK(layout.result_count == (uint32_t)ZOZZ_RESULT_ALLOCATOR_IN_USE + 1u);
}

static void test_build_features(void) {
  ZozzBuildFeatures features;
  memset(&features, 0xAB, sizeof(features));
  zozzBuildFeatures(&features);
  CHECK(features.features_size == (uint32_t)sizeof(ZozzBuildFeatures));

  // Each flag must agree with the entry point behind it: a feature reported
  // present whose call answers UNSUPPORTED is the exact lie this query exists
  // to make impossible.
  ZozzImporter* importer = NULL;
  const ZozzResult gltf_result =
      zozzGltfImporterCreate("does-not-exist.gltf", &importer);
  if (features.gltf) {
    CHECK(gltf_result != ZOZZ_RESULT_UNSUPPORTED);
  } else {
    CHECK(gltf_result == ZOZZ_RESULT_UNSUPPORTED);
  }
  if (importer != NULL) zozzImporterDestroy(importer);

  ZozzOptionsParser* parser = NULL;
  const ZozzResult options_result = zozzOptionsParserCreate(&parser);
  if (features.options) {
    CHECK(options_result == ZOZZ_RESULT_OK);
  } else {
    CHECK(options_result == ZOZZ_RESULT_UNSUPPORTED);
  }
  if (parser != NULL) zozzOptionsParserDestroy(parser);
}

static void test_allocator_rejects_incomplete(void) {
  ZozzAllocator bad;
  bad.allocate = NULL;
  bad.deallocate = count_deallocate;
  bad.user = NULL;
  CHECK(zozzSetAllocator(&bad) == ZOZZ_RESULT_INVALID_ARGUMENT);
}

/// Run both before any allocator has ever been installed and again after
/// zozzSetAllocator(NULL) has restored ozz's own -- both must report the
/// same "not installed" state, not merely the first one.
static void test_allocator_getter_reports_not_installed(void) {
  ZozzAllocator out;
  memset(&out, 0xAB, sizeof(out));  // poisoned, so a stray write would show.
  bool installed = true;
  CHECK(zozzGetAllocator(&out, &installed) == ZOZZ_RESULT_OK);
  CHECK(!installed);

  CHECK(zozzGetAllocator(NULL, &installed) == ZOZZ_RESULT_INVALID_ARGUMENT);
  CHECK(zozzGetAllocator(&out, NULL) == ZOZZ_RESULT_INVALID_ARGUMENT);
}

static void test_allocator_getter_reports_the_installed_allocator(
    const ZozzAllocator* installed_allocator) {
  ZozzAllocator got;
  bool installed = false;
  CHECK(zozzGetAllocator(&got, &installed) == ZOZZ_RESULT_OK);
  CHECK(installed);
  CHECK(got.allocate == installed_allocator->allocate);
  CHECK(got.deallocate == installed_allocator->deallocate);
  CHECK(got.user == installed_allocator->user);
}

static void test_log_level(void) {
  CHECK(zozzGetLogLevel() == ZOZZ_LOG_LEVEL_STANDARD);

  CHECK(zozzSetLogLevel(ZOZZ_LOG_LEVEL_SILENT) == ZOZZ_RESULT_OK);
  CHECK(zozzGetLogLevel() == ZOZZ_LOG_LEVEL_SILENT);

  CHECK(zozzSetLogLevel(ZOZZ_LOG_LEVEL_VERBOSE) == ZOZZ_RESULT_OK);
  CHECK(zozzGetLogLevel() == ZOZZ_LOG_LEVEL_VERBOSE);

  // Rejected out-of-range, leaving the level exactly where it was.
  CHECK(zozzSetLogLevel((ZozzLogLevel)99) == ZOZZ_RESULT_INVALID_ARGUMENT);
  CHECK(zozzGetLogLevel() == ZOZZ_LOG_LEVEL_VERBOSE);

  CHECK(zozzSetLogLevel(ZOZZ_LOG_LEVEL_STANDARD) == ZOZZ_RESULT_OK);
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
  zozzSamplingContextDestroy(NULL);
  zozzSamplingContextInvalidate(NULL);
}

static void test_pose_round_trip(void) {
  // Five joints occupy two SoA blocks, the second one partial.
  const size_t blocks = zozzSoaBlocks(5);
  CHECK(blocks == 2);
  CHECK(zozzSoaBlocks(0) == 0);
  CHECK(zozzSoaBlocks(ZOZZ_MAX_JOINTS + 1) == 0);

  ZozzSoaTransform pose[2];
  CHECK(zozzSoaPoseSetIdentity(pose, blocks) == ZOZZ_RESULT_OK);

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

  CHECK(zozzSoaPoseFromLocalTransforms(written, 5, pose, blocks) ==
        ZOZZ_RESULT_OK);

  ZozzTransform read_back[5];
  memset(read_back, 0, sizeof(read_back));
  CHECK(zozzSoaPoseToLocalTransforms(pose, blocks, read_back, 5) ==
        ZOZZ_RESULT_OK);

  for (int i = 0; i < 5; ++i) {
    for (int k = 0; k < 3; ++k) {
      CHECK(read_back[i].translation[k] == written[i].translation[k]);
      CHECK(read_back[i].scale[k] == written[i].scale[k]);
    }
    CHECK(read_back[i].rotation[3] == 1.f);
  }

  // A span too short for the joint count is refused, not truncated.
  CHECK(zozzSoaPoseToLocalTransforms(pose, 1, read_back, 5) ==
        ZOZZ_RESULT_BUFFER_TOO_SMALL);
  CHECK(zozzSoaPoseFromLocalTransforms(written, 5, pose, 1) ==
        ZOZZ_RESULT_BUFFER_TOO_SMALL);

  // Caller-owned memory means a caller can hand over a misaligned pointer,
  // which ozz would read with an aligned SIMD load. `slack` is oversized so
  // the offset span stays in bounds whatever the entry point does with it.
  ZozzSoaTransform slack[3];
  ZozzSoaTransform* misaligned = (ZozzSoaTransform*)((char*)slack + 4);
  CHECK(zozzSoaPoseSetIdentity(misaligned, 1) == ZOZZ_RESULT_INVALID_ARGUMENT);
  CHECK(zozzSoaPoseToLocalTransforms(misaligned, 1, read_back, 4) ==
        ZOZZ_RESULT_INVALID_ARGUMENT);
  CHECK(zozzSoaPoseFromLocalTransforms(written, 4, misaligned, 1) ==
        ZOZZ_RESULT_INVALID_ARGUMENT);
}

static void test_joint_weight_packing(void) {
  const float weights[5] = {0.f, 0.25f, 0.5f, 0.75f, 1.f};
  ZozzSimdFloat4 packed[2];
  CHECK(zozzSoaWeightsPack(weights, 5, packed, 2) == ZOZZ_RESULT_OK);
  for (int i = 0; i < 5; ++i) {
    CHECK(packed[i / 4].f[i % 4] == weights[i]);
  }
  // The lanes past the joint count mean "fully weighted", not zero.
  for (int lane = 1; lane < 4; ++lane) {
    CHECK(packed[1].f[lane] == 1.f);
  }

  CHECK(zozzSoaWeightsPack(weights, 5, packed, 1) ==
        ZOZZ_RESULT_BUFFER_TOO_SMALL);
  CHECK(zozzSoaWeightsPack(NULL, 5, packed, 2) == ZOZZ_RESULT_INVALID_ARGUMENT);
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

static void test_track_triggering_on_the_stack(void) {
  // A square wave: low, high, low, high over each quarter, step interpolated
  // so each transition sits exactly on a keyframe ratio.
  ZozzRawFloatTrack* raw = NULL;
  CHECK(zozzRawFloatTrackCreate(&raw) == ZOZZ_RESULT_OK);
  if (raw == NULL) return;
  const float values[4] = {0.f, 1.f, 0.f, 1.f};
  for (int i = 0; i < 4; ++i) {
    CHECK(zozzRawFloatTrackPushKeyframe(raw, ZOZZ_TRACK_INTERPOLATION_STEP,
                                        (float)i * 0.25f,
                                        values[i]) == ZOZZ_RESULT_OK);
  }

  ZozzFloatTrack* track = NULL;
  CHECK(zozzFloatTrackBuild(raw, &track) == ZOZZ_RESULT_OK);
  zozzRawFloatTrackDestroy(raw);
  if (track == NULL) return;

  // The whole point of the caller-owned shape: this is a stack object in a C
  // translation unit, sized by the header, and nothing is ever destroyed.
  ZozzTrackTriggeringIterator iterator;
  CHECK(zozzFloatTrackTriggeringJobRun(track, 0.f, 1.f, 0.5f, &iterator) ==
        ZOZZ_RESULT_OK);

  int edges = 0;
  while (zozzTrackTriggeringIteratorValid(&iterator)) {
    ZozzTrackEdge edge;
    CHECK(zozzTrackTriggeringIteratorGet(&iterator, &edge) == ZOZZ_RESULT_OK);
    ++edges;
    CHECK(zozzTrackTriggeringIteratorNext(&iterator) == ZOZZ_RESULT_OK);
  }
  // Four, not three: a track is cyclic, so the seam at ratio 1 -> 0 is an
  // edge too. Past the end is an error rather than an assert inside ozz.
  CHECK(edges == 4);
  CHECK(zozzTrackTriggeringIteratorNext(&iterator) ==
        ZOZZ_RESULT_INVALID_ARGUMENT);

  // Storage that was never run, and a byte-for-byte copy of a live session,
  // are both refused: each carries the wrong guard word or the wrong address.
  ZozzTrackTriggeringIterator never_run;
  memset(&never_run, 0, sizeof(never_run));
  CHECK(!zozzTrackTriggeringIteratorValid(&never_run));
  CHECK(zozzTrackTriggeringIteratorNext(&never_run) ==
        ZOZZ_RESULT_INVALID_ARGUMENT);

  CHECK(zozzFloatTrackTriggeringJobRun(track, 0.f, 1.f, 0.5f, &iterator) ==
        ZOZZ_RESULT_OK);
  ZozzTrackTriggeringIterator moved = iterator;
  CHECK(!zozzTrackTriggeringIteratorValid(&moved));
  CHECK(zozzTrackTriggeringIteratorValid(&iterator));

  zozzFloatTrackDestroy(track);
}

static void test_track_keyframe_views(void) {
  // 12 keys spans two bytes of the steps bitset, so a bit-order mistake shows
  // up past index 7 rather than passing on a single byte.
  ZozzRawFloat3Track* raw = NULL;
  CHECK(zozzRawFloat3TrackCreate(&raw) == ZOZZ_RESULT_OK);
  if (raw == NULL) return;
  const int keys = 12;
  for (int i = 0; i < keys; ++i) {
    const float ratio = (float)i / (float)(keys - 1);
    const float value[3] = {(float)i, (float)-i, 0.5f};
    CHECK(zozzRawFloat3TrackPushKeyframe(
              raw,
              (i % 2 == 0) ? ZOZZ_TRACK_INTERPOLATION_STEP
                           : ZOZZ_TRACK_INTERPOLATION_LINEAR,
              ratio, value) == ZOZZ_RESULT_OK);
  }

  ZozzFloat3Track* track = NULL;
  CHECK(zozzFloat3TrackBuild(raw, &track) == ZOZZ_RESULT_OK);
  zozzRawFloat3TrackDestroy(raw);
  if (track == NULL) return;

  CHECK(zozzFloat3TrackNumKeyframes(track) == keys);

  size_t num_ratios = 0;
  const float* ratios = zozzFloat3TrackRatios(track, &num_ratios);
  size_t num_values = 0;
  const float(*values)[3] = zozzFloat3TrackValues(track, &num_values);
  CHECK(ratios != NULL && num_ratios == (size_t)keys);
  CHECK(values != NULL && num_values == (size_t)keys);

  // Borrowed views of ozz's own arrays: asking twice gives the same address.
  CHECK(zozzFloat3TrackRatios(track, &num_ratios) == ratios);
  CHECK(zozzFloat3TrackValues(track, &num_values) == values);

  for (int i = 0; i < keys; ++i) {
    CHECK(fabsf(ratios[i] - (float)i / (float)(keys - 1)) < 1e-6f);
    CHECK(values[i][0] == (float)i);
    CHECK(values[i][1] == (float)-i);
  }

  size_t step_bytes = 0;
  const uint8_t* steps = zozzFloat3TrackSteps(track, &step_bytes);
  CHECK(steps != NULL && step_bytes == 2);

  ZozzTrackInterpolation modes[12];
  CHECK(zozzTrackInterpolations(steps, step_bytes, (size_t)keys, modes,
                                sizeof(modes) / sizeof(modes[0])) ==
        ZOZZ_RESULT_OK);
  for (int i = 0; i < keys; ++i) {
    CHECK(modes[i] == ((i % 2 == 0) ? ZOZZ_TRACK_INTERPOLATION_STEP
                                    : ZOZZ_TRACK_INTERPOLATION_LINEAR));
  }

  // A short output buffer is refused; a bitset too small for the key count is
  // refused before it is indexed.
  CHECK(zozzTrackInterpolations(steps, step_bytes, (size_t)keys, modes,
                                (size_t)keys - 1) ==
        ZOZZ_RESULT_BUFFER_TOO_SMALL);
  CHECK(zozzTrackInterpolations(steps, 1, (size_t)keys, modes,
                                sizeof(modes) / sizeof(modes[0])) ==
        ZOZZ_RESULT_INVALID_ARGUMENT);

  // A NULL track answers with an empty view rather than a count nobody set.
  size_t none = 123;
  CHECK(zozzFloat3TrackRatios(NULL, &none) == NULL && none == 0);
  none = 123;
  CHECK(zozzFloat3TrackValues(NULL, &none) == NULL && none == 0);
  none = 123;
  CHECK(zozzFloat3TrackSteps(NULL, &none) == NULL && none == 0);

  zozzFloat3TrackDestroy(track);
}

static void test_archive_round_trip(void) {
  MemStream mem;
  memset(&mem, 0, sizeof(mem));

  ZozzTransform rest;
  memset(&rest, 0, sizeof(rest));
  rest.rotation[3] = 1.f;
  rest.scale[0] = rest.scale[1] = rest.scale[2] = 1.f;

  ZozzRawSkeleton* raw_skeleton = NULL;
  CHECK(zozzRawSkeletonCreate(&raw_skeleton) == ZOZZ_RESULT_OK);
  int32_t root_index = -1;
  CHECK(zozzRawSkeletonAddJoint(raw_skeleton, ZOZZ_NO_PARENT, "root", &rest,
                                &root_index) == ZOZZ_RESULT_OK);
  CHECK(zozzRawSkeletonAddJoint(raw_skeleton, root_index, "child", &rest,
                                NULL) == ZOZZ_RESULT_OK);

  ZozzSkeleton* skeleton = NULL;
  CHECK(zozzSkeletonBuild(raw_skeleton, &skeleton) == ZOZZ_RESULT_OK);
  zozzRawSkeletonDestroy(raw_skeleton);
  CHECK(skeleton != NULL);
  if (skeleton == NULL) return;

  ZozzRawAnimation* raw_animation = NULL;
  CHECK(zozzRawAnimationCreate(2, 1.0f, "smoke", &raw_animation) ==
        ZOZZ_RESULT_OK);
  for (int track = 0; track < 2; ++track) {
    const float t0[3] = {0.f, 0.f, 0.f};
    const float t1[3] = {(float)track + 1.f, 0.f, 0.f};
    const float r0[4] = {0.f, 0.f, 0.f, 1.f};
    const float s0[3] = {1.f, 1.f, 1.f};
    CHECK(zozzRawAnimationPushTranslation(raw_animation, track, 0.0f, t0) ==
          ZOZZ_RESULT_OK);
    CHECK(zozzRawAnimationPushTranslation(raw_animation, track, 1.0f, t1) ==
          ZOZZ_RESULT_OK);
    CHECK(zozzRawAnimationPushRotation(raw_animation, track, 0.0f, r0) ==
          ZOZZ_RESULT_OK);
    CHECK(zozzRawAnimationPushScale(raw_animation, track, 0.0f, s0) ==
          ZOZZ_RESULT_OK);
  }

  ZozzAnimation* animation = NULL;
  CHECK(zozzAnimationBuild(raw_animation, &animation) == ZOZZ_RESULT_OK);
  zozzRawAnimationDestroy(raw_animation);
  CHECK(animation != NULL);
  if (animation == NULL) {
    zozzSkeletonDestroy(skeleton);
    return;
  }

  // Write both into one archive over the host-provided stream.
  ZozzStream write_stream;
  write_stream.opened = mem_opened;
  write_stream.write = mem_write;
  write_stream.read = NULL;
  write_stream.seek = NULL;
  write_stream.tell = NULL;
  write_stream.user = &mem;

  // Deliberately the endianness every CI runner in this project is NOT
  // native in (all are little-endian): proves the swap path round-trips
  // through the plain C header, not only through the Zig wrapper's own
  // dedicated endianness test.
  ZozzOArchive* out_archive = NULL;
  CHECK(zozzOArchiveCreate(&write_stream, ZOZZ_ENDIANNESS_BIG, &out_archive) ==
        ZOZZ_RESULT_OK);
  CHECK(zozzOArchiveSaveSkeleton(out_archive, skeleton) == ZOZZ_RESULT_OK);
  CHECK(zozzOArchiveSaveAnimation(out_archive, animation) == ZOZZ_RESULT_OK);
  zozzOArchiveDestroy(out_archive);

  // Read both back through a read-only view of the same buffer, rewound.
  mem.pos = 0;
  ZozzStream read_stream;
  read_stream.opened = mem_opened;
  read_stream.write = NULL;
  read_stream.read = mem_read;
  read_stream.seek = mem_seek;
  read_stream.tell = mem_tell;
  read_stream.user = &mem;

  ZozzIArchive* in_archive = NULL;
  CHECK(zozzIArchiveCreate(&read_stream, &in_archive) == ZOZZ_RESULT_OK);
  CHECK(in_archive != NULL);
  if (in_archive != NULL) {
    // A wrong guess must not consume the object: the right one still works.
    CHECK(!zozzIArchiveTestAnimation(in_archive));
    CHECK(zozzIArchiveTestSkeleton(in_archive));

    ZozzSkeleton* loaded_skeleton = NULL;
    CHECK(zozzIArchiveLoadSkeleton(in_archive, &loaded_skeleton) ==
          ZOZZ_RESULT_OK);
    CHECK(loaded_skeleton != NULL);
    if (loaded_skeleton != NULL) {
      CHECK(zozzSkeletonNumJoints(loaded_skeleton) ==
            zozzSkeletonNumJoints(skeleton));
      CHECK(strcmp(zozzSkeletonJointName(loaded_skeleton, 1),
                   zozzSkeletonJointName(skeleton, 1)) == 0);

      // The bulk views are ozz's own arrays: same answers as the per-joint
      // accessors, one crossing instead of one per joint, and borrowed.
      size_t parent_count = 0;
      const int16_t* parents =
          zozzSkeletonJointParents(loaded_skeleton, &parent_count);
      CHECK(parent_count == (size_t)zozzSkeletonNumJoints(loaded_skeleton));
      CHECK(parents != NULL && parents[0] == ZOZZ_NO_PARENT);
      CHECK(parents[1] == zozzSkeletonJointParent(loaded_skeleton, 1));

      size_t name_count = 0;
      const char* const* names =
          zozzSkeletonJointNames(loaded_skeleton, &name_count);
      CHECK(name_count == parent_count);
      CHECK(names != NULL && strcmp(names[1], "child") == 0);

      size_t block_count = 0;
      const ZozzSoaTransform* rest =
          zozzSkeletonJointRestPoses(loaded_skeleton, &block_count);
      CHECK(block_count ==
            (size_t)zozzSkeletonNumSoaJoints(loaded_skeleton));
      CHECK(rest != NULL);

      zozzSkeletonDestroy(loaded_skeleton);
    }

    CHECK(!zozzIArchiveTestSkeleton(in_archive));
    CHECK(zozzIArchiveTestAnimation(in_archive));

    ZozzAnimation* loaded_animation = NULL;
    CHECK(zozzIArchiveLoadAnimation(in_archive, &loaded_animation) ==
          ZOZZ_RESULT_OK);
    CHECK(loaded_animation != NULL);
    if (loaded_animation != NULL) {
      CHECK(zozzAnimationDuration(loaded_animation) ==
            zozzAnimationDuration(animation));
      CHECK(zozzAnimationNumTracks(loaded_animation) ==
            zozzAnimationNumTracks(animation));
      zozzAnimationDestroy(loaded_animation);
    }

    zozzIArchiveDestroy(in_archive);
  }

  zozzAnimationDestroy(animation);
  zozzSkeletonDestroy(skeleton);
  mem_stream_free(&mem);
}

static void test_raw_archive_round_trip(void) {
  MemStream mem;
  memset(&mem, 0, sizeof(mem));

  ZozzTransform rest;
  memset(&rest, 0, sizeof(rest));
  rest.rotation[3] = 1.f;
  rest.scale[0] = rest.scale[1] = rest.scale[2] = 1.f;

  // Authored child-before-parent on purpose: the archive stores the tree, so
  // the load side comes back DEPTH-FIRST and the indices are not the ones
  // used here. Names and parents survive; the numbering is the tree's.
  ZozzRawSkeleton* raw_skeleton = NULL;
  CHECK(zozzRawSkeletonCreate(&raw_skeleton) == ZOZZ_RESULT_OK);
  int32_t root_index = -1;
  CHECK(zozzRawSkeletonAddJoint(raw_skeleton, ZOZZ_NO_PARENT, "root", &rest,
                                &root_index) == ZOZZ_RESULT_OK);
  int32_t second_root = -1;
  CHECK(zozzRawSkeletonAddJoint(raw_skeleton, ZOZZ_NO_PARENT, "other", &rest,
                                &second_root) == ZOZZ_RESULT_OK);
  CHECK(zozzRawSkeletonAddJoint(raw_skeleton, root_index, "child", &rest,
                                NULL) == ZOZZ_RESULT_OK);
  CHECK(zozzRawSkeletonValidate(raw_skeleton));

  ZozzRawAnimation* raw_animation = NULL;
  CHECK(zozzRawAnimationCreate(1, 2.0f, "raw-smoke", &raw_animation) ==
        ZOZZ_RESULT_OK);
  const float t0[3] = {1.f, 2.f, 3.f};
  const float t1[3] = {4.f, 5.f, 6.f};
  CHECK(zozzRawAnimationPushTranslation(raw_animation, 0, 0.0f, t0) ==
        ZOZZ_RESULT_OK);
  CHECK(zozzRawAnimationPushTranslation(raw_animation, 0, 1.5f, t1) ==
        ZOZZ_RESULT_OK);
  CHECK(zozzRawAnimationValidate(raw_animation));

  ZozzStream write_stream;
  write_stream.opened = mem_opened;
  write_stream.write = mem_write;
  write_stream.read = NULL;
  write_stream.seek = NULL;
  write_stream.tell = NULL;
  write_stream.user = &mem;

  ZozzOArchive* out_archive = NULL;
  CHECK(zozzOArchiveCreate(&write_stream, ZOZZ_ENDIANNESS_LITTLE,
                           &out_archive) == ZOZZ_RESULT_OK);
  CHECK(zozzOArchiveSaveRawSkeleton(out_archive, raw_skeleton) ==
        ZOZZ_RESULT_OK);
  CHECK(zozzOArchiveSaveRawAnimation(out_archive, raw_animation) ==
        ZOZZ_RESULT_OK);
  zozzOArchiveDestroy(out_archive);

  mem.pos = 0;
  ZozzStream read_stream;
  read_stream.opened = mem_opened;
  read_stream.write = NULL;
  read_stream.read = mem_read;
  read_stream.seek = mem_seek;
  read_stream.tell = mem_tell;
  read_stream.user = &mem;

  ZozzIArchive* in_archive = NULL;
  CHECK(zozzIArchiveCreate(&read_stream, &in_archive) == ZOZZ_RESULT_OK);
  if (in_archive != NULL) {
    // A raw archive and a runtime archive carry different ozz tags, so the
    // runtime test refuses it rather than parsing foreign bytes.
    CHECK(!zozzIArchiveTestSkeleton(in_archive));
    CHECK(zozzIArchiveTestRawSkeleton(in_archive));

    ZozzRawSkeleton* loaded_skeleton = NULL;
    CHECK(zozzIArchiveLoadRawSkeleton(in_archive, &loaded_skeleton) ==
          ZOZZ_RESULT_OK);
    if (loaded_skeleton != NULL) {
      CHECK(zozzRawSkeletonNumJoints(loaded_skeleton) == 3);
      CHECK(strcmp(zozzRawSkeletonJointName(loaded_skeleton, 0), "root") == 0);
      CHECK(strcmp(zozzRawSkeletonJointName(loaded_skeleton, 1), "child") == 0);
      CHECK(strcmp(zozzRawSkeletonJointName(loaded_skeleton, 2), "other") == 0);
      CHECK(zozzRawSkeletonJointParent(loaded_skeleton, 1) == 0);
      CHECK(zozzRawSkeletonJointParent(loaded_skeleton, 2) == ZOZZ_NO_PARENT);
      zozzRawSkeletonDestroy(loaded_skeleton);
    }

    ZozzRawAnimation* loaded_animation = NULL;
    CHECK(zozzIArchiveTestRawAnimation(in_archive));
    CHECK(zozzIArchiveLoadRawAnimation(in_archive, &loaded_animation) ==
          ZOZZ_RESULT_OK);
    if (loaded_animation != NULL) {
      CHECK(strcmp(zozzRawAnimationName(loaded_animation), "raw-smoke") == 0);
      CHECK(zozzRawAnimationDuration(loaded_animation) == 2.0f);
      CHECK(zozzRawAnimationNumTranslations(loaded_animation, 0) == 2);

      // The out-buffer is the caller's, and a short one is refused before
      // anything is written — the sentinel below still reads back.
      ZozzRawTranslationKey one;
      one.time = -1.f;
      CHECK(zozzRawAnimationTranslations(loaded_animation, 0, &one, 1) ==
            ZOZZ_RESULT_BUFFER_TOO_SMALL);
      CHECK(one.time == -1.f);

      ZozzRawTranslationKey keys[4];
      CHECK(zozzRawAnimationTranslations(loaded_animation, 0, keys, 4) ==
            ZOZZ_RESULT_OK);
      CHECK(keys[0].time == 0.0f);
      CHECK(keys[0].value[0] == 1.f && keys[0].value[2] == 3.f);
      CHECK(keys[1].time == 1.5f);
      CHECK(keys[1].value[0] == 4.f && keys[1].value[2] == 6.f);

      CHECK(zozzRawAnimationClearTranslations(loaded_animation, 0) ==
            ZOZZ_RESULT_OK);
      CHECK(zozzRawAnimationNumTranslations(loaded_animation, 0) == 0);
      zozzRawAnimationDestroy(loaded_animation);
    }

    zozzIArchiveDestroy(in_archive);
  }

  zozzRawAnimationDestroy(raw_animation);
  zozzRawSkeletonDestroy(raw_skeleton);
  mem_stream_free(&mem);
}

static void test_archive_stream_rejection(void) {
  MemStream mem;
  memset(&mem, 0, sizeof(mem));

  ZozzStream stream;
  stream.opened = mem_opened;
  stream.write = mem_write;
  stream.read = mem_read;
  stream.seek = mem_seek;
  stream.tell = mem_tell;
  stream.user = &mem;

  ZozzStream missing_write = stream;
  missing_write.write = NULL;
  ZozzOArchive* out_archive = (ZozzOArchive*)0x1;
  CHECK(zozzOArchiveCreate(&missing_write, ZOZZ_ENDIANNESS_LITTLE,
                            &out_archive) == ZOZZ_RESULT_INVALID_ARGUMENT);
  CHECK(out_archive == NULL);

  // An out-of-range endianness is rejected too, ahead of the stream check
  // failing for a different reason -- both must independently guard the
  // entry point.
  out_archive = (ZozzOArchive*)0x1;
  CHECK(zozzOArchiveCreate(&stream, (ZozzEndianness)99, &out_archive) ==
        ZOZZ_RESULT_INVALID_ARGUMENT);
  CHECK(out_archive == NULL);

  // Every enum this ABI accepts has to survive the same treatment, not just
  // this one. A C caller can write `(SomeEnum)99` for any of them, and reading
  // an enum object holding a value no enumerator names is undefined — the
  // library must answer INVALID_ARGUMENT rather than abort a sanitised build.
  {
    ZozzRawFloatTrack *track = NULL;
    CHECK(zozzRawFloatTrackCreate(&track) == ZOZZ_RESULT_OK);
    CHECK(zozzRawFloatTrackPushKeyframe(
              track, (ZozzTrackInterpolation)99, 0.5f, 1.0f) ==
          ZOZZ_RESULT_INVALID_ARGUMENT);
    zozzRawFloatTrackDestroy(track);
  }

  ZozzStream missing_read = stream;
  missing_read.read = NULL;
  ZozzIArchive* in_archive = (ZozzIArchive*)0x1;
  CHECK(zozzIArchiveCreate(&missing_read, &in_archive) ==
        ZOZZ_RESULT_INVALID_ARGUMENT);
  CHECK(in_archive == NULL);

  ZozzStream missing_seek = stream;
  missing_seek.seek = NULL;
  in_archive = (ZozzIArchive*)0x1;
  CHECK(zozzIArchiveCreate(&missing_seek, &in_archive) ==
        ZOZZ_RESULT_INVALID_ARGUMENT);
  CHECK(in_archive == NULL);

  ZozzStream missing_tell = stream;
  missing_tell.tell = NULL;
  in_archive = (ZozzIArchive*)0x1;
  CHECK(zozzIArchiveCreate(&missing_tell, &in_archive) ==
        ZOZZ_RESULT_INVALID_ARGUMENT);
  CHECK(in_archive == NULL);

  // Destroying NULL is defined and must not crash, on either archive type.
  zozzOArchiveDestroy(NULL);
  zozzIArchiveDestroy(NULL);

  mem_stream_free(&mem);
}

/// The seam refuses to hand outstanding blocks to a different allocator, and
/// says so rather than corrupting a heap two calls later. A second allocator
/// differing only in `user` is enough to be a different allocator, which is
/// what a host dispatching through `user` depends on.
static void test_allocator_swap_refused_while_blocks_are_live(
    const ZozzAllocator* installed_allocator) {
  ZozzSamplingContext* context = NULL;
  Counters other_counters = {0, 0};
  ZozzAllocator other = *installed_allocator;
  other.user = &other_counters;

  CHECK(zozzAllocatorLiveBlocks() == 0);
  CHECK(zozzSamplingContextCreate(8, &context) == ZOZZ_RESULT_OK);
  CHECK(zozzAllocatorLiveBlocks() > 0);

  CHECK(zozzSetAllocator(&other) == ZOZZ_RESULT_ALLOCATOR_IN_USE);
  CHECK(zozzSetAllocator(NULL) == ZOZZ_RESULT_ALLOCATOR_IN_USE);
  // Refused means untouched: the allocator that produced the block is still
  // the one that will free it.
  test_allocator_getter_reports_the_installed_allocator(installed_allocator);
  // Reinstalling the identical allocator is not a swap.
  CHECK(zozzSetAllocator(installed_allocator) == ZOZZ_RESULT_OK);
  CHECK(other_counters.allocations == 0);

  zozzSamplingContextDestroy(context);
  CHECK(zozzAllocatorLiveBlocks() == 0);
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
  test_build_features();
  test_allocator_rejects_incomplete();
  test_allocator_getter_reports_not_installed();
  test_log_level();

  CHECK(zozzSetAllocator(&allocator) == ZOZZ_RESULT_OK);
  test_allocator_getter_reports_the_installed_allocator(&allocator);

  test_allocator_swap_refused_while_blocks_are_live(&allocator);

  test_bad_input();
  test_pose_round_trip();
  test_joint_weight_packing();
  test_sampling_context();
  test_track_triggering_on_the_stack();
  test_track_keyframe_views();
  test_archive_round_trip();
  test_raw_archive_round_trip();
  test_archive_stream_rejection();

  // The seam must actually have been used, and everything taken must have
  // been given back.
  CHECK(counters.allocations > 0);
  CHECK(counters.allocations == counters.frees);

  CHECK(zozzAllocatorLiveBlocks() == 0);
  CHECK(zozzSetAllocator(NULL) == ZOZZ_RESULT_OK);
  test_allocator_getter_reports_not_installed();

  if (failures != 0) {
    fprintf(stderr, "zozz c smoke: %d check(s) failed\n", failures);
    return 1;
  }
  printf("zozz c smoke: ok (%zu allocations balanced)\n", counters.allocations);
  return 0;
}
