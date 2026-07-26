//===----------------------------------------------------------------------===//
// zozz — a C ABI over ozz-animation's runtime.
//
// This header is the ONLY contract between the C++ implementation and any
// consumer (the Zig wrapper in ../src, or a plain C host). It is deliberately
// free of C++: opaque handles, POD structs with fixed layout, and a flat error
// enum. No exceptions cross this boundary; ozz is compiled -fno-exceptions.
//
// Ownership rules, uniformly:
//   *Create / *Load  allocate through the installed allocator and yield a
//                    handle the caller owns.
//   *Destroy         accepts NULL and is idempotent-safe on a NULL handle.
//   Query accessors  never allocate; returned pointers borrow from the handle
//                    and die with it.
//
// Thread safety: handles are not internally synchronised. Distinct handles may
// be used concurrently. A ZozzSamplingContext is single-threaded state — one
// per concurrently-sampled animation instance.
//===----------------------------------------------------------------------===//

#ifndef ZOZZ_H_
#define ZOZZ_H_

#include <stddef.h>
#include <stdint.h>

#if defined(_MSC_VER) && defined(ZOZZ_SHARED)
#ifdef ZOZZ_BUILD
#define ZOZZ_API __declspec(dllexport)
#else
#define ZOZZ_API __declspec(dllimport)
#endif
#else
#define ZOZZ_API
#endif

