//===----------------------------------------------------------------------===//
// zozz — the SoA <-> AoS transposes, and the operations over a caller-owned
// SoA pose. No allocation happens here: the caller owns every buffer.
//===----------------------------------------------------------------------===//

#include <cmath>

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

size_t zozzSoaBlocks(int num_joints) {
  if (num_joints < 1 || num_joints > zozz::kMaxJoints) return 0;
  return static_cast<size_t>(zozz::SoaBlocks(num_joints));
}

ZozzResult zozzSoaPoseSetIdentity(ZozzSoaTransform* pose, size_t blocks) {
  if (pose == nullptr || blocks == 0) return ZOZZ_RESULT_INVALID_ARGUMENT;
  if (!zozz::IsAligned16(pose)) return ZOZZ_RESULT_INVALID_ARGUMENT;
  ozz::math::SoaTransform* soa = zozz::AsOzz(pose);
  for (size_t b = 0; b < blocks; ++b) {
    soa[b] = ozz::math::SoaTransform::identity();
  }
  return ZOZZ_RESULT_OK;
}

ZozzResult zozzSoaPoseToLocalTransforms(const ZozzSoaTransform* pose,
                                        size_t blocks, ZozzTransform* out,
                                        size_t num_joints) {
  if (pose == nullptr || out == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  if (!zozz::IsAligned16(pose)) return ZOZZ_RESULT_INVALID_ARGUMENT;
  if (num_joints == 0) return ZOZZ_RESULT_INVALID_ARGUMENT;
  if (blocks < (num_joints + 3) / 4) return ZOZZ_RESULT_BUFFER_TOO_SMALL;
  zozz::SoaToAos(zozz::AsOzz(pose), out, static_cast<int>(num_joints));
  return ZOZZ_RESULT_OK;
}

ZozzResult zozzSoaPoseFromLocalTransforms(const ZozzTransform* in,
                                          size_t num_joints,
                                          ZozzSoaTransform* pose,
                                          size_t blocks) {
  if (in == nullptr || pose == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  if (!zozz::IsAligned16(pose)) return ZOZZ_RESULT_INVALID_ARGUMENT;
  if (num_joints == 0) return ZOZZ_RESULT_INVALID_ARGUMENT;
  if (blocks < (num_joints + 3) / 4) return ZOZZ_RESULT_BUFFER_TOO_SMALL;
  zozz::AosToSoa(in, zozz::AsOzz(pose), static_cast<int>(num_joints));
  return ZOZZ_RESULT_OK;
}

ZozzResult zozzSoaWeightsPack(const float* in, size_t num_joints,
                              ZozzSimdFloat4* out, size_t blocks) {
  if (in == nullptr || out == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  if (!zozz::IsAligned16(out)) return ZOZZ_RESULT_INVALID_ARGUMENT;
  if (num_joints == 0) return ZOZZ_RESULT_INVALID_ARGUMENT;
  if (blocks < (num_joints + 3) / 4) return ZOZZ_RESULT_BUFFER_TOO_SMALL;
  for (size_t i = 0; i < num_joints; ++i) {
    if (!std::isfinite(in[i])) return ZOZZ_RESULT_INVALID_ARGUMENT;
  }

  ozz::math::SimdFloat4* simd = zozz::AsOzz(out);
  const size_t used = (num_joints + 3) / 4;
  for (size_t b = 0; b < used; ++b) {
    const size_t base = b * 4;
    float lane[4] = {1.f, 1.f, 1.f, 1.f};
    for (size_t l = 0; l < 4 && base + l < num_joints; ++l) {
      lane[l] = in[base + l];
    }
    simd[b] = ozz::math::simd_float4::LoadPtrU(lane);
  }
  for (size_t b = used; b < blocks; ++b) {
    simd[b] = ozz::math::simd_float4::one();
  }
  return ZOZZ_RESULT_OK;
}

}  // extern "C"
