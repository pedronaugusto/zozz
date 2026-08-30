//===----------------------------------------------------------------------===//
// zozz — operations over a caller-owned SoA pose: sizing, identity, and the
// conversions to and from AoS transforms.
//
// The pose itself is ZozzSoaTransform in zozz_core.h. There is no pose object
// here and no allocation: every function takes the caller's array and its
// length in SoA blocks, exactly as ozz's own jobs take an ozz::span.
//
// Conventions, ownership and thread safety are documented in zozz_core.h.
//===----------------------------------------------------------------------===//

#ifndef ZOZZ_POSE_H_
#define ZOZZ_POSE_H_

#include <stddef.h>

#include "zozz.h"

#ifdef __cplusplus
extern "C" {
#endif

/// SoA blocks needed for `num_joints`: ceil(num_joints / 4), which is what
/// ozz calls num_soa_joints. Returns 0 for a count below 1 or above
/// ZOZZ_MAX_JOINTS, so a caller that ignores the bound allocates nothing and
/// every call below then rejects the empty span.
ZOZZ_API size_t zozzSoaBlocks(int num_joints);

/// Fills every block with the identity transform.
ZOZZ_API ZozzResult zozzSoaPoseSetIdentity(ZozzSoaTransform* pose,
                                           size_t blocks);

/// SoA -> AoS for `num_joints` joints. `blocks` must cover them; joints in a
/// trailing partial block that `num_joints` does not reach are not written.
ZOZZ_API ZozzResult zozzSoaPoseToLocalTransforms(const ZozzSoaTransform* pose,
                                                 size_t blocks,
                                                 ZozzTransform* out,
                                                 size_t num_joints);

/// AoS -> SoA for `num_joints` joints. Lanes of a trailing partial block that
/// `num_joints` does not reach are filled with identity, so the whole span is
/// valid input to a job that reads it a block at a time.
ZOZZ_API ZozzResult zozzSoaPoseFromLocalTransforms(const ZozzTransform* in,
                                                   size_t num_joints,
                                                   ZozzSoaTransform* pose,
                                                   size_t blocks);

/// Packs `num_joints` flat per-joint weights into SoA registers, for
/// ZozzBlendingLayer::joint_weights. Lanes past `num_joints` are filled with
/// 1.0 -- the "fully weighted" meaning ozz gives an absent mask. Values are
/// not clamped: ozz treats a negative weight as 0, and above 1 is valid
/// wherever normalisation allows it. Every value must be finite.
ZOZZ_API ZozzResult zozzSoaWeightsPack(const float* in, size_t num_joints,
                                       ZozzSimdFloat4* out, size_t blocks);

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // ZOZZ_POSE_H_
