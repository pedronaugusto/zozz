//===----------------------------------------------------------------------===//
// zozz — version reporting, result naming, the allocator seam, and log
// verbosity.
//===----------------------------------------------------------------------===//

#include <atomic>
#include <cstring>

#include "ozz/base/log.h"
#include "zozz_internal.h"

namespace {

//===----------------------------------------------------------------------===//
// Allocator seam
//===----------------------------------------------------------------------===//

/// ozz's allocator as it was before zozz interposed, so a block allocated
/// while no host is installed still reaches the allocator ozz shipped with —
/// and so zozzSetAllocator(NULL) returns to that one rather than guessing at
/// it.
ozz::memory::Allocator*& SavedDefault() {
  static ozz::memory::Allocator* saved = nullptr;
  return saved;
}

/// Adapts a host ZozzAllocator onto ozz's abstract allocator interface, and
/// occupies ozz's default-allocator slot for the whole process — forwarding to
/// SavedDefault() while no host is installed — so `live_` counts every
/// outstanding ozz block and not merely the host's. See Interpose().
class HostAllocator : public ozz::memory::Allocator {
 public:
  void Install(const ZozzAllocator& host) { host_ = host; }

  /// Sends subsequent allocations back to the allocator ozz shipped with.
  void Clear() { host_ = ZozzAllocator{}; }

  /// Whether a host allocator is installed. Not the same question as "is this
  /// object ozz's default allocator", which is true from the first moment of
  /// the process: only this says whether anything is behind it.
  bool hosted() const { return host_.allocate != nullptr; }

  /// The struct Install last received, verbatim — what zozzGetAllocator
  /// hands back.
  const ZozzAllocator& installed() const { return host_; }

  /// Whether `other` would dispatch to the same place as the installed one.
  /// The `user` pointer is part of that: two hosts sharing an entry point but
  /// not their state are two allocators.
  bool SameAs(const ZozzAllocator& other) const {
    return host_.allocate == other.allocate &&
           host_.deallocate == other.deallocate && host_.user == other.user;
  }

  /// Blocks handed out and not yet freed, by whichever allocator this adapter
  /// was forwarding to at the time. Atomic because the seam permits
  /// concurrent use of distinct handles: a plain counter would make the very
  /// contract this class documents unsound.
  size_t live() const { return live_.load(std::memory_order_acquire); }

  void* Allocate(size_t size, size_t alignment) override {
    void* block = hosted() ? host_.allocate(host_.user, size, alignment)
                           : SavedDefault()->Allocate(size, alignment);
    if (block != nullptr) live_.fetch_add(1, std::memory_order_release);
    return block;
  }

  void Deallocate(void* block) override {
    // A NULL free is well-formed and allocates nothing, so it must not count
    // down -- ozz frees NULL on paths that never allocated.
    if (block == nullptr) return;
    live_.fetch_sub(1, std::memory_order_release);
    // Routed by what is installed NOW, not by what produced the block --
    // sound only because zozzSetAllocator refuses to exchange one for the
    // other while live() is non-zero. The two rules together are the
    // invariant: every outstanding block was produced by the allocator this
    // adapter currently forwards to.
    if (hosted()) {
      host_.deallocate(host_.user, block);
    } else {
      SavedDefault()->Deallocate(block);
    }
  }

 private:
  ZozzAllocator host_ = {};
  std::atomic<size_t> live_{0};
};

// Function-local static, first constructed by the interposition below, which
// runs during static initialisation: the adapter is in ozz's slot before any
// handle can exist.
HostAllocator& Host() {
  static HostAllocator instance;
  return instance;
}

/// Puts the adapter in ozz's default-allocator slot for the whole process, so
/// live() counts every outstanding ozz block and not merely the host's. Were
/// ozz left on its own allocator until the first zozzSetAllocator, the blocks
/// it handed out would be invisible: the guard would read zero, allow the
/// install, and their frees would land on an allocator that never made them.
/// Static-init safe: ozz's slot is constant-initialised, nothing allocates.
void Interpose() {
  ozz::memory::Allocator* previous = ozz::memory::default_allocator();
  // Only the first interposition records anything: running twice must still
  // remember the allocator ozz shipped with, not this adapter. Recorded
  // before the slot is taken, so the adapter can never forward through a null
  // pointer.
  if (SavedDefault() == nullptr && previous != &Host()) {
    SavedDefault() = previous;
  }
  ozz::memory::SetDefaulAllocator(&Host());
}

/// Interposes during static initialisation — before main, and before any
/// handle can exist. Nothing reads this object; its constructor is the point.
struct Interposer {
  Interposer() { Interpose(); }
};
const Interposer g_interposer;

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
    case ZOZZ_RESULT_ALLOCATOR_IN_USE:
      return "allocator in use";
  }
  return "unknown result";
}

ZozzResult zozzSetAllocator(const ZozzAllocator* alloc) {
  // Idempotent, and repeated here rather than left to static initialisation
  // alone: a C++ host may have pointed ozz at an allocator of its own in the
  // meantime, and this entry point promises that what it accepts is what ozz
  // allocates through.
  Interpose();

  // Every path that changes where a free lands asks the same question first:
  // is anything outstanding that this allocator would have to free? A call
  // that leaves the effective allocator exactly where it was changes nothing,
  // and it is the one case allowed to pass with blocks live: reinstalling the
  // identical struct, or resetting to ozz's own while no host is installed.
  const bool unchanged = alloc == nullptr
                             ? !Host().hosted()
                             : (Host().hosted() && Host().SameAs(*alloc));
  if (!unchanged && Host().live() != 0) return ZOZZ_RESULT_ALLOCATOR_IN_USE;

  if (alloc == nullptr) {
    // The adapter keeps ozz's default-allocator slot; only what it forwards
    // to changes, so blocks made from here on stay counted.
    Host().Clear();
    return ZOZZ_RESULT_OK;
  }

  if (alloc->allocate == nullptr || alloc->deallocate == nullptr) {
    return ZOZZ_RESULT_INVALID_ARGUMENT;
  }

  Host().Install(*alloc);
  return ZOZZ_RESULT_OK;
}

ZozzResult zozzGetAllocator(ZozzAllocator* out, bool* installed) {
  if (out == nullptr || installed == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  *out = ZozzAllocator{};
  *installed = false;

  // Whether a host is installed, not whether the adapter is ozz's default
  // allocator -- it always is. zozzSetAllocator(NULL), or never having called
  // zozzSetAllocator at all, leaves the adapter forwarding to ozz's own
  // allocator, in which case there is no ZozzAllocator to report.
  if (Host().hosted()) {
    *out = Host().installed();
    *installed = true;
  }
  return ZOZZ_RESULT_OK;
}

size_t zozzAllocatorLiveBlocks(void) { return Host().live(); }

ZozzResult zozzSetLogLevel(ZozzLogLevel level) {
  // Reads the parameter's bytes, not its value: a C caller can pass any int
  // through this parameter (`(ZozzLogLevel)99` is legal), and reading an enum
  // object holding a value no enumerator names is undefined behaviour — a
  // `switch (level)` aborts under UBSan for exactly the value this ABI must
  // reject cleanly. Copying the bits into an integer sidesteps that load, so
  // the value can be validated as the untrusted number it actually is.
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