#ifdef __cplusplus
extern "C" {
#endif

//===----------------------------------------------------------------------===//
// Version
//===----------------------------------------------------------------------===//

#define ZOZZ_VERSION_MAJOR 0
#define ZOZZ_VERSION_MINOR 1
#define ZOZZ_VERSION_PATCH 0

/// Version of the zozz binding itself, packed as (major<<16)|(minor<<8)|patch.
/// Compare against the ZOZZ_VERSION_* macros to detect a header/library skew.
ZOZZ_API uint32_t zozzVersion(void);

/// Version of the vendored ozz-animation runtime, same packing.
ZOZZ_API uint32_t zozzOzzVersion(void);

//===----------------------------------------------------------------------===//
// Results
//===----------------------------------------------------------------------===//

typedef enum ZozzResult {
  ZOZZ_OK = 0,
  /// The path could not be opened for reading.
  ZOZZ_ERR_FILE_NOT_FOUND = 1,
  /// The stream ended early or could not be read.
  ZOZZ_ERR_IO = 2,
  /// The archive tag did not identify the expected ozz object type.
  ZOZZ_ERR_BAD_FORMAT = 3,
  /// The allocator returned NULL.
  ZOZZ_ERR_OUT_OF_MEMORY = 4,
  /// A NULL handle, a negative count, or a NaN/out-of-domain scalar.
  ZOZZ_ERR_INVALID_ARGUMENT = 5,
  /// An ozz job rejected its own parameters (Validate() returned false).
  ZOZZ_ERR_JOB_INVALID = 6,
  /// A caller-provided output buffer was too small for the required count.
  ZOZZ_ERR_BUFFER_TOO_SMALL = 7,
  /// The skeleton and animation describe a different number of joints/tracks.
  ZOZZ_ERR_SKELETON_MISMATCH = 8,
} ZozzResult;

/// Static, never-NULL description of a result code. Borrowed; do not free.
ZOZZ_API const char* zozzResultName(ZozzResult result);

//===----------------------------------------------------------------------===//
// Allocator seam
//
// ozz routes every runtime allocation through a single global allocator. zozz
// exposes that seam verbatim rather than hiding it, so a host can account for
// animation memory in its own budget.
//
// Note the asymmetry inherited from ozz: `deallocate` receives only the block
// pointer — no size, no alignment. A host allocator that needs those (Zig's
// std.mem.Allocator does) must record them in a header of its own. The Zig
// wrapper in ../src/memory.zig does exactly that.
//===----------------------------------------------------------------------===//

typedef struct ZozzAllocator {
  /// Must return a block of at least `size` bytes aligned to `alignment`
  /// (always a power of two), or NULL on failure. `size` may be 0.
  void* (*allocate)(void* user, size_t size, size_t alignment);
  /// Frees a block from `allocate`. Must tolerate a NULL block.
  void (*deallocate)(void* user, void* block);
  /// Opaque host pointer, passed back unmodified.
  void* user;
} ZozzAllocator;

/// Installs a process-wide allocator for all subsequent ozz allocations.
///
/// This is global state, mirroring ozz's own design. Call it before loading
/// anything, and do not swap it while live handles exist — those handles will
/// be freed through whichever allocator is installed at destruction time.
/// Passing NULL restores ozz's default (malloc/free) allocator.
///
/// `alloc` is copied by value; the caller need not keep it alive, but `user`
/// must outlive every handle allocated through it.
///
/// Returns ZOZZ_ERR_INVALID_ARGUMENT if either function pointer is NULL, in
/// which case the previously installed allocator is left untouched.
ZOZZ_API ZozzResult zozzSetAllocator(const ZozzAllocator* alloc);

//===----------------------------------------------------------------------===//
// Plain-data types
//===----------------------------------------------------------------------===//

/// One joint's local-space transform, array-of-structs.
///
/// Rotation is a quaternion in (x, y, z, w) order — w LAST, matching ozz.
/// Layout is asserted against ozz's own types in zozz_abi.cpp and mirrored by
/// a comptime check in ../src/math.zig.
typedef struct ZozzTransform {
  float translation[3];
  float rotation[4];
  float scale[3];
} ZozzTransform;

#if defined(__cplusplus)
#define ZOZZ_ALIGN16 alignas(16)
#elif defined(_MSC_VER)
#define ZOZZ_ALIGN16 __declspec(align(16))
#else
#define ZOZZ_ALIGN16 _Alignas(16)
#endif

/// A 4x4 matrix in COLUMN-MAJOR order: m[0..3] is the first column.
/// This matches ozz's Float4x4 (four SimdFloat4 columns) with no transpose.
///
/// 16-byte aligned, and that is load-bearing: ozz's Float4x4 is four SIMD
/// registers and is written with aligned stores. Arrays of this type passed to
/// zozzLocalToModel must therefore start on a 16-byte boundary; the function
/// rejects a misaligned pointer rather than faulting inside ozz.
typedef struct ZozzFloat4x4 {
  ZOZZ_ALIGN16 float m[16];
} ZozzFloat4x4;

//===----------------------------------------------------------------------===//
// Opaque handles
//===----------------------------------------------------------------------===//

/// A joint hierarchy with rest pose. Immutable once loaded.
typedef struct ZozzSkeleton ZozzSkeleton;

/// A compressed animation clip. Immutable once loaded.
typedef struct ZozzAnimation ZozzAnimation;

/// Per-instance scratch that lets forward sampling exploit frame coherency.
/// Not shareable between two animations sampled in the same frame.
typedef struct ZozzSamplingContext ZozzSamplingContext;

/// A pose held in ozz's native structure-of-arrays layout.
///
/// SoA is the currency of ozz's job pipeline: sampling writes it, blending
/// consumes and produces it, local-to-model reads it. Keeping it opaque means
/// consumers never depend on the SIMD layout, while still being able to chain
/// jobs without a conversion per step. Convert to AoS only at the edges, with
/// zozzSoaPoseToLocalTransforms.
typedef struct ZozzSoaPose ZozzSoaPose;

//===----------------------------------------------------------------------===//
// Skeleton
//===----------------------------------------------------------------------===//

/// Loads a skeleton from a .ozz file produced by an ozz offline tool.
ZOZZ_API ZozzResult zozzSkeletonLoadFile(const char* path, ZozzSkeleton** out);

/// Loads a skeleton from a memory image of a .ozz file. The buffer is read
/// during the call only and is not retained.
ZOZZ_API ZozzResult zozzSkeletonLoadMemory(const void* data, size_t size,
                                           ZozzSkeleton** out);

ZOZZ_API void zozzSkeletonDestroy(ZozzSkeleton* skeleton);

ZOZZ_API int zozzSkeletonNumJoints(const ZozzSkeleton* skeleton);

/// Number of SoA blocks: (num_joints + 3) / 4.
ZOZZ_API int zozzSkeletonNumSoaJoints(const ZozzSkeleton* skeleton);

/// Borrowed, NUL-terminated joint name, or NULL if `joint` is out of range.
ZOZZ_API const char* zozzSkeletonJointName(const ZozzSkeleton* skeleton,
                                           int joint);

/// Parent index, or ZOZZ_NO_PARENT for a root. Returns ZOZZ_NO_PARENT for an
/// out-of-range `joint` as well — check against zozzSkeletonNumJoints first if
/// the distinction matters.
#define ZOZZ_NO_PARENT (-1)
ZOZZ_API int16_t zozzSkeletonJointParent(const ZozzSkeleton* skeleton,
                                         int joint);

/// Writes the rest pose as AoS local transforms. `count` must be at least
/// zozzSkeletonNumJoints, else ZOZZ_ERR_BUFFER_TOO_SMALL.
ZOZZ_API ZozzResult zozzSkeletonRestPose(const ZozzSkeleton* skeleton,
                                         ZozzTransform* out, size_t count);

//===----------------------------------------------------------------------===//
// Animation
//===----------------------------------------------------------------------===//

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

//===----------------------------------------------------------------------===//
// SoA pose
//===----------------------------------------------------------------------===//

/// Allocates a pose buffer sized for `num_joints` (rounded up to a SoA block).
ZOZZ_API ZozzResult zozzSoaPoseCreate(int num_joints, ZozzSoaPose** out);

ZOZZ_API void zozzSoaPoseDestroy(ZozzSoaPose* pose);

ZOZZ_API int zozzSoaPoseNumJoints(const ZozzSoaPose* pose);

/// Fills the pose with identity transforms.
ZOZZ_API ZozzResult zozzSoaPoseSetIdentity(ZozzSoaPose* pose);

/// Fills the pose from a skeleton's rest pose. Joint counts must match.
ZOZZ_API ZozzResult zozzSoaPoseSetRestPose(ZozzSoaPose* pose,
                                           const ZozzSkeleton* skeleton);

/// SoA -> AoS. `count` must be at least zozzSoaPoseNumJoints.
ZOZZ_API ZozzResult zozzSoaPoseToLocalTransforms(const ZozzSoaPose* pose,
                                                 ZozzTransform* out,
                                                 size_t count);

/// AoS -> SoA. `count` must be at least zozzSoaPoseNumJoints. Joints in the
/// trailing partial SoA block are padded with identity.
ZOZZ_API ZozzResult zozzSoaPoseFromLocalTransforms(ZozzSoaPose* pose,
                                                   const ZozzTransform* in,
                                                   size_t count);

//===----------------------------------------------------------------------===//
// Sampling
//===----------------------------------------------------------------------===//

/// Creates a context able to sample any animation of at most `max_tracks`
/// tracks. Size it from zozzSkeletonNumJoints, not from one clip, if the
/// context will be reused across clips.
ZOZZ_API ZozzResult zozzSamplingContextCreate(int max_tracks,
                                              ZozzSamplingContext** out);

ZOZZ_API void zozzSamplingContextDestroy(ZozzSamplingContext* context);

/// Drops cached keyframe state. Required before reusing a context with a
/// different animation that may have been allocated at a recycled address.
ZOZZ_API void zozzSamplingContextInvalidate(ZozzSamplingContext* context);

ZOZZ_API int zozzSamplingContextMaxTracks(const ZozzSamplingContext* context);

/// Samples `animation` at `ratio` (unit interval, clamped) into `out`.
///
/// `out` must hold at least as many joints as the animation has tracks.
/// Joints beyond the animation's track count are left untouched — seed them
/// with zozzSoaPoseSetRestPose if the animation is partial.
ZOZZ_API ZozzResult zozzSample(const ZozzAnimation* animation,
                               ZozzSamplingContext* context, float ratio,
                               ZozzSoaPose* out);

//===----------------------------------------------------------------------===//
// Local-to-model
//===----------------------------------------------------------------------===//

/// Walks the hierarchy, converting local-space SoA transforms to model-space
/// AoS matrices. `root` is an optional pre-multiplied root matrix (NULL for
/// identity). `count` must be at least the skeleton's joint count.
ZOZZ_API ZozzResult zozzLocalToModel(const ZozzSkeleton* skeleton,
                                     const ZozzSoaPose* locals,
                                     const ZozzFloat4x4* root,
                                     ZozzFloat4x4* out, size_t count);

//===----------------------------------------------------------------------===//
// ABI layout guard
//
// The Zig wrapper hand-declares `extern struct`s mirroring the POD types
// above. Nothing in either compiler checks that those two declarations agree —
// a field reordered here and not there is silent memory corruption, not a
// build error. zozzAbiLayout reports what the C++ side actually compiled to so
// the other side can assert against it in a test.
//
// This is a deliberate answer to a real failure mode in comparable bindings,
// which pair a hand-written header with hand-written externs and check
// neither.
//===----------------------------------------------------------------------===//

typedef struct ZozzAbiLayout {
  /// sizeof(ZozzAbiLayout). Read this first: if it disagrees with the
  /// consumer's own sizeof, the struct itself has changed and no field below
  /// can be trusted.
  uint32_t layout_size;

  uint32_t transform_size;
  uint32_t transform_align;
  uint32_t transform_offset_translation;
  uint32_t transform_offset_rotation;
  uint32_t transform_offset_scale;

  uint32_t float4x4_size;
  uint32_t float4x4_align;

  uint32_t allocator_size;
  uint32_t allocator_align;
  uint32_t allocator_offset_allocate;
  uint32_t allocator_offset_deallocate;
  uint32_t allocator_offset_user;

  /// Number of enumerators in ZozzResult, so a consumer can assert its own
  /// error mapping is exhaustive.
  uint32_t result_count;
} ZozzAbiLayout;

/// Fills `out` with the layout the library was compiled with. Never fails.
ZOZZ_API void zozzAbiLayout(ZozzAbiLayout* out);

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // ZOZZ_H_
