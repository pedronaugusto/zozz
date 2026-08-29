//===----------------------------------------------------------------------===//
// zozz — the stream bridge in both directions, and the OArchive/IArchive
// entry points.
//===----------------------------------------------------------------------===//

#include "zozz_internal.h"
#include "zozz_track_types.h"

namespace {

/// Write-only adapter from a host ZozzStream onto ozz::io::Stream.
///
/// ozz's own OArchive only ever calls opened() (once, at construction) and
/// Write() on the stream it is given; Read/Seek/Tell/Size are unreachable
/// from this direction. ZozzStream carries read/seek/tell for IArchive below,
/// but this adapter never calls them — it stubs the same four members
/// zozz_internal.h's ConstMemoryStream stubs for the opposite reason.
class HostWriteStream : public ozz::io::Stream {
 public:
  explicit HostWriteStream(const ZozzStream& host) : host_(host) {}

  bool opened() const override { return host_.opened(host_.user) != 0; }

  /// ozz's own OArchive checks a short write only via
  /// `assert(size == sizeof(v))` (archive.h), which disappears under NDEBUG.
  /// Rather than ever reporting a short count back into that assert — an
  /// abort in a debug build, silent corruption in release — this always
  /// reports the full count and latches `failed_`, which every entry point
  /// below checks once the archive has finished writing.
  size_t Write(const void* buffer, size_t size) override {
    if (!failed_ && host_.write(host_.user, buffer, size) != size) {
      failed_ = true;
    }
    return size;
  }

  bool failed() const { return failed_; }

  size_t Read(void*, size_t) override { return 0; }
  int Seek(int, Origin) override { return -1; }
  int Tell() const override { return -1; }
  size_t Size() const override { return 0; }

 private:
  ZozzStream host_;
  bool failed_ = false;
};

/// Read-only adapter from a host ZozzStream onto ozz::io::Stream — the mirror
/// image of HostWriteStream above.
///
/// ozz's own IArchive checks a short read only via `assert(size ==
/// sizeof(v))` (archive.h), which disappears under NDEBUG just like the write
/// side's assert does. A host's `read` legitimately returns fewer bytes than
/// asked at the true end of its data, so rather than ever handing that short
/// count to ozz, this always reports the full count back, zero-fills
/// whatever the host did not supply, and latches `failed_` — the exact
/// technique zozz_internal.h's ConstMemoryStream uses for a memory-backed
/// archive, applied here to an arbitrary host-backed one.
class HostReadStream : public ozz::io::Stream {
 public:
  explicit HostReadStream(const ZozzStream& host) : host_(host) {}

  bool opened() const override { return host_.opened(host_.user) != 0; }

  size_t Read(void* buffer, size_t size) override {
    uint8_t* out = static_cast<uint8_t*>(buffer);
    size_t n = failed_ ? 0 : host_.read(host_.user, buffer, size);
    if (n > size) n = size;  // A host reporting more than it was asked for.
    if (n < size) {
      std::memset(out + n, 0, size - n);
      failed_ = true;
    }
    return size;
  }

  size_t Write(const void*, size_t) override { return 0; }

  /// The only caller is IArchive::TestTag<T>(), rewinding after a peek — see
  /// the tag-sniffing entry points below. A failed seek leaves the read
  /// position unknown, so it latches `failed_` exactly like a short read
  /// does, rather than letting the next read continue from an uncertain spot.
  int Seek(int offset, Origin origin) override {
    if (failed_) return -1;
    if (host_.seek(host_.user, offset, static_cast<ZozzSeekOrigin>(origin)) !=
        0) {
      failed_ = true;
      return -1;
    }
    return 0;
  }

  int Tell() const override { return failed_ ? -1 : host_.tell(host_.user); }

  size_t Size() const override { return 0; }

  bool failed() const { return failed_; }

