//===----------------------------------------------------------------------===//
// zozz — implementation-private declarations shared by the ffi/*.cpp units.
//
// Not installed and not part of the ABI. Nothing here may appear in zozz.h.
//===----------------------------------------------------------------------===//

#ifndef ZOZZ_INTERNAL_H_
#define ZOZZ_INTERNAL_H_

#include <cstring>
#include <new>
#include <utility>

#include "ozz/animation/offline/raw_animation.h"
#include "ozz/animation/offline/raw_skeleton.h"
#include "ozz/animation/offline/raw_track.h"
#include "ozz/animation/offline/tools/import2ozz.h"
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
/// An enum parameter's bytes, rather than its value.
///
/// A C caller can put any integer through an enum parameter — `(ZozzLogLevel)99`
/// is a legal thing to write — and reading an enum object that holds a value no
/// enumerator names is undefined behaviour. Not theoretically: the obvious
/// `switch (level)` aborts under UBSan with "load of value 99, which is not
/// valid for type 'ZozzLogLevel'", which is the abort a host would get in a
/// sanitised build for passing exactly the value this ABI promises to reject
/// cleanly.
///
/// Copying the object representation into an integer is not a load of the enum,
/// so the value can be validated as what it really is: a number that arrived
/// from outside. Every entry point taking an enum by value goes through this
/// before it looks at it. The enum stays in the signature because it is the
/// documented interface — what it cannot be is trusted.
/// Taken by reference on purpose: copying the parameter would itself be a load
/// of the enum, which is the very thing this exists to avoid.
template <typename E>
int32_t RawEnum(const E& value) {
  static_assert(sizeof(E) == sizeof(int32_t),
                "an enum crossing this ABI must be int-sized: no enumerator is "
                "negative, so every compiler this ABI targets gives it int as "
                "its underlying type, and the byte copy below depends on it.");
  int32_t raw;
  std::memcpy(&raw, &value, sizeof raw);
  return raw;
}

constexpr int SoaBlocks(int num_joints) { return (num_joints + 3) / 4; }

//===----------------------------------------------------------------------===//
// Allocation
//
// ozz::New is `new (allocator->Allocate(...)) T(...)` with no null check, so a
// failed allocation is a placement-new at address zero rather than a
// recoverable error. These replacements check first, which is what makes the
// ZOZZ_RESULT_OUT_OF_MEMORY paths in this library reachable instead of decorative.
//===----------------------------------------------------------------------===//

template <typename T, typename... Args>
T* New(Args&&... args) {
  void* block =
      ozz::memory::default_allocator()->Allocate(sizeof(T), alignof(T));
  if (block == nullptr) return nullptr;
  return new (block) T(std::forward<Args>(args)...);
}

template <typename T>
void Delete(T* object) {
  if (object == nullptr) return;
  object->~T();
  ozz::memory::default_allocator()->Deallocate(object);
}

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

  /// True once any read or seek has gone past the end of the buffer.
  bool truncated() const { return truncated_; }

  /// Satisfies every request in full, zero-filling past the end and latching
  /// `truncated_`.
  ///
  /// A short read must never reach ozz. Its IArchive does not check reads:
  /// `operator>>` for a primitive is `Read(&v, sizeof(v))` followed by
  /// `assert(size == sizeof(v))`, and under NDEBUG that assert disappears —
  /// leaving `v` holding whatever was on the stack, with parsing continuing on
  /// garbage. A count read that way decides how much ozz then allocates.
  ///
  /// Zeros are the safe filler: a zeroed count is zero, so ozz's loops do
  /// nothing rather than run wild, and no partially-overwritten count can
  /// round upward. The loader rejects the archive on the flag afterwards.
  size_t Read(void* buffer, size_t size) override {
    uint8_t* out = static_cast<uint8_t*>(buffer);
    const size_t available =
        (data_ != nullptr && tell_ < size_) ? size_ - tell_ : 0;
    const size_t n = size < available ? size : available;

    if (n != 0) std::memcpy(out, data_ + tell_, n);
    if (n < size) {
      std::memset(out + n, 0, size - n);
      truncated_ = true;
    }

    // Advance by the requested amount, not the amount available, so Tell()
    // stays consistent with what the reader believes it consumed.
    tell_ += size;
    return size;
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
    if (target < 0) return -1;
    // Seeking beyond the end is permitted but recorded: a reader that skips
    // past the data it was promised has been handed a truncated archive just
    // as surely as one that read past it.
    if (target > static_cast<int64_t>(size_)) truncated_ = true;
    tell_ = static_cast<size_t>(target);
    return 0;
  }

  int Tell() const override { return static_cast<int>(tell_); }

  size_t Size() const override { return size_; }

 private:
  const uint8_t* data_;
  size_t size_;
  size_t tell_ = 0;
  bool truncated_ = false;
};

//===----------------------------------------------------------------------===//
// Archive loading
//===----------------------------------------------------------------------===//

/// Loads one tagged ozz object from a truncation-detecting stream.
///
/// Two checks bracket ozz's parser, because ozz performs neither in a release
/// build:
///
///   * the tag test, which turns a wrong-type or non-ozz input into a clean
///     error instead of a parse of unrelated bytes (ozz only asserts);
///   * the truncation flag, which catches an input that ran out mid-parse
///     (ozz only asserts on the short read).
template <typename T>
ZozzResult LoadTagged(ConstMemoryStream* stream, T* out) {
  if (!stream->opened()) return ZOZZ_RESULT_IO;
  ozz::io::IArchive archive(stream);
  if (!archive.TestTag<T>()) return ZOZZ_RESULT_BAD_FORMAT;
  if (stream->truncated()) return ZOZZ_RESULT_IO;
  archive >> *out;
  if (stream->truncated()) return ZOZZ_RESULT_IO;
  return ZOZZ_RESULT_OK;
}

