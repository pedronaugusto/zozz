//===----------------------------------------------------------------------===//
// zozz — poses in ozz's structure-of-arrays layout.
//
// Conventions, ownership and thread safety are documented in zozz_core.h.
//===----------------------------------------------------------------------===//

#ifndef ZOZZ_POSE_H_
#define ZOZZ_POSE_H_

#include <stddef.h>

#include "zozz_core.h"
#include "zozz_skeleton.h"

#ifdef __cplusplus
extern "C" {
#endif

/// A pose held in ozz's native structure-of-arrays layout.
///
/// SoA is the currency of ozz's job pipeline: sampling writes it, blending
/// consumes and produces it, local-to-model reads it. Keeping it opaque means
/// consumers never depend on the SIMD layout, while still being able to chain
/// jobs without a conversion per step. Convert to AoS only at the edges, with
/// zozzSoaPoseToLocalTransforms.
typedef struct ZozzSoaPose ZozzSoaPose;

/// Allocates a pose buffer sized for `num_joints` (rounded up to a SoA block).
ZOZZ_API ZozzResult zozzSoaPoseCreate(int num_joints, ZozzSoaPose** out);

ZOZZ_API void zozzSoaPoseDestroy(ZozzSoaPose* pose);

ZOZZ_API int zozzSoaPoseNumJoints(const ZozzSoaPose* pose);

/// Fills the pose with identity transforms.
ZOZZ_API ZozzResult zozzSoaPoseSetIdentity(ZozzSoaPose* pose);

/// Fills the pose from a skeleton's rest pose. Joint counts must match.
ZOZZ_API ZozzResult zozzSoaPoseSetRestPose(ZozzSoaPose* pose,
                                           const ZozzSkeleton* skeleton);

/// SoA -> AoS. `count` must be at least zozzSoaPoseNumJoints.
ZOZZ_API ZozzResult zozzSoaPoseToLocalTransforms(const ZozzSoaPose* pose,
                                                 ZozzTransform* out,
                                                 size_t count);

/// AoS -> SoA. `count` must be at least zozzSoaPoseNumJoints. Joints in the
/// trailing partial SoA block are padded with identity.
ZOZZ_API ZozzResult zozzSoaPoseFromLocalTransforms(ZozzSoaPose* pose,
                                                   const ZozzTransform* in,
                                                   size_t count);

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // ZOZZ_POSE_H_
