//===----------------------------------------------------------------------===//
// zozz — core types and conventions: version, results, the allocator seam,
// plain-data types, and the ABI layout guard.
//
// This is the foundation every other zozz header builds on — ZOZZ_API,
// ZozzResult, ZozzTransform and ZozzFloat4x4 all live here, and the
// conventions that apply to the whole C ABI are documented once, in this
// file, rather than repeated per header.
//
// No exceptions cross this boundary; ozz is compiled -fno-exceptions. Opaque
// handles, POD structs with fixed layout, and a flat error enum are the only
// currency.
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

#ifndef ZOZZ_CORE_H_
#define ZOZZ_CORE_H_

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
#define ZOZZ_VERSION_MINOR 2
#define ZOZZ_VERSION_PATCH 0

/// Version of the zozz binding itself, packed as (major<<16)|(minor<<8)|patch.
/// Compare against the ZOZZ_VERSION_* macros to detect a header/library skew.
ZOZZ_API uint32_t zozzVersion(void);

/// Version of the vendored ozz-animation runtime, same packing.
ZOZZ_API uint32_t zozzOzzVersion(void);

//===----------------------------------------------------------------------===//
// Results
//===----------------------------------------------------------------------===//

// Every enumerator carries its type's name: ZOZZ_RESULT_<WHAT>, never
// ZOZZ_<WHAT>. That is not house style, it is what makes the enum checkable.
// The comptime cross-check in ../src/abi_check.zig pairs each Zig enum field
// with a header enumerator by computing `ZOZZ_` + TYPE + `_` + FIELD, and it
// has to, because a C enum reaches Zig as a plain integer alias with no
// record of which enumerators belonged to it. The prefix is the only thing
// left that can put them back together.
//
// No enumerator may be negative, here or in any enum added later. C leaves an
// enum's underlying type to the implementation and the implementations
// disagree — clang and gcc pick an unsigned type when every enumerator is
// non-negative, MSVC uses int. Staying non-negative is what makes that choice
// unobservable. A negative sentinel belongs in a fixed-width constant, the way
// ZOZZ_NO_PARENT is one.
typedef enum ZozzResult {
  ZOZZ_RESULT_OK = 0,
  /// The path could not be opened for reading.
  ZOZZ_RESULT_FILE_NOT_FOUND = 1,
  /// The stream ended early or could not be read.
  ZOZZ_RESULT_IO = 2,
  /// The archive tag did not identify the expected ozz object type.
  ZOZZ_RESULT_BAD_FORMAT = 3,
  /// The allocator returned NULL.
  ZOZZ_RESULT_OUT_OF_MEMORY = 4,
  /// A NULL handle, a negative count, or a NaN/out-of-domain scalar.
  ZOZZ_RESULT_INVALID_ARGUMENT = 5,
  /// An ozz job rejected its own parameters (Validate() returned false).
  ZOZZ_RESULT_JOB_INVALID = 6,
  /// A caller-provided output buffer was too small for the required count.
  ZOZZ_RESULT_BUFFER_TOO_SMALL = 7,
  /// The skeleton and animation describe a different number of joints/tracks.
  ZOZZ_RESULT_SKELETON_MISMATCH = 8,
  /// Authored offline data failed ozz validation (Validate() returned false):
  /// a raw skeleton over the depth limit, or raw animation keys out of order.
  ZOZZ_RESULT_INVALID_DATA = 9,
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
/// Returns ZOZZ_RESULT_INVALID_ARGUMENT if either function pointer is NULL, in
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

#endif  // ZOZZ_CORE_H_
