//===----------------------------------------------------------------------===//
// zozz — two-bone and single-joint inverse kinematics.
//===----------------------------------------------------------------------===//

#include "zozz_ik.h"

#include "ozz/animation/runtime/ik_aim_job.h"
#include "ozz/animation/runtime/ik_two_bone_job.h"
#include "ozz/base/maths/simd_quaternion.h"
#include "zozz_internal.h"

namespace {

namespace m = ozz::math;

/// Builds the ozz job's fixed inputs from the C descriptor, pointing its
/// three output fields at caller-supplied scratch. Returns false (without
/// touching `out`) if a required pointer is NULL.
///
/// This is the one precondition ozz's own Validate() cannot see: it checks
/// that start_joint_correction/mid_joint_correction are non-NULL, but only
/// after this function would already have pointed them at valid scratch
/// regardless of what the caller passed in ZozzIKTwoBoneJob. The check has to
/// happen here, against the caller's own pointers, before that substitution.
bool BuildTwoBone(const ZozzIKTwoBoneJob& in, ozz::animation::IKTwoBoneJob* out,
                  m::SimdQuaternion* start_scratch,
                  m::SimdQuaternion* mid_scratch, bool* reached_scratch) {
  if (in.start_joint == nullptr || in.mid_joint == nullptr ||
      in.end_joint == nullptr || in.start_joint_correction == nullptr ||
      in.mid_joint_correction == nullptr) {
    return false;
  }
  out->target = m::simd_float4::Load3PtrU(in.target);
  out->mid_axis = m::simd_float4::Load3PtrU(in.mid_axis);
  out->pole_vector = m::simd_float4::Load3PtrU(in.pole_vector);
  out->twist_angle = in.twist_angle;
  out->soften = in.soften;
  out->weight = in.weight;
  // ZozzFloat4x4 is layout- and alignment-compatible with ozz's Float4x4;
  // zozz_abi.cpp static_asserts both properties.
  out->start_joint = reinterpret_cast<const m::Float4x4*>(in.start_joint);
  out->mid_joint = reinterpret_cast<const m::Float4x4*>(in.mid_joint);
  out->end_joint = reinterpret_cast<const m::Float4x4*>(in.end_joint);
  out->start_joint_correction = start_scratch;
  out->mid_joint_correction = mid_scratch;
  out->reached = in.reached != nullptr ? reached_scratch : nullptr;
  return true;
}

bool BuildAim(const ZozzIKAimJob& in, ozz::animation::IKAimJob* out,
             m::SimdQuaternion* correction_scratch, bool* reached_scratch) {
  if (in.joint == nullptr || in.joint_correction == nullptr) {
    return false;
  }
  out->target = m::simd_float4::Load3PtrU(in.target);
  out->forward = m::simd_float4::Load3PtrU(in.forward);
  out->offset = m::simd_float4::Load3PtrU(in.offset);
  out->up = m::simd_float4::Load3PtrU(in.up);
  out->pole_vector = m::simd_float4::Load3PtrU(in.pole_vector);
  out->twist_angle = in.twist_angle;
  out->weight = in.weight;
  out->joint = reinterpret_cast<const m::Float4x4*>(in.joint);
  out->joint_correction = correction_scratch;
  out->reached = in.reached != nullptr ? reached_scratch : nullptr;
  return true;
}

}  // namespace

