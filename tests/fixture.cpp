//===----------------------------------------------------------------------===//
// zozz — synthetic test assets, built with ozz's offline builders.
//===----------------------------------------------------------------------===//

#include "fixture.h"

#include <cstdlib>
#include <cstring>
#include <iostream>
#include <sstream>

#include "ozz/animation/offline/animation_builder.h"
#include "ozz/animation/offline/raw_animation.h"
#include "ozz/animation/offline/raw_skeleton.h"
#include "ozz/animation/offline/skeleton_builder.h"
#include "ozz/animation/runtime/animation.h"
#include "ozz/animation/runtime/skeleton.h"
#include "ozz/base/io/archive.h"
#include "ozz/base/io/stream.h"
#include "ozz/base/maths/transform.h"
#include "ozz/base/memory/unique_ptr.h"

namespace {

using ozz::animation::offline::RawAnimation;
using ozz::animation::offline::RawSkeleton;

/// root -> spine -> {arm_l, arm_r}. Deep enough that local-to-model has a real
/// hierarchy to walk, small enough to stay a fixture.
RawSkeleton BuildRawSkeleton() {
  RawSkeleton raw;
  raw.roots.resize(1);

  RawSkeleton::Joint& root = raw.roots[0];
  root.name = "root";
  root.transform = ozz::math::Transform::identity();

  root.children.resize(1);
  RawSkeleton::Joint& spine = root.children[0];
  spine.name = "spine";
  spine.transform = ozz::math::Transform::identity();
  spine.transform.translation = ozz::math::Float3(0.f, 1.f, 0.f);

  spine.children.resize(2);
  RawSkeleton::Joint& arm_l = spine.children[0];
  arm_l.name = "arm_l";
  arm_l.transform = ozz::math::Transform::identity();
  arm_l.transform.translation = ozz::math::Float3(-0.5f, 0.5f, 0.f);

  RawSkeleton::Joint& arm_r = spine.children[1];
  arm_r.name = "arm_r";
  arm_r.transform = ozz::math::Transform::identity();
  arm_r.transform.translation = ozz::math::Float3(0.5f, 0.5f, 0.f);

  return raw;
}

/// Every joint gets keys, and the root translates along +X across the clip so
/// that two samples at different ratios are observably different.
RawAnimation BuildRawAnimation() {
  RawAnimation raw;
  raw.name = "fixture";
  raw.duration = ZOZZ_FIXTURE_DURATION;
  raw.tracks.resize(ZOZZ_FIXTURE_JOINTS);

  for (int i = 0; i < ZOZZ_FIXTURE_JOINTS; ++i) {
    RawAnimation::JointTrack& track = raw.tracks[i];

    const float offset = static_cast<float>(i);
    track.translations.push_back(
        {0.f, ozz::math::Float3(0.f, offset, 0.f)});
    track.translations.push_back(
        {ZOZZ_FIXTURE_DURATION, ozz::math::Float3(1.f, offset, 0.f)});

    // A quarter turn about Y over the clip, so rotations are non-identity and
    // interpolation has something to do.
    track.rotations.push_back(
        {0.f, ozz::math::Quaternion::identity()});
    track.rotations.push_back(
        {ZOZZ_FIXTURE_DURATION,
         ozz::math::Quaternion::FromAxisAngle(
             ozz::math::Float3(0.f, 1.f, 0.f), ozz::math::kPi_2)});

    track.scales.push_back({0.f, ozz::math::Float3::one()});
    track.scales.push_back({ZOZZ_FIXTURE_DURATION, ozz::math::Float3::one()});
  }

  return raw;
}

/// Serialises one tagged ozz object into a malloc'd buffer.
///
/// malloc rather than the ozz allocator on purpose: the fixture must not
/// disturb the allocation accounting a test may be asserting on.
template <typename T>
ZozzResult Serialise(const T& object, void** out_data, size_t* out_size) {
  if (out_data == nullptr || out_size == nullptr) {
    return ZOZZ_RESULT_INVALID_ARGUMENT;
  }
  *out_data = nullptr;
  *out_size = 0;

  ozz::io::MemoryStream stream;
  if (!stream.opened()) return ZOZZ_RESULT_IO;
  {
    ozz::io::OArchive archive(&stream);
    archive << object;
  }

  const size_t size = stream.Size();
  if (size == 0) return ZOZZ_RESULT_IO;
  if (stream.Seek(0, ozz::io::Stream::kSet) != 0) return ZOZZ_RESULT_IO;

  void* buffer = std::malloc(size);
  if (buffer == nullptr) return ZOZZ_RESULT_OUT_OF_MEMORY;
  if (stream.Read(buffer, size) != size) {
    std::free(buffer);
    return ZOZZ_RESULT_IO;
  }

  *out_data = buffer;
  *out_size = size;
  return ZOZZ_RESULT_OK;
}

}  // namespace

extern "C" {

ZozzResult zozzFixtureSkeleton(void** out_data, size_t* out_size) {
  const RawSkeleton raw = BuildRawSkeleton();
  if (!raw.Validate()) return ZOZZ_RESULT_BAD_FORMAT;

  ozz::animation::offline::SkeletonBuilder builder;
  ozz::unique_ptr<ozz::animation::Skeleton> skeleton = builder(raw);
  if (!skeleton) return ZOZZ_RESULT_BAD_FORMAT;

  return Serialise(*skeleton, out_data, out_size);
}

ZozzResult zozzFixtureAnimation(void** out_data, size_t* out_size) {
  const RawAnimation raw = BuildRawAnimation();
  if (!raw.Validate()) return ZOZZ_RESULT_BAD_FORMAT;

  ozz::animation::offline::AnimationBuilder builder;
  ozz::unique_ptr<ozz::animation::Animation> animation = builder(raw);
  if (!animation) return ZOZZ_RESULT_BAD_FORMAT;

  return Serialise(*animation, out_data, out_size);
}

void zozzFixtureFree(void* data) { std::free(data); }

size_t zozzFixtureCapturedSkeletonLoadBytes(const void* data, size_t size) {
  // std::cerr is what ozz::log::Err() actually writes through at the
  // STANDARD level (log.cc). Swapping its stream buffer for the duration of
  // one call is the only portable way to observe that from here -- no OS
  // stdio redirection needed, and nothing that survives past this function.
  std::ostringstream capture;
  std::streambuf* original = std::cerr.rdbuf(capture.rdbuf());

  ZozzSkeleton* skeleton = nullptr;
  zozzSkeletonLoadMemory(data, size, &skeleton);
  zozzSkeletonDestroy(skeleton);

  std::cerr.rdbuf(original);
  return capture.str().size();
}

}  // extern "C"
