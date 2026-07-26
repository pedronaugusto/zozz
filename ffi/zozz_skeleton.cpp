//===----------------------------------------------------------------------===//
// zozz — skeleton loading and queries.
//===----------------------------------------------------------------------===//

#include "zozz_internal.h"

namespace {

/// Rejects a skeleton that parsed without complaint but describes something
/// ozz's own jobs would refuse. A truncated archive can land here.
ZozzResult ValidateSkeleton(const ozz::animation::Skeleton& skeleton) {
  const int joints = skeleton.num_joints();
  if (joints < 0 || joints > zozz::kMaxJoints) return ZOZZ_ERR_BAD_FORMAT;
  if (skeleton.joint_names().size() != static_cast<size_t>(joints)) {
    return ZOZZ_ERR_BAD_FORMAT;
  }
  if (skeleton.joint_rest_poses().size() !=
      static_cast<size_t>(zozz::SoaBlocks(joints))) {
    return ZOZZ_ERR_BAD_FORMAT;
  }
  return ZOZZ_OK;
}

/// Shared tail of both load entry points: wrap the loaded impl in a handle, or
/// destroy it and report why.
ZozzResult FinishLoad(ZozzSkeleton* skeleton, ZozzResult load_result,
                      ZozzSkeleton** out) {
  if (load_result != ZOZZ_OK) {
    zozz::Delete(skeleton);
    return load_result;
  }
  const ZozzResult valid = ValidateSkeleton(skeleton->impl);
  if (valid != ZOZZ_OK) {
    zozz::Delete(skeleton);
    return valid;
  }
  *out = skeleton;
  return ZOZZ_OK;
}

}  // namespace

extern "C" {

ZozzResult zozzSkeletonLoadFile(const char* path, ZozzSkeleton** out) {
  if (out == nullptr) return ZOZZ_ERR_INVALID_ARGUMENT;
  *out = nullptr;
  ZozzSkeleton* skeleton = zozz::New<ZozzSkeleton>();
  if (skeleton == nullptr) return ZOZZ_ERR_OUT_OF_MEMORY;
  return FinishLoad(skeleton, zozz::LoadFromFile(path, &skeleton->impl), out);
}

ZozzResult zozzSkeletonLoadMemory(const void* data, size_t size,
                                  ZozzSkeleton** out) {
  if (out == nullptr) return ZOZZ_ERR_INVALID_ARGUMENT;
  *out = nullptr;
  ZozzSkeleton* skeleton = zozz::New<ZozzSkeleton>();
  if (skeleton == nullptr) return ZOZZ_ERR_OUT_OF_MEMORY;
  return FinishLoad(skeleton, zozz::LoadFromMemory(data, size, &skeleton->impl),
                    out);
}

void zozzSkeletonDestroy(ZozzSkeleton* skeleton) { zozz::Delete(skeleton); }

int zozzSkeletonNumJoints(const ZozzSkeleton* skeleton) {
  return skeleton == nullptr ? 0 : skeleton->impl.num_joints();
}

int zozzSkeletonNumSoaJoints(const ZozzSkeleton* skeleton) {
  return skeleton == nullptr ? 0 : skeleton->impl.num_soa_joints();
}

const char* zozzSkeletonJointName(const ZozzSkeleton* skeleton, int joint) {
  if (skeleton == nullptr) return nullptr;
  if (joint < 0 || joint >= skeleton->impl.num_joints()) return nullptr;
  return skeleton->impl.joint_names()[joint];
}

int16_t zozzSkeletonJointParent(const ZozzSkeleton* skeleton, int joint) {
  if (skeleton == nullptr) return ZOZZ_NO_PARENT;
  if (joint < 0 || joint >= skeleton->impl.num_joints()) return ZOZZ_NO_PARENT;
  return skeleton->impl.joint_parents()[joint];
}

ZozzResult zozzSkeletonRestPose(const ZozzSkeleton* skeleton,
                                ZozzTransform* out, size_t count) {
  if (skeleton == nullptr || out == nullptr) return ZOZZ_ERR_INVALID_ARGUMENT;
  const int joints = skeleton->impl.num_joints();
  if (count < static_cast<size_t>(joints)) return ZOZZ_ERR_BUFFER_TOO_SMALL;
  zozz::SoaToAos(skeleton->impl.joint_rest_poses().data(), out, joints);
  return ZOZZ_OK;
}

}  // extern "C"
