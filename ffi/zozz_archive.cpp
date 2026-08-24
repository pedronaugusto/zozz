//===----------------------------------------------------------------------===//
// zozz — the write-side stream bridge, and the OArchive entry points.
//===----------------------------------------------------------------------===//

#include "zozz_internal.h"
#include "zozz_track_types.h"

namespace {

/// Write-only adapter from a host ZozzStream onto ozz::io::Stream.
///
/// ozz's own OArchive only ever calls opened() (once, at construction) and
/// Write() on the stream it is given; Read/Seek/Tell/Size are unreachable
/// from this direction and stubbed the same way zozz_internal.h's
/// ConstMemoryStream stubs the half of Stream ITS direction never uses.
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

bool ValidStream(const ZozzStream* stream) {
  return stream != nullptr && stream->opened != nullptr &&
         stream->write != nullptr;
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

  explicit ZozzOArchive(const ZozzStream& host)
      : stream(host), archive(&stream) {}
};

namespace {

ZozzResult CreateArchive(const ZozzStream* stream, ZozzOArchive** out) {
  *out = nullptr;
  if (!ValidStream(stream)) return ZOZZ_RESULT_INVALID_ARGUMENT;
  if (stream->opened(stream->user) == 0) return ZOZZ_RESULT_IO;

  ZozzOArchive* archive = zozz::New<ZozzOArchive>(*stream);
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

  const ZozzStream bridge = {&FileOpened, &FileWrite, &file};
  ZozzOArchive* archive = nullptr;
  ZozzResult result = CreateArchive(&bridge, &archive);
  if (result != ZOZZ_RESULT_OK) return result;

  result = SaveObject(archive, object);
  zozz::Delete(archive);
  return result;
}

}  // namespace

extern "C" {

ZozzResult zozzOArchiveCreate(const ZozzStream* stream, ZozzOArchive** out) {
  if (out == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  return CreateArchive(stream, out);
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
