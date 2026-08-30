//===----------------------------------------------------------------------===//
// zozz — core types and conventions: version, results, the allocator seam,
// plain-data types, and the ABI layout guard. Every other zozz header builds
// on this one, and ABI-wide conventions are documented once, here. No
// exceptions cross this boundary (ozz is compiled -fno-exceptions); the only
// currency is opaque handles, POD structs with fixed layout, and a flat
// error enum. Ownership: *Create/*Load allocate through the installed
// allocator and yield a caller-owned handle. *Destroy accepts NULL and is
// idempotent on NULL. Query accessors never allocate; returned pointers
// borrow from the handle and die with it. A ZozzSamplingContext is
// single-threaded state, one per concurrently-sampled animation instance.
// Thread safety is stated once, at the allocator seam below, which is what
// bounds it: every entry point that allocates reaches one allocator.
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
#define ZOZZ_VERSION_MINOR 4
#define ZOZZ_VERSION_PATCH 0

/// Version of the zozz binding itself, packed as (major<<16)|(minor<<8)|patch.
/// Compare against the ZOZZ_VERSION_* macros to detect a header/library skew.
ZOZZ_API uint32_t zozzVersion(void);

/// Version of the vendored ozz-animation runtime, same packing.
ZOZZ_API uint32_t zozzOzzVersion(void);

//===----------------------------------------------------------------------===//
// Results
//===----------------------------------------------------------------------===//

// Every enumerator carries its type's name (ZOZZ_RESULT_<WHAT>, not
// ZOZZ_<WHAT>) so abi_check.zig's cross-check can derive it from `ZOZZ_` +
// TYPE + `_` + FIELD — a C enum reaches Zig with no other record of its
// members. No enumerator may be negative, here or later: clang/gcc vs. MSVC
// disagree on the underlying type otherwise. A negative sentinel goes in a
// fixed-width constant instead, as ZOZZ_NO_PARENT is.
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
  /// A different allocator was offered to zozzSetAllocator while blocks the
  /// installed one produced are still live. Destroy what is outstanding
  /// first: a block must be freed by the allocator that produced it.
  ZOZZ_RESULT_ALLOCATOR_IN_USE = 11,
} ZozzResult;

/// Static, never-NULL description of a result code. Borrowed; do not free.
ZOZZ_API const char* zozzResultName(ZozzResult result);

//===----------------------------------------------------------------------===//
// Allocator seam
//
// ozz routes every runtime allocation through one global allocator, and zozz
// exposes that seam verbatim. Note the asymmetry inherited from ozz:
// `deallocate` receives only the block pointer — no size, no alignment — so a
// host needing those (Zig does) records them in a header, as memory.zig does.
//
// THREAD SAFETY, for the whole ABI. Distinct handles may be used concurrently
// only when the installed allocator is thread-safe, since every entry point
// that allocates reaches this one seam; ozz's own default is, a host one need
// not be. Neither a handle nor the seam is synchronised: install from one
// thread, before any other thread calls into zozz.
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

/// Installs a process-wide allocator for all subsequent ozz allocations. NULL
/// restores ozz's default (malloc/free). `alloc` is copied, but `user` must
/// outlive every handle it allocates; a NULL function pointer returns
/// ZOZZ_RESULT_INVALID_ARGUMENT. A swap while zozzAllocatorLiveBlocks() is
/// non-zero returns ZOZZ_RESULT_ALLOCATOR_IN_USE, allocator untouched --
/// reinstalling the identical struct is not a swap and always succeeds.
ZOZZ_API ZozzResult zozzSetAllocator(const ZozzAllocator* alloc);

/// Reads back the allocator zozzSetAllocator most recently installed. If a
/// host allocator is active, writes true to `*installed` and fills `*out`
/// with the exact ZozzAllocator last passed to zozzSetAllocator (same struct
/// value, not merely equivalent). Otherwise writes false and zeroes `*out` —
/// `*installed` alone tells a never-installed state from a zero-valued one.
/// Returns ZOZZ_RESULT_INVALID_ARGUMENT if `out` or `installed` is NULL.
ZOZZ_API ZozzResult zozzGetAllocator(ZozzAllocator* out, bool* installed);

/// Blocks the installed host allocator handed out and has not yet been asked
/// to free. Zero before the first install and zero again once every handle
/// allocated through one is destroyed, which makes it both a shut-down leak
/// check and what zozzSetAllocator consults before allowing a swap. ozz's own
/// default allocator is not routed through this seam and is not counted.
ZOZZ_API size_t zozzAllocatorLiveBlocks(void);

//===----------------------------------------------------------------------===//
// Log verbosity
// ozz's own runtime writes diagnostics straight past this ABI: an unsupported
// archive version, for instance, is reported through ozz::log::Err(), which
// lands on the process's own stderr with no ZozzResult attached, because
// ozz::io::IArchive::operator>> cannot fail, only log and leave an empty
// result. A C++ host tunes that noise with ozz::log::SetLevel()/GetLevel();
// this seam gives a zozz host the same two calls. ozz::log::Err()/Out() hand
// back a std::ostream&, which cannot cross a C boundary, so only the LEVEL is
// bound here, not the destination: a zozz host can silence or raise ozz's
// diagnostics but cannot redirect them into a file or logger of its own.
// ZOZZ_LOG_LEVEL_SILENT is the real lever for a host that wants no
// third-party text on its stderr.
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