/// Loads one tagged ozz object from a borrowed memory image.
template <typename T>
ZozzResult LoadFromMemory(const void* data, size_t size, T* out) {
  if (data == nullptr || size == 0) return ZOZZ_RESULT_INVALID_ARGUMENT;
  ConstMemoryStream stream(data, size);
  return LoadTagged(&stream, out);
}

/// Loads one tagged ozz object from a file path.
///
/// The file is read whole into memory and parsed through ConstMemoryStream
/// rather than handed to ozz's own File stream. That is deliberate: ozz's File
/// returns short reads at end-of-file, which is precisely the case its archive
/// reader fails to check. Buffering costs one allocation the size of the
/// archive — which is read in full regardless — and buys both paths the same
/// truncation guarantee.
template <typename T>
ZozzResult LoadFromFile(const char* path, T* out) {
  if (path == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;

  ozz::io::File file(path, "rb");
  if (!file.opened()) return ZOZZ_RESULT_FILE_NOT_FOUND;

  const size_t size = file.Size();
  if (size == 0) return ZOZZ_RESULT_BAD_FORMAT;

  ozz::memory::Allocator* allocator = ozz::memory::default_allocator();
  void* buffer = allocator->Allocate(size, 16);
  if (buffer == nullptr) return ZOZZ_RESULT_OUT_OF_MEMORY;

  const size_t read = file.Read(buffer, size);
  if (read != size) {
    allocator->Deallocate(buffer);
    return ZOZZ_RESULT_IO;
  }

  const ZozzResult result = LoadFromMemory(buffer, size, out);
  allocator->Deallocate(buffer);
  return result;
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

//===----------------------------------------------------------------------===//
// Post-parse sanity checks
//
// Defined once each, in zozz_skeleton.cpp and zozz_animation.cpp
// respectively, and shared here so every loader applies the same checks
// regardless of where the bytes came from: a file, a memory buffer, or a
// host-supplied ZozzIArchive (zozz_archive.cpp). Rejects an object that
// parsed without complaint but describes something ozz's own jobs would
// refuse — the shape a truncated or version-mismatched archive produces.
//===----------------------------------------------------------------------===//

ZozzResult ValidateSkeleton(const ozz::animation::Skeleton& skeleton);
ZozzResult ValidateAnimation(const ozz::animation::Animation& animation);

//===----------------------------------------------------------------------===//
// Flat/nested raw-skeleton conversion
//
// zozz_offline.cpp owns ZozzRawSkeleton's layout (a flat parent/name/rest
// list — see that file's module comment for why); zozz_gltf.cpp needs both
// conversion directions to sit an ozz::animation::offline::OzzImporter, which
// only knows the nested ozz::animation::offline::RawSkeleton tree, in front
// of the flat handle this ABI hands out everywhere else. Defined once, here,
// rather than duplicated.
//===----------------------------------------------------------------------===//

/// Depth-first flattening of a nested ozz RawSkeleton into a fresh flat
/// handle, in the same insertion order zozzSkeletonBuild documents.
ZozzResult BuildFlatSkeleton(const ozz::animation::offline::RawSkeleton& raw,
                             ZozzRawSkeleton** out);

/// The reverse: materialises `flat` into a nested ozz RawSkeleton — the shape
/// OzzImporter::Import(RawSkeleton*, NodeType) fills.
ZozzResult FlattenToNestedSkeleton(const ZozzRawSkeleton* flat,
                                   ozz::animation::offline::RawSkeleton* out);

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

/// The raw-animation handle also lives here rather than beside
/// zozzRawAnimationCreate in zozz_offline.cpp: zozz_optimizer.cpp (the
/// animation optimizer, additive builder and motion extractor) reads and
/// writes `impl` directly too, and a type only one translation unit can see
/// cannot be shared by simply forward-declaring the opaque tag from zozz.h.
struct ZozzRawAnimation {
  ozz::animation::offline::RawAnimation impl;
};

/// Raw-track handles, shared for the same reason: zozz_rawtrack.cpp builds
/// and optimizes them, zozz_optimizer.cpp's motion extractor reads and writes
/// a RawFloat3Track and a RawQuaternionTrack directly.
struct ZozzRawFloatTrack {
  ozz::animation::offline::RawFloatTrack impl;
};
struct ZozzRawFloat2Track {
  ozz::animation::offline::RawFloat2Track impl;
};
struct ZozzRawFloat3Track {
  ozz::animation::offline::RawFloat3Track impl;
};
struct ZozzRawFloat4Track {
  ozz::animation::offline::RawFloat4Track impl;
};
struct ZozzRawQuaternionTrack {
  ozz::animation::offline::RawQuaternionTrack impl;
};

/// An importer handle, shared between zozz_gltf.cpp (the generic OzzImporter
/// accessors and the host-implementable interface) and zozz_gltf_backend.cpp
/// (the concrete glTF backend): both construct one, only the former
/// dereferences it. `impl` is owned; deleted through this base pointer, which
/// works because ~OzzImporter is virtual.
struct ZozzImporter {
  ozz::animation::offline::OzzImporter* impl;
};

#endif  // ZOZZ_INTERNAL_H_
