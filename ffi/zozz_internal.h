//===----------------------------------------------------------------------===//
// zozz — implementation-private declarations shared by the ffi/*.cpp units.
//
// Not installed and not part of the ABI. Nothing here may appear in zozz.h.
//===----------------------------------------------------------------------===//

#ifndef ZOZZ_INTERNAL_H_
#define ZOZZ_INTERNAL_H_

#include <cstring>

#include "ozz/animation/runtime/animation.h"
#include "ozz/animation/runtime/sampling_job.h"
#include "ozz/animation/runtime/skeleton.h"
#include "ozz/base/io/archive.h"
#include "ozz/base/io/stream.h"
#include "ozz/base/maths/soa_transform.h"
#include "ozz/base/memory/allocator.h"
#include "zozz.h"

namespace zozz {

//===----------------------------------------------------------------------===//
// Handle definitions
//
// The C header forward-declares these as opaque tags; defining them as real
// C++ types here means every accessor is statically typed. No reinterpret_cast
// crosses the boundary, so a handle mix-up is a compile error rather than
// memory corruption. This is the main structural departure from bindings that
// cast void* at every entry point.
//===----------------------------------------------------------------------===//

/// Largest joint count zozz will accept from an archive. Mirrors ozz's own
/// hard limit; used to reject a truncated or hostile file before it is
/// interpreted as a huge allocation.
constexpr int kMaxJoints = ozz::animation::Skeleton::kMaxJoints;

/// Number of SoA blocks needed for `num_joints` joints.
constexpr int SoaBlocks(int num_joints) { return (num_joints + 3) / 4; }

//===----------------------------------------------------------------------===//
// Read-only memory stream
//
// ozz ships MemoryStream, but it is read/write and would require copying the
// caller's buffer into it before parsing. Loading from memory is the common
// case for a packed asset, so zozz provides a borrowing, zero-copy stream.
//===----------------------------------------------------------------------===//

class ConstMemoryStream : public ozz::io::Stream {
 public:
  ConstMemoryStream(const void* data, size_t size)
      : data_(static_cast<const uint8_t*>(data)), size_(size), tell_(0) {}

  bool opened() const override { return data_ != nullptr; }

  size_t Read(void* buffer, size_t size) override {
    if (!data_ || tell_ > size_) return 0;
    const size_t remaining = size_ - tell_;
    const size_t n = size < remaining ? size : remaining;
    std::memcpy(buffer, data_ + tell_, n);
    tell_ += n;
    return n;
  }

  // Read-only: a write is a no-op reporting zero bytes stored.
  size_t Write(const void*, size_t) override { return 0; }

  int Seek(int offset, Origin origin) override {
    size_t origin_base = 0;
    switch (origin) {
      case kCurrent:
        origin_base = tell_;
        break;
      case kEnd:
        origin_base = size_;
        break;
      case kSet:
        origin_base = 0;
        break;
      default:
        return -1;
    }
    // Compute in a signed wide type so a negative offset past the start is
    // rejected rather than wrapping into a huge size_t.
    const int64_t target = static_cast<int64_t>(origin_base) + offset;
    if (target < 0 || target > static_cast<int64_t>(size_)) return -1;
    tell_ = static_cast<size_t>(target);
    return 0;
  }

  int Tell() const override { return static_cast<int>(tell_); }

  size_t Size() const override { return size_; }

 private:
  const uint8_t* data_;
  size_t size_;
  size_t tell_;
};

//===----------------------------------------------------------------------===//
// Archive loading
//===----------------------------------------------------------------------===//

/// Loads one tagged ozz object from an open stream.
///
/// The tag test is what makes a wrong-type or non-ozz file a clean error:
/// ozz's own `operator>>` only asserts on a tag mismatch, which is a no-op in
/// a release build and would then parse garbage.
template <typename T>
ZozzResult LoadTagged(ozz::io::Stream* stream, T* out) {
  if (!stream->opened()) return ZOZZ_ERR_IO;
  ozz::io::IArchive archive(stream);
  if (!archive.TestTag<T>()) return ZOZZ_ERR_BAD_FORMAT;
  archive >> *out;
  return ZOZZ_OK;
}

/// Loads one tagged ozz object from a file path.
template <typename T>
ZozzResult LoadFromFile(const char* path, T* out) {
  if (path == nullptr) return ZOZZ_ERR_INVALID_ARGUMENT;
  ozz::io::File file(path, "rb");
  if (!file.opened()) return ZOZZ_ERR_FILE_NOT_FOUND;
  return LoadTagged(&file, out);
}

/// Loads one tagged ozz object from a borrowed memory image.
template <typename T>
ZozzResult LoadFromMemory(const void* data, size_t size, T* out) {
  if (data == nullptr || size == 0) return ZOZZ_ERR_INVALID_ARGUMENT;
  ConstMemoryStream stream(data, size);
  return LoadTagged(&stream, out);
}

//===----------------------------------------------------------------------===//
// SoA <-> AoS conversion
//
// Defined once in zozz_pose.cpp and shared, so the transpose exists in exactly
// one place regardless of which entry point needs it.
//===----------------------------------------------------------------------===//

/// Transposes `num_joints` joints from SoA blocks into AoS transforms.
void SoaToAos(const ozz::math::SoaTransform* soa, ZozzTransform* aos,
              int num_joints);

/// Transposes `num_joints` AoS transforms into SoA blocks, padding any
/// trailing partial block with identity.
void AosToSoa(const ZozzTransform* aos, ozz::math::SoaTransform* soa,
              int num_joints);

}  // namespace zozz

//===----------------------------------------------------------------------===//
// Handle types (global namespace — they must match the C tag names)
//===----------------------------------------------------------------------===//

struct ZozzSkeleton {
  ozz::animation::Skeleton impl;
};

struct ZozzAnimation {
  ozz::animation::Animation impl;
};

struct ZozzSamplingContext {
  ozz::animation::SamplingJob::Context impl;
};

struct ZozzSoaPose {
  ozz::math::SoaTransform* data;
  int num_joints;
  int num_soa_joints;
};

#endif  // ZOZZ_INTERNAL_H_
