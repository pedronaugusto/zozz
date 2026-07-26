//===----------------------------------------------------------------------===//
// zozz — SoA pose storage and the SoA <-> AoS transposes.
//===----------------------------------------------------------------------===//

#include "zozz_internal.h"

namespace zozz {

namespace {

/// Joints handled by one SoA block.
constexpr int kLanes = 4;

}  // namespace

void SoaToAos(const ozz::math::SoaTransform* soa, ZozzTransform* aos,
              int num_joints) {
  namespace m = ozz::math;
  const int blocks = SoaBlocks(num_joints);
  for (int b = 0; b < blocks; ++b) {
    const m::SoaTransform& in = soa[b];

    // Copy into locals rather than aliasing the struct as an array: the
    // members are contiguous in practice, but reading them through an array
    // pointer would be type-punning the compiler is free to reorder around.
    const m::SimdFloat4 t_in[3] = {in.translation.x, in.translation.y,
                                   in.translation.z};
    const m::SimdFloat4 r_in[4] = {in.rotation.x, in.rotation.y, in.rotation.z,
                                   in.rotation.w};
    const m::SimdFloat4 s_in[3] = {in.scale.x, in.scale.y, in.scale.z};

    m::SimdFloat4 t_out[4], r_out[4], s_out[4];
    m::Transpose3x4(t_in, t_out);
    m::Transpose4x4(r_in, r_out);
    m::Transpose3x4(s_in, s_out);

    // The final block is usually partial; never write past num_joints.
    const int base = b * kLanes;
    const int lanes = num_joints - base < kLanes ? num_joints - base : kLanes;
    for (int l = 0; l < lanes; ++l) {
      ZozzTransform& out = aos[base + l];
      m::Store3PtrU(t_out[l], out.translation);
      m::StorePtrU(r_out[l], out.rotation);
      m::Store3PtrU(s_out[l], out.scale);
    }
  }
}

void AosToSoa(const ZozzTransform* aos, ozz::math::SoaTransform* soa,
              int num_joints) {
  namespace m = ozz::math;
  const int blocks = SoaBlocks(num_joints);
  for (int b = 0; b < blocks; ++b) {
    const int base = b * kLanes;
    const int lanes = num_joints - base < kLanes ? num_joints - base : kLanes;

    // Pad the trailing partial block with identity so the unused lanes hold
    // valid data — blending and local-to-model read whole blocks.
    m::SimdFloat4 t_in[4], r_in[4], s_in[4];
    for (int l = 0; l < kLanes; ++l) {
      if (l < lanes) {
        const ZozzTransform& in = aos[base + l];
        t_in[l] = m::simd_float4::Load3PtrU(in.translation);
        r_in[l] = m::simd_float4::LoadPtrU(in.rotation);
        s_in[l] = m::simd_float4::Load3PtrU(in.scale);
      } else {
        t_in[l] = m::simd_float4::zero();
        r_in[l] = m::simd_float4::w_axis();  // identity quaternion (0,0,0,1)
        s_in[l] = m::simd_float4::one();
      }
    }

    m::SoaTransform& out = soa[b];
    m::SimdFloat4 t_out[3], s_out[3], r_out[4];
    m::Transpose4x3(t_in, t_out);
    m::Transpose4x4(r_in, r_out);
    m::Transpose4x3(s_in, s_out);

    out.translation.x = t_out[0];
    out.translation.y = t_out[1];
    out.translation.z = t_out[2];
    out.rotation.x = r_out[0];
    out.rotation.y = r_out[1];
    out.rotation.z = r_out[2];
    out.rotation.w = r_out[3];
    out.scale.x = s_out[0];
    out.scale.y = s_out[1];
    out.scale.z = s_out[2];
  }
}

}  // namespace zozz

extern "C" {

ZozzResult zozzSoaPoseCreate(int num_joints, ZozzSoaPose** out) {
  if (out == nullptr) return ZOZZ_ERR_INVALID_ARGUMENT;
  *out = nullptr;
  if (num_joints <= 0 || num_joints > zozz::kMaxJoints) {
    return ZOZZ_ERR_INVALID_ARGUMENT;
  }

  const int blocks = zozz::SoaBlocks(num_joints);
  ozz::memory::Allocator* allocator = ozz::memory::default_allocator();
  void* storage =
      allocator->Allocate(sizeof(ozz::math::SoaTransform) * blocks,
                          alignof(ozz::math::SoaTransform));
  if (storage == nullptr) return ZOZZ_ERR_OUT_OF_MEMORY;

  ZozzSoaPose* pose = zozz::New<ZozzSoaPose>();
  if (pose == nullptr) {
    allocator->Deallocate(storage);
    return ZOZZ_ERR_OUT_OF_MEMORY;
  }

  pose->data = static_cast<ozz::math::SoaTransform*>(storage);
  pose->num_joints = num_joints;
  pose->num_soa_joints = blocks;
  for (int b = 0; b < blocks; ++b) {
    pose->data[b] = ozz::math::SoaTransform::identity();
  }

  *out = pose;
  return ZOZZ_OK;
}

void zozzSoaPoseDestroy(ZozzSoaPose* pose) {
  if (pose == nullptr) return;
  ozz::memory::default_allocator()->Deallocate(pose->data);
  zozz::Delete(pose);
}

int zozzSoaPoseNumJoints(const ZozzSoaPose* pose) {
  return pose == nullptr ? 0 : pose->num_joints;
}

ZozzResult zozzSoaPoseSetIdentity(ZozzSoaPose* pose) {
  if (pose == nullptr) return ZOZZ_ERR_INVALID_ARGUMENT;
  for (int b = 0; b < pose->num_soa_joints; ++b) {
    pose->data[b] = ozz::math::SoaTransform::identity();
  }
  return ZOZZ_OK;
}

ZozzResult zozzSoaPoseSetRestPose(ZozzSoaPose* pose,
                                  const ZozzSkeleton* skeleton) {
  if (pose == nullptr || skeleton == nullptr) return ZOZZ_ERR_INVALID_ARGUMENT;
  if (pose->num_joints != skeleton->impl.num_joints()) {
    return ZOZZ_ERR_SKELETON_MISMATCH;
  }
  const ozz::span<const ozz::math::SoaTransform> rest =
      skeleton->impl.joint_rest_poses();
  for (int b = 0; b < pose->num_soa_joints; ++b) {
    pose->data[b] = rest[b];
  }
  return ZOZZ_OK;
}

ZozzResult zozzSoaPoseToLocalTransforms(const ZozzSoaPose* pose,
                                        ZozzTransform* out, size_t count) {
  if (pose == nullptr || out == nullptr) return ZOZZ_ERR_INVALID_ARGUMENT;
  if (count < static_cast<size_t>(pose->num_joints)) {
    return ZOZZ_ERR_BUFFER_TOO_SMALL;
  }
  zozz::SoaToAos(pose->data, out, pose->num_joints);
  return ZOZZ_OK;
}

ZozzResult zozzSoaPoseFromLocalTransforms(ZozzSoaPose* pose,
                                          const ZozzTransform* in,
                                          size_t count) {
  if (pose == nullptr || in == nullptr) return ZOZZ_ERR_INVALID_ARGUMENT;
  if (count < static_cast<size_t>(pose->num_joints)) {
    return ZOZZ_ERR_BUFFER_TOO_SMALL;
  }
  zozz::AosToSoa(in, pose->data, pose->num_joints);
  return ZOZZ_OK;
}

}  // extern "C"