//===----------------------------------------------------------------------===//
// 16-byte alignment
//
// ZOZZ_ALIGN16 is applied to a struct DEFINITION -- `struct ZOZZ_ALIGN16 X {}`
// -- and never to a member. Zig 0.16's translate-c does not honour
// `#pragma pack(pop)` on non-MSVC targets: after any `#pragma pack(push, 8)`
// in an included header, a later MEMBER carrying `_Alignas(16)` reads back as
// align 8. mingw's corecrt.h does exactly that around <stdint.h>, so on
// x86_64-windows-gnu a member-aligned type reads as align 8 through @cImport
// while the compiled library lays it out at 16, and ../src/abi_check.zig fires
// on a difference no object file has. Alignment on the TYPE survives the
// leaked pack on all four targets [measured 2026-08-30: windows-gnu,
// windows-msvc, linux-gnu, macos]. It is also the truer statement.
//===----------------------------------------------------------------------===//

#if defined(__cplusplus)
#define ZOZZ_ALIGN16 alignas(16)
#elif defined(_MSC_VER)
#define ZOZZ_ALIGN16 __declspec(align(16))
#else
#define ZOZZ_ALIGN16 __attribute__((aligned(16)))
#endif

/// A 4x4 matrix in COLUMN-MAJOR order: m[0..3] is the first column, matching
/// ozz's Float4x4 (four SimdFloat4 columns) with no transpose. 16-byte
/// aligned, and that is load-bearing: ozz's Float4x4 is four SIMD registers
/// written with aligned stores, so arrays of this type passed to
/// zozzLocalToModel must start on a 16-byte boundary; the function rejects a
/// misaligned pointer rather than faulting inside ozz.
typedef struct ZOZZ_ALIGN16 ZozzFloat4x4 {
  float m[16];
} ZozzFloat4x4;

/// One SIMD register of four floats, ozz's SimdFloat4. It crosses as a type
/// rather than as `float[4]` because that is what a per-joint weight buffer
/// is an array of: one register per four joints, not one float per joint.
typedef struct ZOZZ_ALIGN16 ZozzSimdFloat4 {
  float f[4];
} ZozzSimdFloat4;

//===----------------------------------------------------------------------===//
// Structure of arrays
//
// ozz's job pipeline speaks SoA: four joints share one register per component,
// so a pose is an array of ZozzSoaTransform, one per four joints, and the
// count is ceil(num_joints / 4) -- zozzSoaBlocks. The three types below are
// ozz::math::SoaFloat3, SoaQuaternion and SoaTransform member for member, and
// zozz_abi.cpp asserts every size, alignment and offset against them.
//
// They are public, and that is the point: the caller owns pose memory. A pose
// can live in an arena, on the stack, or as a sub-range of a batch. An opaque
// handle made every one of those impossible and cost an allocation per pose.
//===----------------------------------------------------------------------===//

/// Four joints' worth of one 3-component value: x[i] is joint i's x.
typedef struct ZOZZ_ALIGN16 ZozzSoaFloat3 {
  float x[4];
  float y[4];
  float z[4];
} ZozzSoaFloat3;

/// Four joints' worth of a quaternion, in (x, y, z, w) order like
/// ZozzTransform's.
typedef struct ZOZZ_ALIGN16 ZozzSoaQuaternion {
  float x[4];
  float y[4];
  float z[4];
  float w[4];
} ZozzSoaQuaternion;

/// Four joints' local-space transforms, ozz::math::SoaTransform. This is the
/// currency of the job pipeline: sampling writes it, blending reads and
/// writes it, local-to-model reads it. Convert to ZozzTransform only at the
/// edges, with zozzSoaPoseToLocalTransforms.
typedef struct ZOZZ_ALIGN16 ZozzSoaTransform {
  ZozzSoaFloat3 translation;
  ZozzSoaQuaternion rotation;
  ZozzSoaFloat3 scale;
} ZozzSoaTransform;

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

  uint32_t simd_float4_size;
  uint32_t simd_float4_align;

  uint32_t soa_transform_size;
  uint32_t soa_transform_align;
  uint32_t soa_transform_offset_translation;
  uint32_t soa_transform_offset_rotation;
  uint32_t soa_transform_offset_scale;

  uint32_t blending_layer_size;
  uint32_t blending_layer_align;
  uint32_t blending_layer_offset_weight;
  uint32_t blending_layer_offset_transform;
  uint32_t blending_layer_offset_num_transform;
  uint32_t blending_layer_offset_joint_weights;
  uint32_t blending_layer_offset_num_joint_weights;

  uint32_t track_triggering_size;
  uint32_t track_triggering_align;

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
