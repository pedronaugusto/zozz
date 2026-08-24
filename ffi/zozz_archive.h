//===----------------------------------------------------------------------===//
// zozz — the OArchive write path: persisting a skeleton or a clip to a
// stream a host controls, or straight to a file.
//
// Conventions, ownership and thread safety are documented in zozz_core.h.
//===----------------------------------------------------------------------===//

#ifndef ZOZZ_ARCHIVE_H_
#define ZOZZ_ARCHIVE_H_

#include "zozz.h"

#ifdef __cplusplus
extern "C" {
#endif

//===----------------------------------------------------------------------===//
// Stream seam
//
// A host-provided sink standing in for ozz::io::Stream — the write half only
// — the same role ZozzAllocator plays for ozz::memory::Allocator. ozz's own
// OArchive calls exactly two things on a Stream while writing: opened(),
// once at construction, and Write(), repeatedly. Read/Seek/Tell/Size are
// never reached from this direction, so unlike Stream itself this bridge
// does not ask a host to implement them.
//===----------------------------------------------------------------------===//

typedef struct ZozzStream {
  /// Returns non-zero if the destination is open and ready to accept writes.
  ///
  /// Deliberately `int`, not `bool`, unlike an out-parameter elsewhere in
  /// this ABI: this field is a HOST-IMPLEMENTED callback, not a value zozz
  /// hands back, and a host compiling as strict C89 (no `<stdbool.h>`) can
  /// still implement it without pulling in a C99+ header just for this one
  /// signature.
  int (*opened)(void* user);
  /// Writes `size` bytes from `data`. Must return the number of bytes
  /// actually written; a short count is treated as an I/O failure.
  size_t (*write)(void* user, const void* data, size_t size);
  /// Opaque host pointer, passed back unmodified.
  void* user;
} ZozzStream;

//===----------------------------------------------------------------------===//
// The archive
//===----------------------------------------------------------------------===//

/// An archive bound to one ZozzStream, open for writing.
///
/// Constructing one writes an endianness byte immediately (zozz always
/// writes native-endian; IArchive adapts on read regardless of which
/// platform wrote the file), so every archive is scoped to exactly one
/// logical file: create it, write everything that belongs together, destroy
/// it.
typedef struct ZozzOArchive ZozzOArchive;

/// Binds a new archive to `stream`, which must already report itself opened.
/// `stream` is copied by value; the caller need not keep it alive, but
/// `stream->user` must outlive the archive.
ZOZZ_API ZozzResult zozzOArchiveCreate(const ZozzStream* stream,
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

//===----------------------------------------------------------------------===//
// File convenience
//
// Equivalent to zozzOArchiveCreate + the matching Save + zozzOArchiveDestroy
// over a file-backed stream, for the common case of one object per file.
//===----------------------------------------------------------------------===//

ZOZZ_API ZozzResult zozzSkeletonSaveFile(const ZozzSkeleton* skeleton,
                                         const char* path);

ZOZZ_API ZozzResult zozzAnimationSaveFile(const ZozzAnimation* animation,
                                          const char* path);

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // ZOZZ_ARCHIVE_H_
