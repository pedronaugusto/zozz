//===----------------------------------------------------------------------===//
// zozz — offline builders: RawSkeleton -> Skeleton, RawAnimation -> Animation.
//
// The raw-skeleton handle is deliberately NOT ozz's RawSkeleton. ozz stores
// the hierarchy as nested child vectors, so a stable C API over it would hand
// out pointers that die on the next sibling insertion. The handle keeps a
// flat (parent, name, rest) list instead — the shape a host's own skeleton
// data is already in — and materialises the nested tree once, at build time.
//
// The raw-animation handle wraps ozz's RawAnimation directly: its track
// vectors are sized once at creation and only ever appended to, so no
// borrowed pointer is at risk.
//
// Validation split, uniformly: argument-shape problems (range, NaN, NULL)
// fail at the call that receives them with ZOZZ_RESULT_INVALID_ARGUMENT;
// data-shape problems only ozz can judge (hierarchy depth, key ordering)
// fail at build time with ZOZZ_RESULT_INVALID_DATA. Nothing asserts.
//===----------------------------------------------------------------------===//

#include <cmath>
#include <cstdint>

#include "ozz/animation/offline/animation_builder.h"
#include "ozz/animation/offline/raw_animation.h"
#include "ozz/animation/offline/raw_skeleton.h"
#include "ozz/animation/offline/skeleton_builder.h"
#include "ozz/base/containers/string.h"
#include "ozz/base/containers/vector.h"
#include "ozz/base/maths/transform.h"
#include "ozz/base/memory/unique_ptr.h"
#include "zozz_internal.h"

namespace {

bool Finite3(const float* v) {
  return std::isfinite(v[0]) && std::isfinite(v[1]) && std::isfinite(v[2]);
}

bool Finite4(const float* v) { return Finite3(v) && std::isfinite(v[3]); }

bool FiniteTransform(const ZozzTransform& t) {
  return Finite3(t.translation) && Finite4(t.rotation) && Finite3(t.scale);
}

ozz::math::Transform ToOzz(const ZozzTransform& t) {
  ozz::math::Transform out;
  out.translation = {t.translation[0], t.translation[1], t.translation[2]};
  out.rotation = {t.rotation[0], t.rotation[1], t.rotation[2], t.rotation[3]};
  out.scale = {t.scale[0], t.scale[1], t.scale[2]};
  return out;
}

/// One authored joint, flat. `parent` is an insertion index or -1.
struct FlatJoint {
  int32_t parent;
  ozz::string name;
  ozz::math::Transform rest;
};

/// Recursively copies `joint`'s children (in insertion order) into `out`.
/// Depth is bounded by the joint count, which is bounded by kMaxJoints, so
/// the recursion cannot outgrow the stack meaningfully; ozz's own Validate
/// additionally rejects hierarchies over its depth limit at build.
void FillChildren(const ozz::vector<FlatJoint>& joints,
                  const ozz::vector<ozz::vector<int32_t>>& children,
                  int32_t index,
                  ozz::animation::offline::RawSkeleton::Joint* out) {
  const FlatJoint& flat = joints[index];
  out->name = flat.name.c_str();
  out->transform = flat.rest;

  const ozz::vector<int32_t>& kids = children[index];
  out->children.resize(kids.size());
  for (size_t i = 0; i < kids.size(); ++i) {
    FillChildren(joints, children, kids[i], &out->children[i]);
  }
}

}  // namespace

//===----------------------------------------------------------------------===//
// Handle types (global namespace — they must match the C tag names)
//===----------------------------------------------------------------------===//

struct ZozzRawSkeleton {
  ozz::vector<FlatJoint> joints;
};

struct ZozzRawAnimation {
  ozz::animation::offline::RawAnimation impl;
};

