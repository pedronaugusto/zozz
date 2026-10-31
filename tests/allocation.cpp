//===----------------------------------------------------------------------===//
// zozz — ozz's own allocation sites, driven with an allocation refused. See
// tests/allocation.h.
//===----------------------------------------------------------------------===//

#include "allocation.h"

#include <cstddef>
#include <cstdint>
#include <cstring>
#include <ostream>
#include <vector>

#include "ozz/animation/offline/animation_builder.h"
#include "ozz/animation/offline/raw_animation.h"
#include "ozz/animation/offline/raw_skeleton.h"
#include "ozz/animation/offline/raw_track.h"
#include "ozz/animation/offline/skeleton_builder.h"
#include "ozz/animation/offline/track_builder.h"
#include "ozz/animation/runtime/animation.h"
#include "ozz/animation/runtime/skeleton.h"
#include "ozz/animation/runtime/track.h"
#include "ozz/base/io/archive.h"
#include "ozz/base/io/stream.h"
#include "ozz/base/log.h"
#include "ozz/base/maths/soa_transform.h"
#include "ozz/base/maths/transform.h"
#include "ozz/base/memory/allocator.h"
#include "ozz/base/memory/unique_ptr.h"

namespace {

using ozz::animation::Animation;
using ozz::animation::FloatTrack;
using ozz::animation::Skeleton;
using ozz::animation::offline::AnimationBuilder;
using ozz::animation::offline::RawAnimation;
using ozz::animation::offline::RawFloatTrack;
using ozz::animation::offline::RawSkeleton;
using ozz::animation::offline::SkeletonBuilder;
using ozz::animation::offline::TrackBuilder;

/// Installed as ozz's allocator for its lifetime, it passes every allocation
/// on to the one it replaced except those it is told to refuse: the one
/// numbered `refuse_index`, the first of exactly `refuse_size` bytes at
/// `refuse_alignment`, or all of them. It notes the number of the last
/// allocation made at `watch_alignment`.
class Refusing : public ozz::memory::Allocator {
 public:
  Refusing() : next_(ozz::memory::SetDefaulAllocator(this)) {}
  ~Refusing() override { ozz::memory::SetDefaulAllocator(next_); }
  Refusing(const Refusing&) = delete;
  Refusing& operator=(const Refusing&) = delete;

  void* Allocate(size_t _size, size_t _alignment) override {
    const size_t index = count_++;
    if (_alignment == watch_alignment) last_watched_ = index;
    bool refuse = refuse_all || index == refuse_index;
    if (!refused_sized_ && _size == refuse_size &&
        _alignment == refuse_alignment) {
      refused_sized_ = true;
      refuse = true;
    }
    return refuse ? nullptr : next_->Allocate(_size, _alignment);
  }
  void Deallocate(void* _block) override { next_->Deallocate(_block); }

  size_t last_watched() const { return last_watched_; }

  size_t refuse_index = SIZE_MAX;
  size_t refuse_size = 0;
  size_t refuse_alignment = 0;
  size_t watch_alignment = 0;
  bool refuse_all = false;

 private:
  ozz::memory::Allocator* next_;
  size_t count_ = 0;
  size_t last_watched_ = SIZE_MAX;
  bool refused_sized_ = false;
};

RawSkeleton TwoJoints() {
  RawSkeleton raw;
  raw.roots.resize(1);
  raw.roots[0].name = "root";
  raw.roots[0].transform = ozz::math::Transform::identity();
  raw.roots[0].children.resize(1);
  raw.roots[0].children[0].name = "tip";
  raw.roots[0].children[0].transform = ozz::math::Transform::identity();
  return raw;
}

RawAnimation OneTrack() {
  RawAnimation raw;
  raw.duration = 1.f;
  raw.tracks.resize(1);
  raw.tracks[0].translations.push_back({0.f, ozz::math::Float3::zero()});
  raw.tracks[0].translations.push_back({1.f, ozz::math::Float3::x_axis()});
  return raw;
}

RawFloatTrack TwoKeys() {
  using ozz::animation::offline::RawTrackInterpolation;
  RawFloatTrack raw;
  raw.keyframes.push_back({RawTrackInterpolation::kLinear, 0.f, 0.f});
  raw.keyframes.push_back({RawTrackInterpolation::kLinear, 1.f, 1.f});
  return raw;
}

/// Runs `builder` over `raw` with `configure` applied to a Refusing installed
/// around that call alone; `watched` receives its last_watched().
template <typename Object, typename Raw, typename Builder, typename Configure>
ozz::unique_ptr<Object> BuildWith(const Raw& raw, const Builder& builder,
                                  Configure configure, size_t* watched) {
  Refusing refusing;
  configure(refusing);
  ozz::unique_ptr<Object> built = builder(raw);
  *watched = refusing.last_watched();
  return built;
}

/// Builds `object` under `configure`. 1 when the builder returned null.
template <typename Configure>
int Build(int object, Configure configure, size_t* watched) {
  switch (object) {
    case ZOZZ_TEST_SKELETON:
      return BuildWith<Skeleton>(TwoJoints(), SkeletonBuilder(), configure,
                                 watched)
                 ? 0
                 : 1;
    case ZOZZ_TEST_ANIMATION:
      return BuildWith<Animation>(OneTrack(), AnimationBuilder(), configure,
                                  watched)
                 ? 0
                 : 1;
    default:
      return BuildWith<FloatTrack>(TwoKeys(), TrackBuilder(), configure, watched)
                 ? 0
                 : 1;
  }
}

/// Saves `object` built normally, then loads it back with every allocation
/// refused; `empty` says whether the loaded object holds nothing.
template <typename Object, typename Raw, typename Builder, typename Empty>
int LoadWith(const Raw& raw, const Builder& builder, Empty empty) {
  const ozz::unique_ptr<Object> built = builder(raw);
  if (!built) return 0;
  ozz::io::MemoryStream stream;
  {
    ozz::io::OArchive out(&stream);
    out << *built;
  }
  stream.Seek(0, ozz::io::Stream::kSet);
  Object loaded;
  {
    ozz::io::IArchive in(&stream);
    Refusing refusing;
    refusing.refuse_all = true;
    in >> loaded;
  }
  return empty(loaded) ? 1 : 0;
}

}  // namespace

