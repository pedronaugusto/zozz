//===----------------------------------------------------------------------===//
// zozz — version reporting, result naming, the allocator seam, and log
// verbosity.
//===----------------------------------------------------------------------===//

#include <cstring>

#include "ozz/base/log.h"
#include "zozz_internal.h"

namespace {

//===----------------------------------------------------------------------===//
// Allocator seam
//===----------------------------------------------------------------------===//

/// Adapts a host ZozzAllocator onto ozz's abstract allocator interface.
class HostAllocator : public ozz::memory::Allocator {
 public:
  void Install(const ZozzAllocator& host) { host_ = host; }

  /// The struct Install last received, verbatim — what zozzGetAllocator
  /// hands back.
  const ZozzAllocator& installed() const { return host_; }

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
    case ZOZZ_RESULT_OK:
      return "ok";
    case ZOZZ_RESULT_FILE_NOT_FOUND:
      return "file not found";
    case ZOZZ_RESULT_IO:
      return "io error";
    case ZOZZ_RESULT_BAD_FORMAT:
      return "bad format";
    case ZOZZ_RESULT_OUT_OF_MEMORY:
      return "out of memory";
    case ZOZZ_RESULT_INVALID_ARGUMENT:
      return "invalid argument";
    case ZOZZ_RESULT_JOB_INVALID:
      return "job invalid";
    case ZOZZ_RESULT_BUFFER_TOO_SMALL:
      return "buffer too small";
    case ZOZZ_RESULT_SKELETON_MISMATCH:
      return "skeleton mismatch";
    case ZOZZ_RESULT_INVALID_DATA:
      return "invalid data";
    case ZOZZ_RESULT_UNSUPPORTED:
      return "unsupported";
  }
  return "unknown result";
}

ZozzResult zozzSetAllocator(const ZozzAllocator* alloc) {
  if (alloc == nullptr) {
    if (SavedDefault() != nullptr) {
      ozz::memory::SetDefaulAllocator(SavedDefault());
      SavedDefault() = nullptr;
    }
    return ZOZZ_RESULT_OK;
  }

  if (alloc->allocate == nullptr || alloc->deallocate == nullptr) {
    return ZOZZ_RESULT_INVALID_ARGUMENT;
  }

  Host().Install(*alloc);
  ozz::memory::Allocator* previous = ozz::memory::SetDefaulAllocator(&Host());
  // Only record the first swap: swapping twice must still restore the
  // allocator ozz shipped with, not our own adapter.
  if (SavedDefault() == nullptr && previous != &Host()) {
    SavedDefault() = previous;
  }
  return ZOZZ_RESULT_OK;
}

ZozzResult zozzGetAllocator(ZozzAllocator* out, bool* installed) {
  if (out == nullptr || installed == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  *out = ZozzAllocator{};
  *installed = false;

  // The installed adapter IS the currently active allocator only while it is
  // the one ozz is actually pointed at: zozzSetAllocator(NULL) or never
  // having called zozzSetAllocator at all both leave ozz pointed at its own
  // default instead, in which case there is no ZozzAllocator to report.
  if (ozz::memory::default_allocator() == &Host()) {
    *out = Host().installed();
    *installed = true;
  }
  return ZOZZ_RESULT_OK;
}

ZozzResult zozzSetLogLevel(ZozzLogLevel level) {
  // Read the parameter's bytes, not its value.
  //
  // A C caller can put any int through this parameter — `(ZozzLogLevel)99` is
  // a legal thing to write — and reading an enum object holding a value no
  // enumerator names is undefined behaviour. It is not a theoretical one: the
  // obvious `switch (level)` aborts under UBSan with "load of value 99, which
  // is not valid for type 'ZozzLogLevel'", which is exactly the abort a host
  // would get in a sanitised build for passing a value this ABI is supposed
  // to reject cleanly.
  //
  // Copying the object representation into an integer is not a load of the
  // enum, so the value can be validated as what it really is: a number that
  // arrived from outside. The enum stays in the signature because it is the
  // documented interface — what it cannot be is trusted.
  const int32_t raw = zozz::RawEnum(level);
  switch (raw) {
    case ZOZZ_LOG_LEVEL_SILENT:
    case ZOZZ_LOG_LEVEL_STANDARD:
    case ZOZZ_LOG_LEVEL_VERBOSE:
      ozz::log::SetLevel(static_cast<ozz::log::Level>(raw));
      return ZOZZ_RESULT_OK;
  }
  return ZOZZ_RESULT_INVALID_ARGUMENT;
}

ZozzLogLevel zozzGetLogLevel(void) {
  return static_cast<ZozzLogLevel>(ozz::log::GetLevel());
}

}  // extern "C"
