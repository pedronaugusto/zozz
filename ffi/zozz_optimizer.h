//===----------------------------------------------------------------------===//
// zozz — offline animation processing: optimization, sampling utilities,
// additive delta animations, and root-motion extraction, layered on the
// RawAnimation authored through zozz_offline.cpp. Included from zozz.h;
// safe to include directly too (header guards no-op it).
//
// ZozzOptimizerSetting and ZozzMotionSettings are passed by CONST POINTER,
// never by value, at every entry point below, including setters where a
// value would fit in one register: SysV and the Windows x64 ABI disagree on
// whether such an aggregate passes in registers or by hidden reference, and
// a pointer is unambiguous on both.
//===----------------------------------------------------------------------===//

#ifndef ZOZZ_OPTIMIZER_H_
#define ZOZZ_OPTIMIZER_H_

#include <stdbool.h>
#include <stddef.h>

#include "zozz.h"

#ifdef __cplusplus
extern "C" {
#endif

//===----------------------------------------------------------------------===//
// Animation optimizer
//
// Key-frame reduction within an error tolerance, evaluated hierarchically: the
// error a joint's decimation would produce is measured out to `distance` past
// the joint, so an aggressive shoulder tolerance cannot silently blow up at
// the fingers. `setting` is the default applied to every joint; a per-joint
// override replaces it for one joint's chain.
//===----------------------------------------------------------------------===//

typedef struct ZozzAnimationOptimizer ZozzAnimationOptimizer;

typedef struct ZozzOptimizerSetting {
  /// Maximum error the optimizer may introduce on a whole joint hierarchy, in
  /// model-space units. Must be finite and >= 0. ozz's own default is 1e-3
  /// (1mm at a 1-unit-per-meter scale).
  float tolerance;
  /// Distance from the joint, past its own hierarchy, at which error is still
  /// measured (emulates the effect on skinned geometry beyond the last
  /// joint). Must be finite and >= 0. ozz's own default is 1e-1 (10cm).
  float distance;
} ZozzOptimizerSetting;

/// Allocates an optimizer with ozz's default setting (tolerance 1e-3,
/// distance 1e-1) and no per-joint overrides.
ZOZZ_API ZozzResult zozzAnimationOptimizerCreate(ZozzAnimationOptimizer** out);

ZOZZ_API void zozzAnimationOptimizerDestroy(ZozzAnimationOptimizer* optimizer);

/// Replaces the default setting applied to every joint not otherwise
/// overridden. `setting` is read only for the duration of the call.
ZOZZ_API ZozzResult zozzAnimationOptimizerSetSetting(
    ZozzAnimationOptimizer* optimizer, const ZozzOptimizerSetting* setting);

ZOZZ_API ZozzResult zozzAnimationOptimizerGetSetting(
    const ZozzAnimationOptimizer* optimizer, ZozzOptimizerSetting* out);

/// Overrides the setting for one joint's chain. `joint` is a built-skeleton
/// index (see zozz_offline.cpp for the depth-first index mapping); it is not
/// checked against any particular skeleton here, only rejected if negative —
/// the joint a given index names is a property of whichever skeleton
/// zozzAnimationOptimizerRun is later called with. `setting` is read only for
/// the duration of the call.
ZOZZ_API ZozzResult zozzAnimationOptimizerSetJointOverride(
    ZozzAnimationOptimizer* optimizer, int32_t joint,
    const ZozzOptimizerSetting* setting);

/// Removes a joint's override, if any. Not an error if `joint` had none.
ZOZZ_API ZozzResult zozzAnimationOptimizerClearJointOverride(
    ZozzAnimationOptimizer* optimizer, int32_t joint);

/// Runs the optimizer over `input`, writing the decimated clip to
/// `output`; `output` must be a distinct, already-created raw animation
/// (from zozzRawAnimationCreate) whose contents are discarded even on
/// failure. `skeleton` must match `input`'s joint/track count, else
/// ZOZZ_RESULT_SKELETON_MISMATCH; fails ZOZZ_RESULT_INVALID_DATA if `input`
/// fails RawAnimation validation (zozzAnimationBuild).
ZOZZ_API ZozzResult zozzAnimationOptimizerRun(
    const ZozzAnimationOptimizer* optimizer, const ZozzRawAnimation* input,
    const ZozzSkeleton* skeleton, ZozzRawAnimation* output);

//===----------------------------------------------------------------------===//
// Raw-animation sampling and re-timing utilities
//
// For offline use only (preview, re-timing, cooking) — not a substitute for
// zozzSample, which is the runtime path over a built ZozzAnimation.
//===----------------------------------------------------------------------===//

/// Samples one track of `raw` at `time` (seconds; clamped to the track's own
/// first/last key outside its range) into `out`. Fails with
/// ZOZZ_RESULT_INVALID_DATA if the track does not pass validation (keys out
/// of time order).
ZOZZ_API ZozzResult zozzRawAnimationSampleTrack(const ZozzRawAnimation* raw,
                                                int32_t track, float time,
                                                ZozzTransform* out);

/// Samples every track of `raw` at `time` into `out`. `count` must be at
/// least zozzRawAnimationNumTracks, else ZOZZ_RESULT_BUFFER_TOO_SMALL; any
/// slots past the track count are filled with the identity transform.
ZOZZ_API ZozzResult zozzRawAnimationSample(const ZozzRawAnimation* raw,
                                           float time, ZozzTransform* out,
                                           size_t count);

/// Writes the sorted, de-duplicated union of every keyframe time across all
/// tracks of `raw`. Two-call convention: pass `out` as NULL to learn the count
/// without writing anything (`*out_count` is filled, and the call succeeds);
/// pass a real buffer once `count` is known to be at least that large, else
/// ZOZZ_RESULT_BUFFER_TOO_SMALL. Fails ZOZZ_RESULT_INVALID_DATA if `raw` does
/// not pass validation.
ZOZZ_API ZozzResult zozzRawAnimationExtractTimePoints(const ZozzRawAnimation* raw,
                                                      float* out, size_t count,
                                                      size_t* out_count);

/// One keyframe of a MODEL-space sample: `time` in the animation's own
/// seconds, `transform` the sampled joint's model-space matrix at that time.
typedef struct ZozzModelSpaceSample {
  float time;
  ZozzFloat4x4 transform;
} ZozzModelSpaceSample;

/// Samples `raw`'s `joint` in MODEL space, at every keyframe on it or an
/// ancestor. `skeleton` must match `raw`'s track count, else
/// ZOZZ_RESULT_SKELETON_MISMATCH; `joint` must be a valid index into it, else
/// ZOZZ_RESULT_INVALID_ARGUMENT; `raw` must pass validation, else
/// ZOZZ_RESULT_INVALID_DATA. Two-call: `out` NULL to learn the count, else a
/// buffer of that many ZozzModelSpaceSample, or ZOZZ_RESULT_BUFFER_TOO_SMALL.
ZOZZ_API ZozzResult zozzRawAnimationSampleTrackModelSpace(
    const ZozzRawAnimation* raw, const ZozzSkeleton* skeleton, int32_t joint,
    ZozzModelSpaceSample* out, size_t count, size_t* out_count);

/// Fixed-period sample times over `[0, duration]`: `num_keys` keys spaced
/// `1/frequency` apart, with the last key clamped to `duration` exactly
/// rather than drifting past it from accumulated floating-point error.
/// `duration` must be finite and >= 0; `frequency` must be finite and > 0.
typedef struct ZozzFixedRateSamplingTime ZozzFixedRateSamplingTime;

ZOZZ_API ZozzResult zozzFixedRateSamplingTimeCreate(
    float duration, float frequency, ZozzFixedRateSamplingTime** out);

ZOZZ_API void zozzFixedRateSamplingTimeDestroy(ZozzFixedRateSamplingTime* self);

ZOZZ_API size_t
zozzFixedRateSamplingTimeNumKeys(const ZozzFixedRateSamplingTime* self);

/// Time of the `key`-th sample. `key` must be < zozzFixedRateSamplingTimeNumKeys,
/// else ZOZZ_RESULT_INVALID_ARGUMENT.
ZOZZ_API ZozzResult zozzFixedRateSamplingTimeAt(
    const ZozzFixedRateSamplingTime* self, size_t key, float* out);

//===----------------------------------------------------------------------===//
// Additive animation builder
//
// Turns an absolute-pose clip into a delta clip suitable for additive
// blending: every key becomes "how far past the reference" rather than "the
// absolute transform". Stateless — no create/destroy, just the two forms of
// the call.
//===----------------------------------------------------------------------===//

/// Builds a delta animation from `input` using its OWN first frame as the
/// reference pose, per joint. `output` must be a distinct, already-created
/// raw animation; its previous contents are discarded even on failure.
/// Fails with ZOZZ_RESULT_INVALID_DATA if `input` does not pass validation.
ZOZZ_API ZozzResult zozzAdditiveAnimationBuilderRun(const ZozzRawAnimation* input,
                                                    ZozzRawAnimation* output);

/// As above, but the reference pose is supplied explicitly: one transform per
/// track of `input`. `reference_pose_count` must be at least
/// zozzRawAnimationNumTracks(input), else ZOZZ_RESULT_INVALID_DATA (a short
/// reference pose is treated as a data problem, not an argument-shape one).
/// `reference_pose` is read only for the duration of the call.
ZOZZ_API ZozzResult zozzAdditiveAnimationBuilderRunWithReference(
    const ZozzRawAnimation* input, const ZozzTransform* reference_pose,
    size_t reference_pose_count, ZozzRawAnimation* output);

//===----------------------------------------------------------------------===//
// Motion extractor
//
// Pulls root motion (translation and/or rotation, axis by axis) out of the
// root joint of a clip into separate tracks, optionally baking its inverse
// back into the remaining animation so the two recombine to the original
// motion at runtime.
//===----------------------------------------------------------------------===//

/// Which pose the extracted motion is measured against.
typedef enum ZozzMotionReference {
  /// Global / absolute reference: the extracted value IS the root's raw
  /// component, unshifted.
  ZOZZ_MOTION_REFERENCE_ABSOLUTE = 0,
  /// The skeleton's rest-pose root transform.
  ZOZZ_MOTION_REFERENCE_SKELETON = 1,
  /// The animation's own first frame.
  ZOZZ_MOTION_REFERENCE_ANIMATION = 2,
} ZozzMotionReference;

typedef struct ZozzMotionSettings {
  /// Extract the X, Y, Z components respectively (translation: axes;
  /// rotation: decomposed pitch/yaw/roll about X/Y/Z).
  bool x, y, z;
  ZozzMotionReference reference;
  /// Bake the extracted (inverse) motion back into the output animation.
  bool bake;
  /// Redistribute the first/last-key difference across the whole duration so
  /// the extracted track loops seamlessly.
  bool loop;
} ZozzMotionSettings;

typedef struct ZozzMotionExtractor ZozzMotionExtractor;

/// Allocates an extractor with ozz's defaults: root_joint 0; position
/// extracts X/Z against the skeleton reference, baked, not looped; rotation
/// extracts Y (yaw) against the skeleton reference, baked, not looped.
ZOZZ_API ZozzResult zozzMotionExtractorCreate(ZozzMotionExtractor** out);

ZOZZ_API void zozzMotionExtractorDestroy(ZozzMotionExtractor* extractor);

/// Index of the joint root motion is extracted from. Must be >= 0; whether it
/// is in range for a particular skeleton is checked at Run.
ZOZZ_API ZozzResult zozzMotionExtractorSetRootJoint(
    ZozzMotionExtractor* extractor, int32_t joint);

ZOZZ_API int32_t
zozzMotionExtractorGetRootJoint(const ZozzMotionExtractor* extractor);

/// `settings` is read only for the duration of the call.
ZOZZ_API ZozzResult zozzMotionExtractorSetPositionSettings(
    ZozzMotionExtractor* extractor, const ZozzMotionSettings* settings);

ZOZZ_API ZozzResult zozzMotionExtractorGetPositionSettings(
    const ZozzMotionExtractor* extractor, ZozzMotionSettings* out);

/// `settings` is read only for the duration of the call.
ZOZZ_API ZozzResult zozzMotionExtractorSetRotationSettings(
    ZozzMotionExtractor* extractor, const ZozzMotionSettings* settings);

ZOZZ_API ZozzResult zozzMotionExtractorGetRotationSettings(
    const ZozzMotionExtractor* extractor, ZozzMotionSettings* out);

/// Extracts motion from `input`'s root joint into `motion_position` and
/// `motion_rotation`, writing the optionally-baked remainder to `output`. All
/// three must be distinct, pre-created (`output` != `input`, checked); prior
/// contents are discarded on failure. `skeleton` must match `input`'s track
/// count, else ZOZZ_RESULT_SKELETON_MISMATCH; else ZOZZ_RESULT_INVALID_DATA if
/// `input` fails validation or the root joint is out of range.
ZOZZ_API ZozzResult zozzMotionExtractorRun(
    const ZozzMotionExtractor* extractor, const ZozzRawAnimation* input,
    const ZozzSkeleton* skeleton, ZozzRawFloat3Track* motion_position,
    ZozzRawQuaternionTrack* motion_rotation, ZozzRawAnimation* output);

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // ZOZZ_OPTIMIZER_H_
