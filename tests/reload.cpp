//===----------------------------------------------------------------------===//
// zozz — a refused load into an ozz object that held something. See
// tests/reload.h.
//===----------------------------------------------------------------------===//

#include "reload.h"

#include "allocation.h"
#include "ozz/animation/runtime/animation.h"
#include "ozz/animation/runtime/skeleton.h"
#include "ozz/animation/runtime/track.h"
#include "ozz/base/io/archive.h"
#include "ozz/base/io/stream.h"

namespace {

/// Loads `size` bytes at `data` into `object`; whether ozz refused them.
template <typename Object>
bool LoadInto(Object& object, const void* data, size_t size) {
  ozz::io::MemoryStream stream;
  if (stream.Write(data, size) != size) return false;
  stream.Seek(0, ozz::io::Stream::kSet);
  ozz::io::IArchive in(&stream);
  in >> object;
  return in.refused();
}

template <typename Object, typename Size>
long Reload(const void* held, size_t held_size, const void* refused,
            size_t refused_size, Size size) {
  Object object;
  if (LoadInto(object, held, held_size) || size(object) == 0) return -1;
  if (!LoadInto(object, refused, refused_size)) return -1;
  return static_cast<long>(size(object));
}

}  // namespace

extern "C" {

long zozzTestReloadRefused(int object, const void* held, size_t held_size,
                           const void* refused, size_t refused_size) {
  switch (object) {
    case ZOZZ_TEST_SKELETON:
      return Reload<ozz::animation::Skeleton>(
          held, held_size, refused, refused_size,
          [](const ozz::animation::Skeleton& s) { return s.num_joints(); });
    case ZOZZ_TEST_ANIMATION:
      return Reload<ozz::animation::Animation>(
          held, held_size, refused, refused_size,
          [](const ozz::animation::Animation& a) {
            return a.timepoints().size();
          });
    default:
      return Reload<ozz::animation::FloatTrack>(
          held, held_size, refused, refused_size,
          [](const ozz::animation::FloatTrack& t) { return t.ratios().size(); });
  }
}

}  // extern "C"
