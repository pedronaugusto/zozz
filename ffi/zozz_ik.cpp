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
/// three output fields at caller-supplied scratch; returns false, `out`
/// untouched, if a required pointer is NULL. Ozz's own Validate() cannot
/// catch a NULL here: it checks start_joint_correction/mid_joint_correction
/// only after this function has already pointed them at scratch, so this
/// function must reject NULL first, against the caller's own pointers.
bool BuildTwoBone(const ZozzIKTwoBoneJob& in, ozz::animation::IKTwoBoneJob* out,
                  m::SimdQuaternion* start_scratch,
                  m::SimdQuaternion* mid_scratch, bool* reached_scratch) {
  if (in.start_joint == nullptr || in.mid_joint == nullptr ||
      in.end_joint == nullptr || in.start_joint_correction == nullptr ||
      in.mid_joint_correction == nullptr) {
    return false;
  }
  out->target = *zozz::AsOzz(&in.target);
  out->mid_axis = *zozz::AsOzz(&in.mid_axis);
  out->pole_vector = *zozz::AsOzz(&in.pole_vector);
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
  out->target = *zozz::AsOzz(&in.target);
  out->forward = *zozz::AsOzz(&in.forward);
  out->offset = *zozz::AsOzz(&in.offset);
  out->up = *zozz::AsOzz(&in.up);
  out->pole_vector = *zozz::AsOzz(&in.pole_vector);
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
  *zozz::AsOzz(&out->target) = defaults.target;
  *zozz::AsOzz(&out->mid_axis) = defaults.mid_axis;
  *zozz::AsOzz(&out->pole_vector) = defaults.pole_vector;
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

  *zozz::AsOzz(job->start_joint_correction) = start_correction.xyzw;
  *zozz::AsOzz(job->mid_joint_correction) = mid_correction.xyzw;
  if (job->reached != nullptr) *job->reached = reached;
  return ZOZZ_RESULT_OK;
}

void zozzIKAimJobDefaults(ZozzIKAimJob* out) {
  if (out == nullptr) return;
  const ozz::animation::IKAimJob defaults;
  *zozz::AsOzz(&out->target) = defaults.target;
  *zozz::AsOzz(&out->forward) = defaults.forward;
  *zozz::AsOzz(&out->offset) = defaults.offset;
  *zozz::AsOzz(&out->up) = defaults.up;
  *zozz::AsOzz(&out->pole_vector) = defaults.pole_vector;
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

  *zozz::AsOzz(job->joint_correction) = correction.xyzw;
  if (job->reached != nullptr) *job->reached = reached;
  return ZOZZ_RESULT_OK;
}

ZozzResult zozzSoaPoseApplyLocalCorrections(
    ZozzSoaTransform* pose, size_t blocks,
    const ZozzJointCorrection* corrections, size_t count) {
  if (count == 0) return ZOZZ_RESULT_OK;
  if (pose == nullptr || corrections == nullptr) {
    return ZOZZ_RESULT_INVALID_ARGUMENT;
  }
  if (!zozz::IsAligned16(pose)) return ZOZZ_RESULT_INVALID_ARGUMENT;
  for (size_t i = 0; i < count; ++i) {
    const int32_t joint = corrections[i].joint;
    if (joint < 0 || static_cast<size_t>(joint) / 4 >= blocks) {
      return ZOZZ_RESULT_INVALID_ARGUMENT;
    }
  }

  m::SoaTransform* soa = zozz::AsOzz(pose);
  size_t i = 0;
  while (i < count) {
    const int32_t block = corrections[i].joint / 4;

    // Transpose the block's rotation to one full quaternion per joint, edit
    // the lanes this run names, and transpose back. Transpose4x4 is a real
    // 4x4 transpose (not SoA/AoS-specific), so it is its own inverse: the
    // same operation zozz_pose.cpp's SoaToAos/AosToSoa use in both
    // directions. Hoisting it over a run of same-block corrections is why a
    // whole IK pass costs one call and, usually, one transpose pair.
    const m::SimdFloat4 r_in[4] = {soa[block].rotation.x, soa[block].rotation.y,
                                   soa[block].rotation.z,
                                   soa[block].rotation.w};
    m::SimdFloat4 r_out[4];
    m::Transpose4x4(r_in, r_out);

    for (; i < count && corrections[i].joint / 4 == block; ++i) {
      const int32_t lane = corrections[i].joint & 3;
      const m::SimdQuaternion delta = {*zozz::AsOzz(&corrections[i].rotation)};
      const m::SimdQuaternion old_rotation = {r_out[lane]};
      r_out[lane] = (delta * old_rotation).xyzw;
    }

    m::SimdFloat4 r_back[4];
    m::Transpose4x4(r_out, r_back);
    soa[block].rotation.x = r_back[0];
    soa[block].rotation.y = r_back[1];
    soa[block].rotation.z = r_back[2];
    soa[block].rotation.w = r_back[3];
  }

  return ZOZZ_RESULT_OK;
}

}  // extern "C"