 private:
  ZozzStream host_;
  bool failed_ = false;
};

bool ValidWriteStream(const ZozzStream* stream) {
  return stream != nullptr && stream->opened != nullptr &&
         stream->write != nullptr;
}

// Both of these read the parameter's bytes rather than its value — see
// RawEnum in zozz_internal.h. A host can pass any integer here.
// These take the raw integer, not ZozzEndianness. Passing the enum by value
// anywhere — even to a helper that means to validate it — is itself a load of
// the enum, and undefined when a host passed a value no enumerator names. It
// is converted once, with zozz::RawEnum, at the entry point that receives it,
// and travels as a number from there.
bool ValidEndianness(int32_t endianness) {
  return endianness == ZOZZ_ENDIANNESS_BIG ||
         endianness == ZOZZ_ENDIANNESS_LITTLE;
}

ozz::Endianness ToOzz(int32_t endianness) {
  return endianness == ZOZZ_ENDIANNESS_BIG ? ozz::kBigEndian
                                           : ozz::kLittleEndian;
}

/// The ZozzEndianness matching this platform's own native order — what the
/// file-convenience functions below pass, unconditionally, to reproduce the
/// behaviour every zozzOArchiveCreate call had before it took an explicit
/// ZozzEndianness.
int32_t NativeEndianness() {
  return ozz::GetNativeEndianness() == ozz::kBigEndian ? ZOZZ_ENDIANNESS_BIG
                                                        : ZOZZ_ENDIANNESS_LITTLE;
}

bool ValidReadStream(const ZozzStream* stream) {
  return stream != nullptr && stream->opened != nullptr &&
         stream->read != nullptr && stream->seek != nullptr &&
         stream->tell != nullptr;
}

int FileOpened(void* user) {
  return static_cast<ozz::io::File*>(user)->opened() ? 1 : 0;
}

size_t FileWrite(void* user, const void* data, size_t size) {
  return static_cast<ozz::io::File*>(user)->Write(data, size);
}

}  // namespace

struct ZozzOArchive {
  HostWriteStream stream;
  ozz::io::OArchive archive;

  ZozzOArchive(const ZozzStream& host, ozz::Endianness endianness)
      : stream(host), archive(&stream, endianness) {}
};

struct ZozzIArchive {
  HostReadStream stream;
  ozz::io::IArchive archive;

  explicit ZozzIArchive(const ZozzStream& host)
      : stream(host), archive(&stream) {}
};

