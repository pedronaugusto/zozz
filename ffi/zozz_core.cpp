//===----------------------------------------------------------------------===//
// zozz — version reporting, result naming, and the allocator seam.
//===----------------------------------------------------------------------===//

#include "zozz_internal.h"

namespace {

//===----------------------------------------------------------------------===//
// Allocator seam
//===----------------------------------------------------------------------===//

/// Adapts a host ZozzAllocator onto ozz's abstract allocator interface.
class HostAllocator : public ozz::memory::Allocator {
 public:
  void Install(const ZozzAllocator& host) { host_ = host; }

  void* Allocate(size_t size, size_t alignment) override {
    return host_.allocate(host_.user, size, alignment);
  }

  void Deallocate(void* block) override {
    host_.deallocate(host_.user, block);
  }

 private:
  ZozzAllocator host_ = {};
};

// Function-local statics: constructed on first use, so there is no static
// initialisation order dependency against ozz's own default allocator.
HostAllocator& Host() {
  static HostAllocator instance;
  return instance;
}

/// ozz's allocator as it was before zozz first replaced it, so NULL can
/// restore the original rather than guessing at it.
ozz::memory::Allocator*& SavedDefault() {
  static ozz::memory::Allocator* saved = nullptr;
  return saved;
}

}  // namespace

extern "C" {

uint32_t zozzVersion(void) {
  return (static_cast<uint32_t>(ZOZZ_VERSION_MAJOR) << 16) |
         (static_cast<uint32_t>(ZOZZ_VERSION_MINOR) << 8) |
         static_cast<uint32_t>(ZOZZ_VERSION_PATCH);
}

uint32_t zozzOzzVersion(void) {
  // Pinned in UPSTREAM.md; bump both together when re-vendoring.
  return (0u << 16) | (17u << 8) | 0u;
}

const char* zozzResultName(ZozzResult result) {
  switch (result) {
    case ZOZZ_OK:
      return "ok";
    case ZOZZ_ERR_FILE_NOT_FOUND:
      return "file not found";
    case ZOZZ_ERR_IO:
      return "io error";
    case ZOZZ_ERR_BAD_FORMAT:
      return "bad format";
    case ZOZZ_ERR_OUT_OF_MEMORY:
      return "out of memory";
    case ZOZZ_ERR_INVALID_ARGUMENT:
      return "invalid argument";
    case ZOZZ_ERR_JOB_INVALID:
      return "job invalid";
    case ZOZZ_ERR_BUFFER_TOO_SMALL:
      return "buffer too small";
    case ZOZZ_ERR_SKELETON_MISMATCH:
      return "skeleton mismatch";
    case ZOZZ_ERR_INVALID_DATA:
      return "invalid data";
  }
  return "unknown result";
}

ZozzResult zozzSetAllocator(const ZozzAllocator* alloc) {
  if (alloc == nullptr) {
    if (SavedDefault() != nullptr) {
      ozz::memory::SetDefaulAllocator(SavedDefault());
      SavedDefault() = nullptr;
    }
    return ZOZZ_OK;
  }

  if (alloc->allocate == nullptr || alloc->deallocate == nullptr) {
    return ZOZZ_ERR_INVALID_ARGUMENT;
  }

  Host().Install(*alloc);
  ozz::memory::Allocator* previous = ozz::memory::SetDefaulAllocator(&Host());
  // Only record the first swap: swapping twice must still restore the
  // allocator ozz shipped with, not our own adapter.
  if (SavedDefault() == nullptr && previous != &Host()) {
    SavedDefault() = previous;
  }
  return ZOZZ_OK;
}

}  // extern "C"