extern "C" {

void zozzIKTwoBoneJobDefaults(ZozzIKTwoBoneJob* out) {
  if (out == nullptr) return;
  const ozz::animation::IKTwoBoneJob defaults;
  m::Store3PtrU(defaults.target, out->target);
  m::Store3PtrU(defaults.mid_axis, out->mid_axis);
  m::Store3PtrU(defaults.pole_vector, out->pole_vector);
  out->twist_angle = defaults.twist_angle;
  out->soften = defaults.soften;
  out->weight = defaults.weight;
  out->start_joint = nullptr;
  out->mid_joint = nullptr;
  out->end_joint = nullptr;
  out->start_joint_correction = nullptr;
  out->mid_joint_correction = nullptr;
  out->reached = nullptr;
}

ZozzResult zozzIKTwoBoneJobRun(const ZozzIKTwoBoneJob* job) {
  if (job == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;

  ozz::animation::IKTwoBoneJob ozz_job;
  m::SimdQuaternion start_correction, mid_correction;
  bool reached = false;
  if (!BuildTwoBone(*job, &ozz_job, &start_correction, &mid_correction,
                    &reached)) {
    return ZOZZ_RESULT_INVALID_ARGUMENT;
  }

  // A job's Validate() returning false is a real error path, not an
  // assertion: ozz's own Run() would otherwise happily read the unnormalized
  // mid_axis it rejects. ZOZZ_RESULT_JOB_INVALID names that specifically,
  // apart from ZOZZ_RESULT_INVALID_ARGUMENT above, which is this layer's own
  // rejection of a null pointer BuildTwoBone could not even hand to ozz.
  if (!ozz_job.Validate()) return ZOZZ_RESULT_JOB_INVALID;
  if (!ozz_job.Run()) return ZOZZ_RESULT_JOB_INVALID;

  m::StorePtrU(start_correction.xyzw, job->start_joint_correction);
  m::StorePtrU(mid_correction.xyzw, job->mid_joint_correction);
  if (job->reached != nullptr) *job->reached = reached;
  return ZOZZ_RESULT_OK;
}

void zozzIKAimJobDefaults(ZozzIKAimJob* out) {
  if (out == nullptr) return;
  const ozz::animation::IKAimJob defaults;
  m::Store3PtrU(defaults.target, out->target);
  m::Store3PtrU(defaults.forward, out->forward);
  m::Store3PtrU(defaults.offset, out->offset);
  m::Store3PtrU(defaults.up, out->up);
  m::Store3PtrU(defaults.pole_vector, out->pole_vector);
  out->twist_angle = defaults.twist_angle;
  out->weight = defaults.weight;
  out->joint = nullptr;
  out->joint_correction = nullptr;
  out->reached = nullptr;
}

ZozzResult zozzIKAimJobRun(const ZozzIKAimJob* job) {
  if (job == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;

  ozz::animation::IKAimJob ozz_job;
  m::SimdQuaternion correction;
  bool reached = false;
  if (!BuildAim(*job, &ozz_job, &correction, &reached)) {
    return ZOZZ_RESULT_INVALID_ARGUMENT;
  }

  if (!ozz_job.Validate()) return ZOZZ_RESULT_JOB_INVALID;
  if (!ozz_job.Run()) return ZOZZ_RESULT_JOB_INVALID;

  m::StorePtrU(correction.xyzw, job->joint_correction);
  if (job->reached != nullptr) *job->reached = reached;
  return ZOZZ_RESULT_OK;
}

ZozzResult zozzSoaPoseApplyLocalCorrection(ZozzSoaPose* pose, int joint,
                                           const float correction[4]) {
  if (pose == nullptr || correction == nullptr) {
    return ZOZZ_RESULT_INVALID_ARGUMENT;
  }
  if (joint < 0 || joint >= pose->num_joints) {
    return ZOZZ_RESULT_INVALID_ARGUMENT;
  }

  const int block = joint / 4;
  const int lane = joint & 3;
  m::SoaTransform& soa = pose->data[block];

  // Transpose the block's rotation to one full quaternion per joint, replace
  // this joint's lane, and transpose back. Transpose4x4 is a real 4x4
  // transpose (not SoA/AoS-specific), so it is its own inverse: this is the
  // same operation zozz_pose.cpp's SoaToAos/AosToSoa use in both directions.
  const m::SimdFloat4 r_in[4] = {soa.rotation.x, soa.rotation.y,
                                 soa.rotation.z, soa.rotation.w};
  m::SimdFloat4 r_out[4];
  m::Transpose4x4(r_in, r_out);

  const m::SimdQuaternion delta = {m::simd_float4::LoadPtrU(correction)};
  const m::SimdQuaternion old_rotation = {r_out[lane]};
  const m::SimdQuaternion new_rotation = delta * old_rotation;
  r_out[lane] = new_rotation.xyzw;

  m::SimdFloat4 r_back[4];
  m::Transpose4x4(r_out, r_back);
  soa.rotation.x = r_back[0];
  soa.rotation.y = r_back[1];
  soa.rotation.z = r_back[2];
  soa.rotation.w = r_back[3];

  return ZOZZ_RESULT_OK;
}

}  // extern "C"