extern "C" {

//===----------------------------------------------------------------------===//
// Raw skeleton
//===----------------------------------------------------------------------===//

ZozzResult zozzRawSkeletonCreate(ZozzRawSkeleton** out) {
  if (out == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  *out = nullptr;
  ZozzRawSkeleton* raw = zozz::New<ZozzRawSkeleton>();
  if (raw == nullptr) return ZOZZ_RESULT_OUT_OF_MEMORY;
  *out = raw;
  return ZOZZ_RESULT_OK;
}

void zozzRawSkeletonDestroy(ZozzRawSkeleton* raw) { zozz::Delete(raw); }

ZozzResult zozzRawSkeletonAddJoint(ZozzRawSkeleton* raw, int32_t parent,
                                   const char* name,
                                   const ZozzTransform* rest,
                                   int32_t* out_index) {
  if (raw == nullptr || name == nullptr || rest == nullptr) {
    return ZOZZ_RESULT_INVALID_ARGUMENT;
  }
  const int32_t count = static_cast<int32_t>(raw->joints.size());
  if (parent != ZOZZ_NO_PARENT && (parent < 0 || parent >= count)) {
    return ZOZZ_RESULT_INVALID_ARGUMENT;
  }
  if (count >= zozz::kMaxJoints) return ZOZZ_RESULT_INVALID_ARGUMENT;
  if (!FiniteTransform(*rest)) return ZOZZ_RESULT_INVALID_ARGUMENT;

  raw->joints.push_back({parent, ozz::string(name), ToOzz(*rest)});
  if (out_index != nullptr) *out_index = count;
  return ZOZZ_RESULT_OK;
}

int zozzRawSkeletonNumJoints(const ZozzRawSkeleton* raw) {
  return raw == nullptr ? 0 : static_cast<int>(raw->joints.size());
}

ZozzResult zozzSkeletonBuild(const ZozzRawSkeleton* raw, ZozzSkeleton** out) {
  if (raw == nullptr || out == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  *out = nullptr;
  if (raw->joints.empty()) return ZOZZ_RESULT_INVALID_DATA;

  // Materialise the nested tree: bucket children per parent, then fill
  // depth-first from the roots. Insertion order is preserved within each
  // child list, which is what makes a depth-first insertion sequence come
  // out with identical indices.
  const size_t count = raw->joints.size();
  ozz::vector<ozz::vector<int32_t>> children(count);
  ozz::vector<int32_t> roots;
  for (size_t i = 0; i < count; ++i) {
    const int32_t parent = raw->joints[i].parent;
    if (parent == ZOZZ_NO_PARENT) {
      roots.push_back(static_cast<int32_t>(i));
    } else {
      children[parent].push_back(static_cast<int32_t>(i));
    }
  }

  ozz::animation::offline::RawSkeleton raw_ozz;
  raw_ozz.roots.resize(roots.size());
  for (size_t i = 0; i < roots.size(); ++i) {
    FillChildren(raw->joints, children, roots[i], &raw_ozz.roots[i]);
  }

  if (!raw_ozz.Validate()) return ZOZZ_RESULT_INVALID_DATA;

  ozz::animation::offline::SkeletonBuilder builder;
  ozz::unique_ptr<ozz::animation::Skeleton> built = builder(raw_ozz);
  if (!built) return ZOZZ_RESULT_OUT_OF_MEMORY;

  ZozzSkeleton* skeleton = zozz::New<ZozzSkeleton>();
  if (skeleton == nullptr) return ZOZZ_RESULT_OUT_OF_MEMORY;
  skeleton->impl = std::move(*built);
  *out = skeleton;
  return ZOZZ_RESULT_OK;
}

//===----------------------------------------------------------------------===//
// Raw animation
//===----------------------------------------------------------------------===//

ZozzResult zozzRawAnimationCreate(int num_tracks, float duration,
                                  const char* name, ZozzRawAnimation** out) {
  if (out == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  *out = nullptr;
  if (num_tracks <= 0 || num_tracks > zozz::kMaxJoints) {
    return ZOZZ_RESULT_INVALID_ARGUMENT;
  }
  if (!std::isfinite(duration) || duration <= 0.f) {
    return ZOZZ_RESULT_INVALID_ARGUMENT;
  }

  ZozzRawAnimation* raw = zozz::New<ZozzRawAnimation>();
  if (raw == nullptr) return ZOZZ_RESULT_OUT_OF_MEMORY;
  raw->impl.duration = duration;
  raw->impl.name = name == nullptr ? "" : name;
  raw->impl.tracks.resize(static_cast<size_t>(num_tracks));
  *out = raw;
  return ZOZZ_RESULT_OK;
}

void zozzRawAnimationDestroy(ZozzRawAnimation* raw) { zozz::Delete(raw); }

int zozzRawAnimationNumTracks(const ZozzRawAnimation* raw) {
  return raw == nullptr ? 0 : static_cast<int>(raw->impl.tracks.size());
}

float zozzRawAnimationDuration(const ZozzRawAnimation* raw) {
  return raw == nullptr ? 0.f : raw->impl.duration;
}

namespace {

/// Shared argument validation for the three push entry points. Writes the
/// checked track pointer through `out_track` on success.
ZozzResult CheckPush(ZozzRawAnimation* raw, int track, float time,
                     const float* value, int value_count,
                     ozz::animation::offline::RawAnimation::JointTrack**
                         out_track) {
  if (raw == nullptr || value == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  if (track < 0 || track >= static_cast<int>(raw->impl.tracks.size())) {
    return ZOZZ_RESULT_INVALID_ARGUMENT;
  }
  if (!std::isfinite(time) || time < 0.f || time > raw->impl.duration) {
    return ZOZZ_RESULT_INVALID_ARGUMENT;
  }
  const bool finite = value_count == 4 ? Finite4(value) : Finite3(value);
  if (!finite) return ZOZZ_RESULT_INVALID_ARGUMENT;
  *out_track = &raw->impl.tracks[static_cast<size_t>(track)];
  return ZOZZ_RESULT_OK;
}

}  // namespace

ZozzResult zozzRawAnimationPushTranslation(ZozzRawAnimation* raw, int track,
                                           float time, const float value[3]) {
  ozz::animation::offline::RawAnimation::JointTrack* t = nullptr;
  const ZozzResult check = CheckPush(raw, track, time, value, 3, &t);
  if (check != ZOZZ_RESULT_OK) return check;
  t->translations.push_back(
      {time, ozz::math::Float3(value[0], value[1], value[2])});
  return ZOZZ_RESULT_OK;
}

ZozzResult zozzRawAnimationPushRotation(ZozzRawAnimation* raw, int track,
                                        float time, const float value[4]) {
  ozz::animation::offline::RawAnimation::JointTrack* t = nullptr;
  const ZozzResult check = CheckPush(raw, track, time, value, 4, &t);
  if (check != ZOZZ_RESULT_OK) return check;
  t->rotations.push_back(
      {time,
       ozz::math::Quaternion(value[0], value[1], value[2], value[3])});
  return ZOZZ_RESULT_OK;
}

ZozzResult zozzRawAnimationPushScale(ZozzRawAnimation* raw, int track,
                                     float time, const float value[3]) {
  ozz::animation::offline::RawAnimation::JointTrack* t = nullptr;
  const ZozzResult check = CheckPush(raw, track, time, value, 3, &t);
  if (check != ZOZZ_RESULT_OK) return check;
  t->scales.push_back({time, ozz::math::Float3(value[0], value[1], value[2])});
  return ZOZZ_RESULT_OK;
}

ZozzResult zozzAnimationBuild(const ZozzRawAnimation* raw,
                              ZozzAnimation** out) {
  if (raw == nullptr || out == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  *out = nullptr;
  if (!raw->impl.Validate()) return ZOZZ_RESULT_INVALID_DATA;

  ozz::animation::offline::AnimationBuilder builder;
  ozz::unique_ptr<ozz::animation::Animation> built = builder(raw->impl);
  if (!built) return ZOZZ_RESULT_OUT_OF_MEMORY;

  ZozzAnimation* animation = zozz::New<ZozzAnimation>();
  if (animation == nullptr) return ZOZZ_RESULT_OUT_OF_MEMORY;
  animation->impl = std::move(*built);
  *out = animation;
  return ZOZZ_RESULT_OK;
}

}  // extern "C"
