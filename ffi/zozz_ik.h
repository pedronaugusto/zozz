//===----------------------------------------------------------------------===//
// zozz — two-bone and single-joint inverse kinematics.
//
// Conventions, ownership and thread safety are documented in zozz_core.h.
//===----------------------------------------------------------------------===//

#ifndef ZOZZ_IK_H_
#define ZOZZ_IK_H_

#include <stddef.h>

#include "zozz.h"

#ifndef __cplusplus
#include <stdbool.h>
#endif

#ifdef __cplusplus
extern "C" {
#endif

//===----------------------------------------------------------------------===//
// Two-bone IK
//
// Solves a three-joint chain (two bones) so its end reaches a target
// position, writing the local-space rotation corrections for the chain's
// first two joints. Fold the corrections into a pose with
// zozzSoaPoseApplyLocalCorrections before the next model-space update.
//
// Vectors and quaternions here are ZozzSimdFloat4, which is what ozz's own
// job fields are. A caller working from model-space matrices already holds
// them in that form, and a scalar caller writes {x, y, z, 0}.
//===----------------------------------------------------------------------===//

typedef struct ZozzIKTwoBoneJob {
  /// Target position to reach, in model-space. w is ignored.
  ZozzSimdFloat4 target;
  /// Middle joint's rotation axis, in middle-joint local-space. Must be
  /// normalized: zozzIKTwoBoneJobDefaults sets it to the z axis, and
  /// zozzIKTwoBoneJobRun refuses anything else.
  ZozzSimdFloat4 mid_axis;
  /// Pole vector, in model-space: controls which way the chain bends.
  ZozzSimdFloat4 pole_vector;
  /// Rotates the chain around the start-to-target vector. Default 0.
  float twist_angle;
  /// Fraction of the chain's reach, measured back from full extension, over
  /// which the chain gradually falls behind an out-of-range target instead
  /// of snapping straight. Default 1.
  float soften;
  /// Blends the correction: 0 leaves the pose untouched, 1 applies it in
  /// full. Unlike mid_axis, this is NOT checked by Validate() — a weight of 0
  /// is accepted and silently produces an identity correction.
  /// zozzIKTwoBoneJobDefaults sets it to 1 instead of leaving a caller to
  /// zero-initialize the struct and get that by accident.
  float weight;

  /// Model-space matrices of the chain's three joints. They must be
  /// ancestors of one another but need not be direct ancestors. Borrowed for
  /// the call only.
  const ZozzFloat4x4* start_joint;
  const ZozzFloat4x4* mid_joint;
  const ZozzFloat4x4* end_joint;

  /// Required. On success, the local-space correction to left-multiply onto
  /// start_joint's/mid_joint's current local rotation (xyzw, w LAST) is
  /// written here. Points to caller-owned, 16-byte aligned storage; left
  /// untouched on failure.
  ZozzSimdFloat4* start_joint_correction;
  ZozzSimdFloat4* mid_joint_correction;

  /// Optional (NULL to ignore). On success, set to true if the target was
  /// reachable, false otherwise. Left untouched on failure.
  bool* reached;
} ZozzIKTwoBoneJob;

/// Fills `out` with ozz's own defaults: z-axis mid_axis, y-axis pole_vector,
/// zero target and twist, soften and weight both at 1. Joint pointers and
/// outputs are left NULL. A no-op if `out` is NULL.
ZOZZ_API void zozzIKTwoBoneJobDefaults(ZozzIKTwoBoneJob* out);

/// Runs the job. Returns ZOZZ_RESULT_INVALID_ARGUMENT if `job` is NULL or if
/// any of the three joint pointers or either correction output is NULL.
/// Returns ZOZZ_RESULT_JOB_INVALID if the job's own Validate() rejects it (an
/// unnormalized mid_axis).
ZOZZ_API ZozzResult zozzIKTwoBoneJobRun(const ZozzIKTwoBoneJob* job);

//===----------------------------------------------------------------------===//
// Aim IK
//
// Rotates a single joint so a forward vector, in the joint's local-space,
// aims at a target position in model-space.
//===----------------------------------------------------------------------===//

typedef struct ZozzIKAimJob {
  /// Target position to aim at, in model-space. w is ignored.
  ZozzSimdFloat4 target;
  /// Joint's forward axis, in joint local-space, to aim at the target. Must
  /// be normalized: zozzIKAimJobDefaults sets it to the x axis, and
  /// zozzIKAimJobRun refuses anything else.
  ZozzSimdFloat4 forward;
  /// Offset, in joint local-space, of the point that aims at the target.
  /// Default zero.
  ZozzSimdFloat4 offset;
  /// Joint's up axis, in joint local-space, kept aligned with pole_vector.
  /// Default y axis.
  ZozzSimdFloat4 up;
  /// Pole vector, in model-space: controls which way "up" points.
  ZozzSimdFloat4 pole_vector;
  /// Rotates the joint around the target vector. Default 0.
  float twist_angle;
  /// Blends the correction: 0 leaves the pose untouched, 1 applies it in
  /// full. NOT checked by Validate() — see ZozzIKTwoBoneJob.weight.
  float weight;

  /// Joint's model-space matrix. Borrowed for the call only.
  const ZozzFloat4x4* joint;

  /// Required. On success, the local-space correction to left-multiply onto
  /// joint's current local rotation (xyzw, w LAST) is written here. Points
  /// to caller-owned, 16-byte aligned storage; left untouched on failure.
  ZozzSimdFloat4* joint_correction;

  /// Optional (NULL to ignore). On success, set to true if the target was
  /// reachable, false otherwise. Left untouched on failure.
  bool* reached;
} ZozzIKAimJob;

/// Fills `out` with ozz's own defaults: x-axis forward, zero target/offset,
/// y-axis up and pole_vector, zero twist, weight at 1. The joint pointer and
/// output are left NULL. A no-op if `out` is NULL.
ZOZZ_API void zozzIKAimJobDefaults(ZozzIKAimJob* out);

/// Runs the job. Returns ZOZZ_RESULT_INVALID_ARGUMENT if `job` is NULL or if
/// `joint` or `joint_correction` is NULL. Returns ZOZZ_RESULT_JOB_INVALID if
/// the job's own Validate() rejects it (an unnormalized forward vector).
ZOZZ_API ZozzResult zozzIKAimJobRun(const ZozzIKAimJob* job);

//===----------------------------------------------------------------------===//
// Folding a correction back into a pose
//===----------------------------------------------------------------------===//

/// One joint's local-space rotation correction, as an IK job produces it.
typedef struct ZozzJointCorrection {
  /// Rotation to left-multiply onto the joint's current local rotation
  /// (xyzw, w LAST) — an IK job's *_joint_correction, unchanged.
  ZozzSimdFloat4 rotation;
  /// Joint index within the pose.
  int32_t joint;
} ZozzJointCorrection;

/// Left-multiplies each correction onto its joint's current local rotation in
/// `pose`, in place: pose[joint].rotation = rotation * pose[joint].rotation.
/// Translation and scale, and every joint not named, are left untouched. A
/// whole IK pass is one call, and corrections landing in the same SoA block
/// share one transpose. Every index is checked BEFORE anything is written, so
/// on ZOZZ_RESULT_INVALID_ARGUMENT the pose is exactly as it was.
ZOZZ_API ZozzResult zozzSoaPoseApplyLocalCorrections(
    ZozzSoaTransform* pose, size_t blocks,
    const ZozzJointCorrection* corrections, size_t count);

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // ZOZZ_IK_H_
