//===----------------------------------------------------------------------===//
// zozz — skeleton and animation utilities.
//===----------------------------------------------------------------------===//

#include "zozz_utils.h"

#include "ozz/animation/runtime/animation_utils.h"
#include "ozz/animation/runtime/skeleton_utils.h"
#include "zozz_internal.h"

namespace {

/// Shared body of the three per-track keyframe counters: same null and
/// range checks, only the ozz-side function differs.
ZozzResult CountKeys(const ZozzAnimation* animation, int track,
                     int (*count_fn)(const ozz::animation::Animation&, int),
                     int* out) {
  if (animation == nullptr || out == nullptr) {
    return ZOZZ_RESULT_INVALID_ARGUMENT;
  }
  if (track < -1 || track >= animation->impl.num_tracks()) {
    return ZOZZ_RESULT_INVALID_ARGUMENT;
  }
  *out = count_fn(animation->impl, track);
  return ZOZZ_RESULT_OK;
}

}  // namespace

extern "C" {

ZozzResult zozzSkeletonJointRestPoseLocal(const ZozzSkeleton* skeleton,
                                          int joint, ZozzTransform* out) {
  if (skeleton == nullptr || out == nullptr) {
    return ZOZZ_RESULT_INVALID_ARGUMENT;
  }
  if (joint < 0 || joint >= skeleton->impl.num_joints()) {
    return ZOZZ_RESULT_INVALID_ARGUMENT;
  }

  const ozz::math::Transform rest =
      ozz::animation::GetJointRestPoseLocalSpace(skeleton->impl, joint);
  out->translation[0] = rest.translation.x;
  out->translation[1] = rest.translation.y;
  out->translation[2] = rest.translation.z;
  out->rotation[0] = rest.rotation.x;
  out->rotation[1] = rest.rotation.y;
  out->rotation[2] = rest.rotation.z;
  out->rotation[3] = rest.rotation.w;
  out->scale[0] = rest.scale.x;
  out->scale[1] = rest.scale.y;
  out->scale[2] = rest.scale.z;
  return ZOZZ_RESULT_OK;
}

ZozzResult zozzSkeletonRestPoseModelSpace(const ZozzSkeleton* skeleton,
                                          ZozzFloat4x4* out, size_t count) {
  if (skeleton == nullptr || out == nullptr) {
    return ZOZZ_RESULT_INVALID_ARGUMENT;
  }
  if (!zozz::IsAligned16(out)) return ZOZZ_RESULT_INVALID_ARGUMENT;
  const int joints = skeleton->impl.num_joints();
  if (count < static_cast<size_t>(joints)) return ZOZZ_RESULT_BUFFER_TOO_SMALL;

  const ozz::vector<ozz::math::Float4x4> models =
      ozz::animation::GetRestPoseModelSpace(skeleton->impl);
  // ZozzFloat4x4 is layout- and alignment-compatible with ozz's Float4x4;
  // zozz_abi.cpp static_asserts both properties.
  std::memcpy(out, models.data(),
             static_cast<size_t>(joints) * sizeof(ZozzFloat4x4));
  return ZOZZ_RESULT_OK;
}

ZozzResult zozzSkeletonJointIsLeaf(const ZozzSkeleton* skeleton, int joint,
                                   bool* out) {
  if (skeleton == nullptr || out == nullptr) {
    return ZOZZ_RESULT_INVALID_ARGUMENT;
  }
  *out = false;
  if (joint < 0 || joint >= skeleton->impl.num_joints()) {
    return ZOZZ_RESULT_INVALID_ARGUMENT;
  }
  *out = ozz::animation::IsLeaf(skeleton->impl, joint);
  return ZOZZ_RESULT_OK;
}

int zozzSkeletonFindJoint(const ZozzSkeleton* skeleton, const char* name) {
  if (skeleton == nullptr || name == nullptr) return -1;
  return ozz::animation::FindJoint(skeleton->impl, name);
}

ZozzResult zozzSkeletonIterateJointsDepthFirst(const ZozzSkeleton* skeleton,
                                               int from,
                                               ZozzJointVisitor visitor,
                                               void* user) {
  if (skeleton == nullptr || visitor == nullptr) {
    return ZOZZ_RESULT_INVALID_ARGUMENT;
  }
  const int joints = skeleton->impl.num_joints();
  if (from != ZOZZ_NO_PARENT && (from < 0 || from >= joints)) {
    return ZOZZ_RESULT_INVALID_ARGUMENT;
  }

  ozz::animation::IterateJointsDF(
      skeleton->impl,
      [visitor, user](int current, int parent) {
        visitor(current, parent, user);
      },
      from);
  return ZOZZ_RESULT_OK;
}

ZozzResult zozzSkeletonIterateJointsDepthFirstReverse(
    const ZozzSkeleton* skeleton, ZozzJointVisitor visitor, void* user) {
  if (skeleton == nullptr || visitor == nullptr) {
    return ZOZZ_RESULT_INVALID_ARGUMENT;
  }

  ozz::animation::IterateJointsDFReverse(
      skeleton->impl, [visitor, user](int current, int parent) {
        visitor(current, parent, user);
      });
  return ZOZZ_RESULT_OK;
}

ZozzResult zozzAnimationCountTranslationKeys(const ZozzAnimation* animation,
                                             int track, int* out) {
  return CountKeys(animation, track, ozz::animation::CountTranslationKeyframes,
                   out);
}

ZozzResult zozzAnimationCountRotationKeys(const ZozzAnimation* animation,
                                          int track, int* out) {
  return CountKeys(animation, track, ozz::animation::CountRotationKeyframes,
                   out);
}

ZozzResult zozzAnimationCountScaleKeys(const ZozzAnimation* animation,
                                       int track, int* out) {
  return CountKeys(animation, track, ozz::animation::CountScaleKeyframes, out);
}

}  // extern "C"
