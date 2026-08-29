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

#ifndef __cplusplus
#include <stdbool.h>
#endif

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
#define ZOZZ_VERSION_MINOR 3
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
  /// The entry point exists but its build option is off (-Doptions,
  /// -Dgltf): the library was compiled without the code it needs.
  ZOZZ_RESULT_UNSUPPORTED = 10,
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

/// Reads back the allocator zozzSetAllocator most recently installed.
///
/// Writes true to `*installed` and fills `*out` with the exact ZozzAllocator
/// last passed to zozzSetAllocator — the same struct value, not merely an
/// equivalent one — when a host allocator is currently active. Writes false
/// and zeroes `*out` otherwise: zozzSetAllocator has never been called with a
/// non-NULL argument, or the most recent call passed NULL to restore ozz's
/// own allocator. `*out` is not a meaningful ZozzAllocator in that case;
/// `*installed` is what tells the two states apart, rather than leaving a
/// caller to guess whether an all-zero struct means "nothing installed" or
/// "an allocator with a NULL user pointer," which it cannot do reliably.
///
/// This is what makes save-and-restore possible: read the current allocator
/// before installing a temporary one, then pass it back to zozzSetAllocator
/// afterward — or, if `*installed` came back false, pass NULL instead of
/// reconstructing ozz's own allocator by hand.
///
/// Returns ZOZZ_RESULT_INVALID_ARGUMENT if `out` or `installed` is NULL.
ZOZZ_API ZozzResult zozzGetAllocator(ZozzAllocator* out, bool* installed);

//===----------------------------------------------------------------------===//
// Log verbosity
//
// ozz's own runtime writes diagnostics straight past this ABI: an unsupported
// archive version, for instance, is reported through ozz::log::Err() — see
// libs/ozz/src/animation/runtime/skeleton.cc:131 and animation.cc:285 — which
// lands on the process's own stderr with no ZozzResult attached, because
// ozz::io::IArchive::operator>> cannot fail, only log and leave an empty
// result (see "Validation at the boundary" in the README). A C++ host tunes
// that noise with ozz::log::SetLevel() / GetLevel(); this seam gives a zozz
// host the same two calls.
//
// ozz::log::Err() and Out() hand back a std::ostream&, which cannot cross a C
// boundary, so only the LEVEL is bound here, not the destination: a zozz host
// can silence or raise ozz's own diagnostics but has no way to redirect them
// into a file or a logger of its own. ZOZZ_LOG_LEVEL_SILENT is the whole of
// that lever, and it is a real one — it is what a host wanting no third-party
// text on its stderr actually needs.
//===----------------------------------------------------------------------===//

/// Mirrors ozz::log::Level exactly (checked in ffi/zozz_abi.cpp).
typedef enum ZozzLogLevel {
  /// No output at all, even errors are muted.
  ZOZZ_LOG_LEVEL_SILENT = 0,
  /// ozz's own default.
  ZOZZ_LOG_LEVEL_STANDARD = 1,
  /// Most verbose.
  ZOZZ_LOG_LEVEL_VERBOSE = 2,
} ZozzLogLevel;

/// Sets ozz's global logging verbosity — process-wide, like the allocator
/// seam above, because ozz's own log level is.
///
/// Returns ZOZZ_RESULT_INVALID_ARGUMENT for a value outside ZozzLogLevel,
/// leaving the current level untouched.
ZOZZ_API ZozzResult zozzSetLogLevel(ZozzLogLevel level);

/// Reads back ozz's current logging verbosity. Never fails: there is always
/// a current level, ZOZZ_LOG_LEVEL_STANDARD until something changes it.
ZOZZ_API ZozzLogLevel zozzGetLogLevel(void);

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
