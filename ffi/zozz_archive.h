//===----------------------------------------------------------------------===//
// zozz — the archive: persisting a skeleton, a clip or a track to a stream a
// host controls, or straight to a file, and reading them back the same way.
//
// Conventions, ownership and thread safety are documented in zozz_core.h.
//===----------------------------------------------------------------------===//

#ifndef ZOZZ_ARCHIVE_H_
#define ZOZZ_ARCHIVE_H_

#include "zozz.h"

#ifndef __cplusplus
#include <stdbool.h>
#endif

#ifdef __cplusplus
extern "C" {
#endif

//===----------------------------------------------------------------------===//
// Stream seam
//
// A host-provided stand-in for ozz::io::Stream — the same role ZozzAllocator
// plays for ozz::memory::Allocator. One struct serves both directions,
// because ozz has one Stream interface and this ABI has exactly one seam for
// it, not a second read-only shape bolted on beside the first.
//
// Which callbacks a direction actually reaches is narrow and fixed: OArchive
// calls only opened(), once at construction, and write(), repeatedly.
// IArchive calls opened() at construction, read() repeatedly, and seek() and
// tell() only to rewind after a tag test (see TestTag below) — a plain
// sequential read never seeks at all. Size() is never called from either
// direction, so unlike ozz::io::Stream this bridge does not ask a host to
// implement it.
//
// A callback the direction in use does not need may be left NULL:
// zozzOArchiveCreate rejects a stream missing `opened` or `write`;
// zozzIArchiveCreate rejects one missing `opened`, `read`, `seek` or `tell`.
// Either way the rejection happens at Create, not the first call that would
// have needed the missing callback.
//===----------------------------------------------------------------------===//

/// Matches ozz::io::Stream::Origin exactly (checked in ffi/zozz_abi.cpp), so
/// a `seek` callback can hand these straight to whatever seek primitive it
/// wraps — fseek, a memory cursor, or anything else with the same three
/// origins.
typedef enum ZozzSeekOrigin {
  /// Relative to the current position.
  ZOZZ_SEEK_ORIGIN_CURRENT = 0,
  /// Relative to the end of the stream.
  ZOZZ_SEEK_ORIGIN_END = 1,
  /// Relative to the beginning of the stream.
  ZOZZ_SEEK_ORIGIN_SET = 2,
} ZozzSeekOrigin;

typedef struct ZozzStream {
  /// Returns non-zero if the stream is open and ready for the calls below.
  ///
  /// Deliberately `int`, not `bool`, unlike an out-parameter elsewhere in
  /// this ABI: this field is a HOST-IMPLEMENTED callback, not a value zozz
  /// hands back, and a host compiling as strict C89 (no `<stdbool.h>`) can
  /// still implement it without pulling in a C99+ header just for this one
  /// signature.
  int (*opened)(void* user);

  /// Writes `size` bytes from `data`. Must return the number of bytes
  /// actually written; a short count is treated as an I/O failure. Required
  /// to write through this stream; leave NULL on a read-only one.
  size_t (*write)(void* user, const void* data, size_t size);

  /// Reads up to `size` bytes into `buffer`. Must return the number of bytes
  /// actually read; a short count is treated as an I/O failure, the same as a
  /// short `write` — a real end of stream is detected by a tag test or by the
  /// object count a host frames around its data, not by a partial read.
  /// Required to read through this stream; leave NULL on a write-only one.
  size_t (*read)(void* user, void* buffer, size_t size);

  /// Moves the position indicator by `offset` bytes relative to `origin`.
  /// Returns zero on success, non-zero otherwise — the same contract
  /// ozz::io::Stream::Seek uses. Required for reading, never called while
  /// writing; leave NULL on a write-only stream.
  int (*seek)(void* user, int offset, ZozzSeekOrigin origin);

  /// Returns the current position indicator, or a negative value on error.
  /// Required for reading, for the same reason as `seek`; leave NULL on a
  /// write-only stream.
  int (*tell)(void* user);

  /// Opaque host pointer, passed back unmodified.
  void* user;
} ZozzStream;

//===----------------------------------------------------------------------===//
// Endianness
//
// Mirrors ozz::Endianness exactly (checked in ffi/zozz_abi.cpp): the byte
// order zozzOArchiveCreate writes a file in.
//===----------------------------------------------------------------------===//

typedef enum ZozzEndianness {
  ZOZZ_ENDIANNESS_BIG = 0,
  ZOZZ_ENDIANNESS_LITTLE = 1,
} ZozzEndianness;

//===----------------------------------------------------------------------===//
// Writing
//
// Constructing a ZozzOArchive writes an endianness byte immediately, naming
// whichever ZozzEndianness the caller chose — a host producing a file for a
// foreign-endian target writes one, just as a C++ host would pass one to
// OArchive's own constructor — and IArchive adapts on read regardless of
// which platform wrote the file (see below). Every archive is scoped to
// exactly one logical file either way: create it, write everything that
// belongs together, destroy it.
//
// There is no entry point for the platform's own native order: a Zig host has
// that in the compiler's target information.
//
// OArchive::endian_swap() is not exposed either, because the host chose the
// byte order itself. IArchive::endian_swap() IS exposed, below: its value comes
// from a byte IArchive's constructor reads off the stream, and nothing else
// here hands that byte back.
//===----------------------------------------------------------------------===//

typedef struct ZozzOArchive ZozzOArchive;

/// Binds a new archive to `stream`, which must already report itself opened
/// and implement `write`. `stream` is copied by value; the caller need not
/// keep it alive, but `stream->user` must outlive the archive.
///
/// `endianness` selects the byte order written for every primitive and
/// tagged object saved through this archive from here on.
ZOZZ_API ZozzResult zozzOArchiveCreate(const ZozzStream* stream,
                                       ZozzEndianness endianness,
                                       ZozzOArchive** out);

ZOZZ_API void zozzOArchiveDestroy(ZozzOArchive* archive);

/// Writes `size` untyped bytes, unswapped and uninterpreted — the same
/// primitive ozz::io::OArchive::SaveBinary exposes, for a host framing its
/// own data around the tagged objects below.
ZOZZ_API ZozzResult zozzOArchiveSaveBinary(ZozzOArchive* archive,
                                           const void* data, size_t size);

/// Writes one native-endian 32-bit integer.
ZOZZ_API ZozzResult zozzOArchiveSaveInt32(ZozzOArchive* archive,
                                          int32_t value);

/// Writes one native-endian float. Rejects NaN.
ZOZZ_API ZozzResult zozzOArchiveSaveFloat(ZozzOArchive* archive, float value);

/// Writes a tagged, versioned skeleton — the same archive shape
/// zozzSkeletonLoadFile / zozzSkeletonLoadMemory read back.
ZOZZ_API ZozzResult zozzOArchiveSaveSkeleton(ZozzOArchive* archive,
                                             const ZozzSkeleton* skeleton);

/// Writes a tagged, versioned animation clip.
ZOZZ_API ZozzResult zozzOArchiveSaveAnimation(ZozzOArchive* archive,
                                              const ZozzAnimation* animation);

/// Writes a tagged, versioned runtime track — the same archive shape
/// zozzFloatTrackLoadFile / zozzFloatTrackLoadMemory read back. One entry
/// point per track value type; a TrackBuilder-produced track otherwise has
/// no way to leave the process it was built in.
ZOZZ_API ZozzResult zozzOArchiveSaveFloatTrack(ZozzOArchive* archive,
                                               const ZozzFloatTrack* track);

ZOZZ_API ZozzResult zozzOArchiveSaveFloat2Track(ZozzOArchive* archive,
                                                const ZozzFloat2Track* track);

ZOZZ_API ZozzResult zozzOArchiveSaveFloat3Track(ZozzOArchive* archive,
                                                const ZozzFloat3Track* track);

ZOZZ_API ZozzResult zozzOArchiveSaveFloat4Track(ZozzOArchive* archive,
                                                const ZozzFloat4Track* track);

ZOZZ_API ZozzResult zozzOArchiveSaveQuaternionTrack(
    ZozzOArchive* archive, const ZozzQuaternionTrack* track);

//===----------------------------------------------------------------------===//
// Reading
//
// The read twin of the above. Constructing a ZozzIArchive reads the
// endianness byte an OArchive wrote and adapts every primitive and tagged
// object loaded afterward to the native format, regardless of which platform
// wrote the file — so `stream` must be positioned exactly where it was right
// after the matching zozzOArchiveCreate. Scoped the same way: create it,
// read back everything that was written, in the order it was written,
// destroy it.
//===----------------------------------------------------------------------===//

typedef struct ZozzIArchive ZozzIArchive;

/// Binds a new archive to `stream`, which must already report itself opened
/// and implement `read`, `seek` and `tell`. `stream` is copied by value; the
/// caller need not keep it alive, but `stream->user` must outlive the
/// archive.
ZOZZ_API ZozzResult zozzIArchiveCreate(const ZozzStream* stream,
                                       ZozzIArchive** out);

ZOZZ_API void zozzIArchiveDestroy(ZozzIArchive* archive);

/// True when the stream was written in the opposite byte order from this
/// platform's. Loads swap transparently already; this matters only for raw
/// bytes read back through zozzIArchiveLoadBinary. False for a NULL archive.
ZOZZ_API bool zozzIArchiveEndianSwap(const ZozzIArchive* archive);

/// Reads `size` untyped bytes into `data`, unswapped and uninterpreted — the
/// read twin of zozzOArchiveSaveBinary.
ZOZZ_API ZozzResult zozzIArchiveLoadBinary(ZozzIArchive* archive, void* data,
                                           size_t size);

/// Reads one native-endian 32-bit integer.
ZOZZ_API ZozzResult zozzIArchiveLoadInt32(ZozzIArchive* archive,
                                          int32_t* out);

/// Reads one native-endian float.
ZOZZ_API ZozzResult zozzIArchiveLoadFloat(ZozzIArchive* archive, float* out);

/// Reads one tagged, versioned skeleton. Applies the same checks
/// zozzSkeletonLoadFile / zozzSkeletonLoadMemory do: the next object's tag
/// must identify a skeleton (ZOZZ_RESULT_BAD_FORMAT otherwise) and the parsed
/// result must pass the same joint-count and array-shape sanity check.
ZOZZ_API ZozzResult zozzIArchiveLoadSkeleton(ZozzIArchive* archive,
                                             ZozzSkeleton** out);

/// Reads one tagged, versioned animation clip, with the same tag and
/// sanity checks zozzAnimationLoadFile / zozzAnimationLoadMemory apply.
ZOZZ_API ZozzResult zozzIArchiveLoadAnimation(ZozzIArchive* archive,
                                              ZozzAnimation** out);

/// Reads one tagged, versioned runtime track — the read twin of
/// zozzOArchiveSaveFloatTrack and the type-specific entry points below it.
ZOZZ_API ZozzResult zozzIArchiveLoadFloatTrack(ZozzIArchive* archive,
                                               ZozzFloatTrack** out);

ZOZZ_API ZozzResult zozzIArchiveLoadFloat2Track(ZozzIArchive* archive,
                                                ZozzFloat2Track** out);

ZOZZ_API ZozzResult zozzIArchiveLoadFloat3Track(ZozzIArchive* archive,
                                                ZozzFloat3Track** out);

ZOZZ_API ZozzResult zozzIArchiveLoadFloat4Track(ZozzIArchive* archive,
                                                ZozzFloat4Track** out);

ZOZZ_API ZozzResult zozzIArchiveLoadQuaternionTrack(
    ZozzIArchive* archive, ZozzQuaternionTrack** out);

//===----------------------------------------------------------------------===//
// Tag sniffing
//
// Answers "is the next object in this archive a T?" without committing to
// it — the ozz::io::IArchive::TestTag<T>() a host cannot otherwise reach,
// which is what lets one read a mixed archive: test each type in turn, then
// Load the one that matched. Whichever answer comes back, the read position
// is exactly where it was before the call, so a false result is free to try
// again with a different type, and a true result is free to Load right
// after.
//===----------------------------------------------------------------------===//

/// True if the next object is a skeleton.
ZOZZ_API bool zozzIArchiveTestSkeleton(ZozzIArchive* archive);

/// True if the next object is an animation clip.
ZOZZ_API bool zozzIArchiveTestAnimation(ZozzIArchive* archive);

/// True if the next object is a float track. One entry point per track value
/// type, matching the Load calls above.
ZOZZ_API bool zozzIArchiveTestFloatTrack(ZozzIArchive* archive);

ZOZZ_API bool zozzIArchiveTestFloat2Track(ZozzIArchive* archive);

ZOZZ_API bool zozzIArchiveTestFloat3Track(ZozzIArchive* archive);

ZOZZ_API bool zozzIArchiveTestFloat4Track(ZozzIArchive* archive);

ZOZZ_API bool zozzIArchiveTestQuaternionTrack(ZozzIArchive* archive);

//===----------------------------------------------------------------------===//
// File convenience
//
// Equivalent to zozzOArchiveCreate + the matching Save + zozzOArchiveDestroy
// over a file-backed stream, for the common case of one object per file —
// always native-endian, unconditionally, with no ZozzEndianness parameter of
// their own: call zozzOArchiveCreate directly over a host-implemented file
// stream for anything else. The read equivalent is zozzSkeletonLoadFile /
// zozzSkeletonLoadMemory and the animation/track functions beside them —
// those own the file's lifetime internally the same way, and existed before
// this archive did.
//===----------------------------------------------------------------------===//

ZOZZ_API ZozzResult zozzSkeletonSaveFile(const ZozzSkeleton* skeleton,
                                         const char* path);

ZOZZ_API ZozzResult zozzAnimationSaveFile(const ZozzAnimation* animation,
                                          const char* path);

ZOZZ_API ZozzResult zozzFloatTrackSaveFile(const ZozzFloatTrack* track,
                                           const char* path);

ZOZZ_API ZozzResult zozzFloat2TrackSaveFile(const ZozzFloat2Track* track,
                                            const char* path);

ZOZZ_API ZozzResult zozzFloat3TrackSaveFile(const ZozzFloat3Track* track,
                                            const char* path);

ZOZZ_API ZozzResult zozzFloat4TrackSaveFile(const ZozzFloat4Track* track,
                                            const char* path);

ZOZZ_API ZozzResult zozzQuaternionTrackSaveFile(const ZozzQuaternionTrack* track,
                                                const char* path);

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // ZOZZ_ARCHIVE_H_