extern "C" {

int zozzTestBuildRefusingNew(int object) {
  size_t watched = 0;
  const size_t size = object == ZOZZ_TEST_SKELETON    ? sizeof(Skeleton)
                      : object == ZOZZ_TEST_ANIMATION ? sizeof(Animation)
                                                      : sizeof(FloatTrack);
  const size_t alignment = object == ZOZZ_TEST_SKELETON    ? alignof(Skeleton)
                           : object == ZOZZ_TEST_ANIMATION ? alignof(Animation)
                                                           : alignof(FloatTrack);
  return Build(
      object,
      [&](Refusing& refusing) {
        refusing.refuse_size = size;
        refusing.refuse_alignment = alignment;
      },
      &watched);
}

int zozzTestBuildRefusingBuffer(int object) {
  // The alignment each Allocate asks for (skeleton.cc, animation.cc,
  // track.cc); containers the builder fills afterwards may ask too, but not
  // after the buffer at this one.
  const size_t alignment = object == ZOZZ_TEST_SKELETON
                               ? alignof(ozz::math::SoaTransform)
                               : alignof(float);
  size_t buffer = SIZE_MAX;
  const auto watch = [&](Refusing& refusing) {
    refusing.watch_alignment = alignment;
  };
  if (Build(object, watch, &buffer) != 0 || buffer == SIZE_MAX) return 0;
  size_t watched = 0;
  return Build(
      object, [&](Refusing& refusing) { refusing.refuse_index = buffer; },
      &watched);
}

int zozzTestLoadRefusingAll(int object) {
  switch (object) {
    case ZOZZ_TEST_SKELETON:
      return LoadWith<Skeleton>(TwoJoints(), SkeletonBuilder(),
                                [](const Skeleton& s) {
                                  return s.num_joints() == 0;
                                });
    case ZOZZ_TEST_ANIMATION:
      return LoadWith<Animation>(OneTrack(), AnimationBuilder(),
                                 [](const Animation& a) {
                                   return a.num_tracks() == 0;
                                 });
    default:
      return LoadWith<FloatTrack>(TwoKeys(), TrackBuilder(),
                                  [](const FloatTrack& t) {
                                    return t.ratios().empty();
                                  });
  }
}

int zozzTestLogRefusingAll(void) {
  const ozz::log::Level level = ozz::log::SetLevel(ozz::log::kSilent);
  {
    Refusing refusing;
    refusing.refuse_all = true;
    ozz::log::Log() << "a suppressed line" << std::endl;
  }
  ozz::log::SetLevel(level);
  return 1;
}

int zozzTestStreamRefusingGrowth(void) {
  ozz::io::MemoryStream stream;
  const char first[16] = {1};
  if (stream.Write(first, sizeof(first)) != sizeof(first)) return 0;
  // Past what the first write allocated (the increment is private to ozz,
  // 16 KiB in stream.cc), so the stream must grow.
  const size_t more = size_t{1} << 20;
  const std::vector<char> second(more);
  size_t written = 0;
  {
    Refusing refusing;
    refusing.refuse_all = true;
    written = stream.Write(second.data(), more);
  }
  char back[sizeof(first)] = {};
  stream.Seek(0, ozz::io::Stream::kSet);
  const bool kept = stream.Read(back, sizeof(back)) == sizeof(back) &&
                    std::memcmp(back, first, sizeof(first)) == 0;
  return written == 0 && kept && stream.Size() == sizeof(first) ? 1 : 0;
}

int zozzTestBuildEmptySkeleton(void) {
  const ozz::unique_ptr<Skeleton> built = SkeletonBuilder()(RawSkeleton());
  return built && built->num_joints() == 0 ? 1 : 0;
}

}  // extern "C"