namespace {

ZozzResult CreateOArchive(const ZozzStream* stream, int32_t endianness,
                          ZozzOArchive** out) {
  *out = nullptr;
  if (!ValidWriteStream(stream)) return ZOZZ_RESULT_INVALID_ARGUMENT;
  if (!ValidEndianness(endianness)) return ZOZZ_RESULT_INVALID_ARGUMENT;
  if (stream->opened(stream->user) == 0) return ZOZZ_RESULT_IO;

  ZozzOArchive* archive = zozz::New<ZozzOArchive>(*stream, ToOzz(endianness));
  if (archive == nullptr) return ZOZZ_RESULT_OUT_OF_MEMORY;

  *out = archive;
  return ZOZZ_RESULT_OK;
}

template <typename T>
ZozzResult SaveObject(ZozzOArchive* archive, const T& object) {
  if (archive == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  if (archive->stream.failed()) return ZOZZ_RESULT_IO;
  archive->archive << object;
  return archive->stream.failed() ? ZOZZ_RESULT_IO : ZOZZ_RESULT_OK;
}

/// Create + Save + Destroy over a file-backed stream, sharing the exact
/// write-tracking HostWriteStream gives the host-bridge path: a short fwrite
/// is caught here rather than reaching OArchive's own unchecked assert.
template <typename T>
ZozzResult SaveToFile(const char* path, const T& object) {
  if (path == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;

  ozz::io::File file(path, "wb");
  if (!file.opened()) return ZOZZ_RESULT_IO;

  const ZozzStream bridge = {&FileOpened, &FileWrite, nullptr,
                             nullptr,    nullptr,     &file};
  ZozzOArchive* archive = nullptr;
  ZozzResult result = CreateOArchive(&bridge, NativeEndianness(), &archive);
  if (result != ZOZZ_RESULT_OK) return result;

  result = SaveObject(archive, object);
  zozz::Delete(archive);
  return result;
}

/// Reads one tagged, versioned object: tests the tag first — turning a
/// wrong-type or non-ozz stream into ZOZZ_RESULT_BAD_FORMAT rather than a
/// parse of unrelated bytes, the same guarantee zozz::LoadTagged gives the
/// file/memory loaders — then parses, checking `failed()` at every step
/// since none of this throws.
template <typename T>
ZozzResult LoadTaggedObject(ZozzIArchive* archive, T* object) {
  if (archive == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  if (archive->stream.failed()) return ZOZZ_RESULT_IO;
  if (!archive->archive.TestTag<T>()) return ZOZZ_RESULT_BAD_FORMAT;
  if (archive->stream.failed()) return ZOZZ_RESULT_IO;
  archive->archive >> *object;
  return archive->stream.failed() ? ZOZZ_RESULT_IO : ZOZZ_RESULT_OK;
}

/// Shared shape of the five track loaders: allocate the handle, load into its
/// impl, unwind on any failure. Skeleton and animation each need an extra
/// post-parse sanity check (see zozzIArchiveLoadSkeleton/LoadAnimation below)
/// so they are not routed through this helper.
template <typename Handle>
ZozzResult LoadTrack(ZozzIArchive* archive, Handle** out) {
  if (out == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  *out = nullptr;
  Handle* handle = zozz::New<Handle>();
  if (handle == nullptr) return ZOZZ_RESULT_OUT_OF_MEMORY;

  const ZozzResult result = LoadTaggedObject(archive, &handle->impl);
  if (result != ZOZZ_RESULT_OK) {
    zozz::Delete(handle);
    return result;
  }
  *out = handle;
  return ZOZZ_RESULT_OK;
}

/// True if the next object in `archive` tags as a T, without consuming it.
/// Shared tail of the zozzIArchiveTest* entry points below.
template <typename T>
bool PeekTag(ZozzIArchive* archive) {
  if (archive == nullptr || archive->stream.failed()) return false;
  return archive->archive.TestTag<T>();
}

}  // namespace

extern "C" {

ZozzResult zozzOArchiveCreate(const ZozzStream* stream,
                              ZozzEndianness endianness, ZozzOArchive** out) {
  if (out == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  return CreateOArchive(stream, zozz::RawEnum(endianness), out);
}

void zozzOArchiveDestroy(ZozzOArchive* archive) { zozz::Delete(archive); }

ZozzResult zozzOArchiveSaveBinary(ZozzOArchive* archive, const void* data,
                                  size_t size) {
  if (archive == nullptr || (data == nullptr && size != 0)) {
    return ZOZZ_RESULT_INVALID_ARGUMENT;
  }
  if (archive->stream.failed()) return ZOZZ_RESULT_IO;
  archive->archive.SaveBinary(data, size);
  return archive->stream.failed() ? ZOZZ_RESULT_IO : ZOZZ_RESULT_OK;
}

ZozzResult zozzOArchiveSaveInt32(ZozzOArchive* archive, int32_t value) {
  if (archive == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  if (archive->stream.failed()) return ZOZZ_RESULT_IO;
  archive->archive << value;
  return archive->stream.failed() ? ZOZZ_RESULT_IO : ZOZZ_RESULT_OK;
}

ZozzResult zozzOArchiveSaveFloat(ZozzOArchive* archive, float value) {
  if (archive == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  if (value != value) return ZOZZ_RESULT_INVALID_ARGUMENT;  // NaN
  if (archive->stream.failed()) return ZOZZ_RESULT_IO;
  archive->archive << value;
  return archive->stream.failed() ? ZOZZ_RESULT_IO : ZOZZ_RESULT_OK;
}

ZozzResult zozzOArchiveSaveSkeleton(ZozzOArchive* archive,
                                    const ZozzSkeleton* skeleton) {
  if (skeleton == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  return SaveObject(archive, skeleton->impl);
}

ZozzResult zozzOArchiveSaveAnimation(ZozzOArchive* archive,
                                     const ZozzAnimation* animation) {
  if (animation == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  return SaveObject(archive, animation->impl);
}

ZozzResult zozzOArchiveSaveFloatTrack(ZozzOArchive* archive,
                                      const ZozzFloatTrack* track) {
  if (track == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  return SaveObject(archive, track->impl);
}

ZozzResult zozzOArchiveSaveFloat2Track(ZozzOArchive* archive,
                                       const ZozzFloat2Track* track) {
  if (track == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  return SaveObject(archive, track->impl);
}

ZozzResult zozzOArchiveSaveFloat3Track(ZozzOArchive* archive,
                                       const ZozzFloat3Track* track) {
  if (track == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  return SaveObject(archive, track->impl);
}

ZozzResult zozzOArchiveSaveFloat4Track(ZozzOArchive* archive,
                                       const ZozzFloat4Track* track) {
  if (track == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  return SaveObject(archive, track->impl);
}

ZozzResult zozzOArchiveSaveQuaternionTrack(ZozzOArchive* archive,
                                           const ZozzQuaternionTrack* track) {
  if (track == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  return SaveObject(archive, track->impl);
}

ZozzResult zozzIArchiveCreate(const ZozzStream* stream, ZozzIArchive** out) {
  if (out == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  *out = nullptr;
  if (!ValidReadStream(stream)) return ZOZZ_RESULT_INVALID_ARGUMENT;
  if (stream->opened(stream->user) == 0) return ZOZZ_RESULT_IO;

  ZozzIArchive* archive = zozz::New<ZozzIArchive>(*stream);
  if (archive == nullptr) return ZOZZ_RESULT_OUT_OF_MEMORY;

  *out = archive;
  return ZOZZ_RESULT_OK;
}

void zozzIArchiveDestroy(ZozzIArchive* archive) { zozz::Delete(archive); }

bool zozzIArchiveEndianSwap(const ZozzIArchive* archive) {
  return archive != nullptr && archive->archive.endian_swap();
}

ZozzResult zozzIArchiveLoadBinary(ZozzIArchive* archive, void* data,
                                  size_t size) {
  if (archive == nullptr || (data == nullptr && size != 0)) {
    return ZOZZ_RESULT_INVALID_ARGUMENT;
  }
  if (archive->stream.failed()) return ZOZZ_RESULT_IO;
  archive->archive.LoadBinary(data, size);
  return archive->stream.failed() ? ZOZZ_RESULT_IO : ZOZZ_RESULT_OK;
}

ZozzResult zozzIArchiveLoadInt32(ZozzIArchive* archive, int32_t* out) {
  if (archive == nullptr || out == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  *out = 0;
  if (archive->stream.failed()) return ZOZZ_RESULT_IO;
  archive->archive >> *out;
  return archive->stream.failed() ? ZOZZ_RESULT_IO : ZOZZ_RESULT_OK;
}

ZozzResult zozzIArchiveLoadFloat(ZozzIArchive* archive, float* out) {
  if (archive == nullptr || out == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  *out = 0.f;
  if (archive->stream.failed()) return ZOZZ_RESULT_IO;
  archive->archive >> *out;
  return archive->stream.failed() ? ZOZZ_RESULT_IO : ZOZZ_RESULT_OK;
}

ZozzResult zozzIArchiveLoadSkeleton(ZozzIArchive* archive,
                                    ZozzSkeleton** out) {
  if (out == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  *out = nullptr;
  ZozzSkeleton* skeleton = zozz::New<ZozzSkeleton>();
  if (skeleton == nullptr) return ZOZZ_RESULT_OUT_OF_MEMORY;

  ZozzResult result = LoadTaggedObject(archive, &skeleton->impl);
  if (result == ZOZZ_RESULT_OK) {
    result = zozz::ValidateSkeleton(skeleton->impl);
  }
  if (result != ZOZZ_RESULT_OK) {
    zozz::Delete(skeleton);
    return result;
  }
  *out = skeleton;
  return ZOZZ_RESULT_OK;
}

ZozzResult zozzIArchiveLoadAnimation(ZozzIArchive* archive,
                                     ZozzAnimation** out) {
  if (out == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  *out = nullptr;
  ZozzAnimation* animation = zozz::New<ZozzAnimation>();
  if (animation == nullptr) return ZOZZ_RESULT_OUT_OF_MEMORY;

  ZozzResult result = LoadTaggedObject(archive, &animation->impl);
  if (result == ZOZZ_RESULT_OK) {
    result = zozz::ValidateAnimation(animation->impl);
  }
  if (result != ZOZZ_RESULT_OK) {
    zozz::Delete(animation);
    return result;
  }
  *out = animation;
  return ZOZZ_RESULT_OK;
}

ZozzResult zozzIArchiveLoadFloatTrack(ZozzIArchive* archive,
                                      ZozzFloatTrack** out) {
  return LoadTrack(archive, out);
}

ZozzResult zozzIArchiveLoadFloat2Track(ZozzIArchive* archive,
                                       ZozzFloat2Track** out) {
  return LoadTrack(archive, out);
}

ZozzResult zozzIArchiveLoadFloat3Track(ZozzIArchive* archive,
                                       ZozzFloat3Track** out) {
  return LoadTrack(archive, out);
}

ZozzResult zozzIArchiveLoadFloat4Track(ZozzIArchive* archive,
                                       ZozzFloat4Track** out) {
  return LoadTrack(archive, out);
}

ZozzResult zozzIArchiveLoadQuaternionTrack(ZozzIArchive* archive,
                                           ZozzQuaternionTrack** out) {
  return LoadTrack(archive, out);
}

bool zozzIArchiveTestSkeleton(ZozzIArchive* archive) {
  return PeekTag<ozz::animation::Skeleton>(archive);
}

bool zozzIArchiveTestAnimation(ZozzIArchive* archive) {
  return PeekTag<ozz::animation::Animation>(archive);
}

bool zozzIArchiveTestFloatTrack(ZozzIArchive* archive) {
  return PeekTag<ozz::animation::FloatTrack>(archive);
}

bool zozzIArchiveTestFloat2Track(ZozzIArchive* archive) {
  return PeekTag<ozz::animation::Float2Track>(archive);
}

bool zozzIArchiveTestFloat3Track(ZozzIArchive* archive) {
  return PeekTag<ozz::animation::Float3Track>(archive);
}

bool zozzIArchiveTestFloat4Track(ZozzIArchive* archive) {
  return PeekTag<ozz::animation::Float4Track>(archive);
}

bool zozzIArchiveTestQuaternionTrack(ZozzIArchive* archive) {
  return PeekTag<ozz::animation::QuaternionTrack>(archive);
}

ZozzResult zozzSkeletonSaveFile(const ZozzSkeleton* skeleton,
                                const char* path) {
  if (skeleton == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  return SaveToFile(path, skeleton->impl);
}

ZozzResult zozzAnimationSaveFile(const ZozzAnimation* animation,
                                 const char* path) {
  if (animation == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  return SaveToFile(path, animation->impl);
}

ZozzResult zozzFloatTrackSaveFile(const ZozzFloatTrack* track,
                                  const char* path) {
  if (track == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  return SaveToFile(path, track->impl);
}

ZozzResult zozzFloat2TrackSaveFile(const ZozzFloat2Track* track,
                                   const char* path) {
  if (track == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  return SaveToFile(path, track->impl);
}

ZozzResult zozzFloat3TrackSaveFile(const ZozzFloat3Track* track,
                                   const char* path) {
  if (track == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  return SaveToFile(path, track->impl);
}

ZozzResult zozzFloat4TrackSaveFile(const ZozzFloat4Track* track,
                                   const char* path) {
  if (track == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  return SaveToFile(path, track->impl);
}

ZozzResult zozzQuaternionTrackSaveFile(const ZozzQuaternionTrack* track,
                                       const char* path) {
  if (track == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  return SaveToFile(path, track->impl);
}

}  // extern "C"
