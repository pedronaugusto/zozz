//===----------------------------------------------------------------------===//
// zozz — raw tracks, TrackBuilder, TrackOptimizer. See ffi/zozz_rawtrack.h.
//
// Validation split, uniformly with zozz_offline.cpp: a keyframe's ratio has a
// fixed [0, 1] range (unlike a raw animation's caller-chosen duration), so it
// is checked eagerly at push with ZOZZ_RESULT_INVALID_ARGUMENT; ordering
// across keys is a data-shape property only RawTrack::Validate() can judge,
// and surfaces at Build/Optimize as ZOZZ_RESULT_INVALID_DATA. Nothing
// asserts.
//===----------------------------------------------------------------------===//

#include <cmath>
#include <cstdint>

#include "ozz/animation/offline/raw_track.h"
#include "ozz/animation/offline/track_builder.h"
#include "ozz/animation/offline/track_optimizer.h"
#include "ozz/animation/runtime/track.h"
#include "ozz/base/memory/unique_ptr.h"
#include "zozz_internal.h"
#include "zozz_track_types.h"

namespace {

bool FiniteN(const float* v, int n) {
  for (int i = 0; i < n; ++i) {
    if (!std::isfinite(v[i])) return false;
  }
  return true;
}

// Takes the raw integer, not ZozzTrackInterpolation — see RawEnum in
// zozz_internal.h. Passing the enum by value anywhere, even to a helper
// meant to validate it, is itself a load of the enum, and undefined when a
// host passes a value no enumerator names. The value is converted once, with
// zozz::RawEnum, at the entry point that receives it, and travels as a
// number from there.
bool ValidInterpolation(int32_t interpolation) {
  return interpolation == ZOZZ_TRACK_INTERPOLATION_STEP ||
         interpolation == ZOZZ_TRACK_INTERPOLATION_LINEAR;
}

ozz::animation::offline::RawTrackInterpolation::Value ToOzz(
    int32_t interpolation) {
  return interpolation == ZOZZ_TRACK_INTERPOLATION_STEP
             ? ozz::animation::offline::RawTrackInterpolation::kStep
             : ozz::animation::offline::RawTrackInterpolation::kLinear;
}

/// Shared push-keyframe argument validation across all five track types.
ZozzResult CheckPushKeyframe(int32_t interpolation, float ratio,
                             const float* value, int value_count) {
  if (value == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  if (!ValidInterpolation(interpolation)) return ZOZZ_RESULT_INVALID_ARGUMENT;
  if (!std::isfinite(ratio) || ratio < 0.f || ratio > 1.f) {
    return ZOZZ_RESULT_INVALID_ARGUMENT;
  }
  if (!FiniteN(value, value_count)) return ZOZZ_RESULT_INVALID_ARGUMENT;
  return ZOZZ_RESULT_OK;
}

/// Shared optimize-argument validation: null/self-alias/tolerance range.
ZozzResult CheckOptimize(const void* input, const void* output,
                         float tolerance) {
  if (input == nullptr || output == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  if (input == output) return ZOZZ_RESULT_INVALID_ARGUMENT;
  if (!std::isfinite(tolerance) || tolerance < 0.f) {
    return ZOZZ_RESULT_INVALID_ARGUMENT;
  }
  return ZOZZ_RESULT_OK;
}

/// The float the C keyframe structs store their value in. A single-channel
/// track's key carries a bare float and the others carry an array, so the
/// destination is reached through an overload rather than by name — which is
/// what lets one template below serve all five value types.
float* ValuePtr(float& value) { return &value; }
float* ValuePtr(float (&value)[2]) { return value; }
float* ValuePtr(float (&value)[3]) { return value; }
float* ValuePtr(float (&value)[4]) { return value; }

void WriteValue(float* out, float value) { out[0] = value; }

void WriteValue(float* out, const ozz::math::Float2& value) {
  out[0] = value.x;
  out[1] = value.y;
}

void WriteValue(float* out, const ozz::math::Float3& value) {
  out[0] = value.x;
  out[1] = value.y;
  out[2] = value.z;
}

void WriteValue(float* out, const ozz::math::Float4& value) {
  out[0] = value.x;
  out[1] = value.y;
  out[2] = value.z;
  out[3] = value.w;
}

void WriteValue(float* out, const ozz::math::Quaternion& value) {
  out[0] = value.x;
  out[1] = value.y;
  out[2] = value.z;
  out[3] = value.w;
}

/// Shared keyframe read-back across all five track types. Caller-owned
/// memory, exact-or-larger capacity, nothing written on a short buffer — the
/// same contract zozz_track.h's runtime read-back has.
template <typename Handle, typename Key>
ZozzResult RawTrackKeyframes(const Handle* raw, Key* out, size_t count) {
  if (raw == nullptr || out == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  const auto& keys = raw->impl.keyframes;
  if (count < keys.size()) return ZOZZ_RESULT_BUFFER_TOO_SMALL;
  for (size_t i = 0; i < keys.size(); ++i) {
    out[i].interpolation =
        keys[i].interpolation ==
                ozz::animation::offline::RawTrackInterpolation::kStep
            ? ZOZZ_TRACK_INTERPOLATION_STEP
            : ZOZZ_TRACK_INTERPOLATION_LINEAR;
    out[i].ratio = keys[i].ratio;
    WriteValue(ValuePtr(out[i].value), keys[i].value);
  }
  return ZOZZ_RESULT_OK;
}

template <typename Handle>
ZozzResult RawTrackSetName(Handle* raw, const char* name) {
  if (raw == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  raw->impl.name = name == nullptr ? "" : name;
  return ZOZZ_RESULT_OK;
}

template <typename Handle>
ZozzResult RawTrackClear(Handle* raw) {
  if (raw == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  raw->impl.keyframes.clear();
  return ZOZZ_RESULT_OK;
}

}  // namespace

//===----------------------------------------------------------------------===//
// Runtime track handle types (global namespace — must match the C tag names)
//
// Nothing outside this translation unit reads or writes these: only
// TrackBuilder produces them and only zozz*TrackDestroy consumes them.
//===----------------------------------------------------------------------===//

extern "C" {

//===----------------------------------------------------------------------===//
// RawFloatTrack
//===----------------------------------------------------------------------===//

ZozzResult zozzRawFloatTrackCreate(ZozzRawFloatTrack** out) {
  if (out == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  *out = nullptr;
  ZozzRawFloatTrack* raw = zozz::New<ZozzRawFloatTrack>();
  if (raw == nullptr) return ZOZZ_RESULT_OUT_OF_MEMORY;
  *out = raw;
  return ZOZZ_RESULT_OK;
}

void zozzRawFloatTrackDestroy(ZozzRawFloatTrack* raw) { zozz::Delete(raw); }

int zozzRawFloatTrackNumKeyframes(const ZozzRawFloatTrack* raw) {
  return raw == nullptr ? 0 : static_cast<int>(raw->impl.keyframes.size());
}

ZozzResult zozzRawFloatTrackPushKeyframe(ZozzRawFloatTrack* raw,
                                         ZozzTrackInterpolation interpolation,
                                         float ratio, float value) {
  if (raw == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  const int32_t interp = zozz::RawEnum(interpolation);
  const ZozzResult check = CheckPushKeyframe(interp, ratio, &value, 1);
  if (check != ZOZZ_RESULT_OK) return check;
  raw->impl.keyframes.push_back({ToOzz(interp), ratio, value});
  return ZOZZ_RESULT_OK;
}

ZozzResult zozzFloatTrackBuild(const ZozzRawFloatTrack* raw,
                               ZozzFloatTrack** out) {
  if (raw == nullptr || out == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  *out = nullptr;
  if (!raw->impl.Validate()) return ZOZZ_RESULT_INVALID_DATA;

  const ozz::animation::offline::TrackBuilder builder;
  ozz::unique_ptr<ozz::animation::FloatTrack> built = builder(raw->impl);
  if (!built) return ZOZZ_RESULT_OUT_OF_MEMORY;

  ZozzFloatTrack* track = zozz::New<ZozzFloatTrack>();
  if (track == nullptr) return ZOZZ_RESULT_OUT_OF_MEMORY;
  track->impl = std::move(*built);
  *out = track;
  return ZOZZ_RESULT_OK;
}

ZozzResult zozzRawFloatTrackOptimize(const ZozzRawFloatTrack* input,
                                     float tolerance,
                                     ZozzRawFloatTrack* output) {
  const ZozzResult check = CheckOptimize(input, output, tolerance);
  if (check != ZOZZ_RESULT_OK) return check;

  ozz::animation::offline::TrackOptimizer optimizer;
  optimizer.tolerance = tolerance;
  const bool ok = optimizer(input->impl, &output->impl);
  return ok ? ZOZZ_RESULT_OK : ZOZZ_RESULT_INVALID_DATA;
}

bool zozzRawFloatTrackValidate(const ZozzRawFloatTrack* raw) {
  return raw != nullptr && raw->impl.Validate();
}

const char* zozzRawFloatTrackName(const ZozzRawFloatTrack* raw) {
  return raw == nullptr ? nullptr : raw->impl.name.c_str();
}

ZozzResult zozzRawFloatTrackSetName(ZozzRawFloatTrack* raw, const char* name) {
  return RawTrackSetName(raw, name);
}

ZozzResult zozzRawFloatTrackKeyframes(const ZozzRawFloatTrack* raw,
                                      ZozzRawFloatKeyframe* out, size_t count) {
  return RawTrackKeyframes(raw, out, count);
}

ZozzResult zozzRawFloatTrackClear(ZozzRawFloatTrack* raw) {
  return RawTrackClear(raw);
}

//===----------------------------------------------------------------------===//
// RawFloat2Track
//===----------------------------------------------------------------------===//

ZozzResult zozzRawFloat2TrackCreate(ZozzRawFloat2Track** out) {
  if (out == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  *out = nullptr;
  ZozzRawFloat2Track* raw = zozz::New<ZozzRawFloat2Track>();
  if (raw == nullptr) return ZOZZ_RESULT_OUT_OF_MEMORY;
  *out = raw;
  return ZOZZ_RESULT_OK;
}

void zozzRawFloat2TrackDestroy(ZozzRawFloat2Track* raw) { zozz::Delete(raw); }

int zozzRawFloat2TrackNumKeyframes(const ZozzRawFloat2Track* raw) {
  return raw == nullptr ? 0 : static_cast<int>(raw->impl.keyframes.size());
}

ZozzResult zozzRawFloat2TrackPushKeyframe(ZozzRawFloat2Track* raw,
                                          ZozzTrackInterpolation interpolation,
                                          float ratio, const float value[2]) {
  if (raw == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  const int32_t interp = zozz::RawEnum(interpolation);
  const ZozzResult check = CheckPushKeyframe(interp, ratio, value, 2);
  if (check != ZOZZ_RESULT_OK) return check;
  raw->impl.keyframes.push_back(
      {ToOzz(interp), ratio, ozz::math::Float2(value[0], value[1])});
  return ZOZZ_RESULT_OK;
}

ZozzResult zozzFloat2TrackBuild(const ZozzRawFloat2Track* raw,
                                ZozzFloat2Track** out) {
  if (raw == nullptr || out == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  *out = nullptr;
  if (!raw->impl.Validate()) return ZOZZ_RESULT_INVALID_DATA;

  const ozz::animation::offline::TrackBuilder builder;
  ozz::unique_ptr<ozz::animation::Float2Track> built = builder(raw->impl);
  if (!built) return ZOZZ_RESULT_OUT_OF_MEMORY;

  ZozzFloat2Track* track = zozz::New<ZozzFloat2Track>();
  if (track == nullptr) return ZOZZ_RESULT_OUT_OF_MEMORY;
  track->impl = std::move(*built);
  *out = track;
  return ZOZZ_RESULT_OK;
}

ZozzResult zozzRawFloat2TrackOptimize(const ZozzRawFloat2Track* input,
                                      float tolerance,
                                      ZozzRawFloat2Track* output) {
  const ZozzResult check = CheckOptimize(input, output, tolerance);
  if (check != ZOZZ_RESULT_OK) return check;

  ozz::animation::offline::TrackOptimizer optimizer;
  optimizer.tolerance = tolerance;
  const bool ok = optimizer(input->impl, &output->impl);
  return ok ? ZOZZ_RESULT_OK : ZOZZ_RESULT_INVALID_DATA;
}

bool zozzRawFloat2TrackValidate(const ZozzRawFloat2Track* raw) {
  return raw != nullptr && raw->impl.Validate();
}

const char* zozzRawFloat2TrackName(const ZozzRawFloat2Track* raw) {
  return raw == nullptr ? nullptr : raw->impl.name.c_str();
}

ZozzResult zozzRawFloat2TrackSetName(ZozzRawFloat2Track* raw,
                                     const char* name) {
  return RawTrackSetName(raw, name);
}

ZozzResult zozzRawFloat2TrackKeyframes(const ZozzRawFloat2Track* raw,
                                       ZozzRawFloat2Keyframe* out,
                                       size_t count) {
  return RawTrackKeyframes(raw, out, count);
}

ZozzResult zozzRawFloat2TrackClear(ZozzRawFloat2Track* raw) {
  return RawTrackClear(raw);
}

//===----------------------------------------------------------------------===//
// RawFloat3Track
//===----------------------------------------------------------------------===//

ZozzResult zozzRawFloat3TrackCreate(ZozzRawFloat3Track** out) {
  if (out == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  *out = nullptr;
  ZozzRawFloat3Track* raw = zozz::New<ZozzRawFloat3Track>();
  if (raw == nullptr) return ZOZZ_RESULT_OUT_OF_MEMORY;
  *out = raw;
  return ZOZZ_RESULT_OK;
}

void zozzRawFloat3TrackDestroy(ZozzRawFloat3Track* raw) { zozz::Delete(raw); }

int zozzRawFloat3TrackNumKeyframes(const ZozzRawFloat3Track* raw) {
  return raw == nullptr ? 0 : static_cast<int>(raw->impl.keyframes.size());
}

ZozzResult zozzRawFloat3TrackPushKeyframe(ZozzRawFloat3Track* raw,
                                          ZozzTrackInterpolation interpolation,
                                          float ratio, const float value[3]) {
  if (raw == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  const int32_t interp = zozz::RawEnum(interpolation);
  const ZozzResult check = CheckPushKeyframe(interp, ratio, value, 3);
  if (check != ZOZZ_RESULT_OK) return check;
  raw->impl.keyframes.push_back({ToOzz(interp), ratio,
                                 ozz::math::Float3(value[0], value[1], value[2])});
  return ZOZZ_RESULT_OK;
}

ZozzResult zozzFloat3TrackBuild(const ZozzRawFloat3Track* raw,
                                ZozzFloat3Track** out) {
  if (raw == nullptr || out == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  *out = nullptr;
  if (!raw->impl.Validate()) return ZOZZ_RESULT_INVALID_DATA;

  const ozz::animation::offline::TrackBuilder builder;
  ozz::unique_ptr<ozz::animation::Float3Track> built = builder(raw->impl);
  if (!built) return ZOZZ_RESULT_OUT_OF_MEMORY;

  ZozzFloat3Track* track = zozz::New<ZozzFloat3Track>();
  if (track == nullptr) return ZOZZ_RESULT_OUT_OF_MEMORY;
  track->impl = std::move(*built);
  *out = track;
  return ZOZZ_RESULT_OK;
}

ZozzResult zozzRawFloat3TrackOptimize(const ZozzRawFloat3Track* input,
                                      float tolerance,
                                      ZozzRawFloat3Track* output) {
  const ZozzResult check = CheckOptimize(input, output, tolerance);
  if (check != ZOZZ_RESULT_OK) return check;

  ozz::animation::offline::TrackOptimizer optimizer;
  optimizer.tolerance = tolerance;
  const bool ok = optimizer(input->impl, &output->impl);
  return ok ? ZOZZ_RESULT_OK : ZOZZ_RESULT_INVALID_DATA;
}

bool zozzRawFloat3TrackValidate(const ZozzRawFloat3Track* raw) {
  return raw != nullptr && raw->impl.Validate();
}

const char* zozzRawFloat3TrackName(const ZozzRawFloat3Track* raw) {
  return raw == nullptr ? nullptr : raw->impl.name.c_str();
}

ZozzResult zozzRawFloat3TrackSetName(ZozzRawFloat3Track* raw,
                                     const char* name) {
  return RawTrackSetName(raw, name);
}

ZozzResult zozzRawFloat3TrackKeyframes(const ZozzRawFloat3Track* raw,
                                       ZozzRawFloat3Keyframe* out,
                                       size_t count) {
  return RawTrackKeyframes(raw, out, count);
}

ZozzResult zozzRawFloat3TrackClear(ZozzRawFloat3Track* raw) {
  return RawTrackClear(raw);
}

//===----------------------------------------------------------------------===//
// RawFloat4Track
//===----------------------------------------------------------------------===//

ZozzResult zozzRawFloat4TrackCreate(ZozzRawFloat4Track** out) {
  if (out == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  *out = nullptr;
  ZozzRawFloat4Track* raw = zozz::New<ZozzRawFloat4Track>();
  if (raw == nullptr) return ZOZZ_RESULT_OUT_OF_MEMORY;
  *out = raw;
  return ZOZZ_RESULT_OK;
}

void zozzRawFloat4TrackDestroy(ZozzRawFloat4Track* raw) { zozz::Delete(raw); }

int zozzRawFloat4TrackNumKeyframes(const ZozzRawFloat4Track* raw) {
  return raw == nullptr ? 0 : static_cast<int>(raw->impl.keyframes.size());
}

ZozzResult zozzRawFloat4TrackPushKeyframe(ZozzRawFloat4Track* raw,
                                          ZozzTrackInterpolation interpolation,
                                          float ratio, const float value[4]) {
  if (raw == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  const int32_t interp = zozz::RawEnum(interpolation);
  const ZozzResult check = CheckPushKeyframe(interp, ratio, value, 4);
  if (check != ZOZZ_RESULT_OK) return check;
  raw->impl.keyframes.push_back(
      {ToOzz(interp), ratio,
       ozz::math::Float4(value[0], value[1], value[2], value[3])});
  return ZOZZ_RESULT_OK;
}

ZozzResult zozzFloat4TrackBuild(const ZozzRawFloat4Track* raw,
                                ZozzFloat4Track** out) {
  if (raw == nullptr || out == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  *out = nullptr;
  if (!raw->impl.Validate()) return ZOZZ_RESULT_INVALID_DATA;

  const ozz::animation::offline::TrackBuilder builder;
  ozz::unique_ptr<ozz::animation::Float4Track> built = builder(raw->impl);
  if (!built) return ZOZZ_RESULT_OUT_OF_MEMORY;

  ZozzFloat4Track* track = zozz::New<ZozzFloat4Track>();
  if (track == nullptr) return ZOZZ_RESULT_OUT_OF_MEMORY;
  track->impl = std::move(*built);
  *out = track;
  return ZOZZ_RESULT_OK;
}

ZozzResult zozzRawFloat4TrackOptimize(const ZozzRawFloat4Track* input,
                                      float tolerance,
                                      ZozzRawFloat4Track* output) {
  const ZozzResult check = CheckOptimize(input, output, tolerance);
  if (check != ZOZZ_RESULT_OK) return check;

  ozz::animation::offline::TrackOptimizer optimizer;
  optimizer.tolerance = tolerance;
  const bool ok = optimizer(input->impl, &output->impl);
  return ok ? ZOZZ_RESULT_OK : ZOZZ_RESULT_INVALID_DATA;
}

bool zozzRawFloat4TrackValidate(const ZozzRawFloat4Track* raw) {
  return raw != nullptr && raw->impl.Validate();
}

const char* zozzRawFloat4TrackName(const ZozzRawFloat4Track* raw) {
  return raw == nullptr ? nullptr : raw->impl.name.c_str();
}

ZozzResult zozzRawFloat4TrackSetName(ZozzRawFloat4Track* raw,
                                     const char* name) {
  return RawTrackSetName(raw, name);
}

ZozzResult zozzRawFloat4TrackKeyframes(const ZozzRawFloat4Track* raw,
                                       ZozzRawFloat4Keyframe* out,
                                       size_t count) {
  return RawTrackKeyframes(raw, out, count);
}

ZozzResult zozzRawFloat4TrackClear(ZozzRawFloat4Track* raw) {
  return RawTrackClear(raw);
}

//===----------------------------------------------------------------------===//
// RawQuaternionTrack
//===----------------------------------------------------------------------===//

ZozzResult zozzRawQuaternionTrackCreate(ZozzRawQuaternionTrack** out) {
  if (out == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  *out = nullptr;
  ZozzRawQuaternionTrack* raw = zozz::New<ZozzRawQuaternionTrack>();
  if (raw == nullptr) return ZOZZ_RESULT_OUT_OF_MEMORY;
  *out = raw;
  return ZOZZ_RESULT_OK;
}

void zozzRawQuaternionTrackDestroy(ZozzRawQuaternionTrack* raw) {
  zozz::Delete(raw);
}

int zozzRawQuaternionTrackNumKeyframes(const ZozzRawQuaternionTrack* raw) {
  return raw == nullptr ? 0 : static_cast<int>(raw->impl.keyframes.size());
}

ZozzResult zozzRawQuaternionTrackPushKeyframe(
    ZozzRawQuaternionTrack* raw, ZozzTrackInterpolation interpolation,
    float ratio, const float value[4]) {
  if (raw == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  const int32_t interp = zozz::RawEnum(interpolation);
  const ZozzResult check = CheckPushKeyframe(interp, ratio, value, 4);
  if (check != ZOZZ_RESULT_OK) return check;
  raw->impl.keyframes.push_back(
      {ToOzz(interp), ratio,
       ozz::math::Quaternion(value[0], value[1], value[2], value[3])});
  return ZOZZ_RESULT_OK;
}

ZozzResult zozzQuaternionTrackBuild(const ZozzRawQuaternionTrack* raw,
                                    ZozzQuaternionTrack** out) {
  if (raw == nullptr || out == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  *out = nullptr;
  if (!raw->impl.Validate()) return ZOZZ_RESULT_INVALID_DATA;

  const ozz::animation::offline::TrackBuilder builder;
  ozz::unique_ptr<ozz::animation::QuaternionTrack> built = builder(raw->impl);
  if (!built) return ZOZZ_RESULT_OUT_OF_MEMORY;

  ZozzQuaternionTrack* track = zozz::New<ZozzQuaternionTrack>();
  if (track == nullptr) return ZOZZ_RESULT_OUT_OF_MEMORY;
  track->impl = std::move(*built);
  *out = track;
  return ZOZZ_RESULT_OK;
}

ZozzResult zozzRawQuaternionTrackOptimize(const ZozzRawQuaternionTrack* input,
                                          float tolerance,
                                          ZozzRawQuaternionTrack* output) {
  const ZozzResult check = CheckOptimize(input, output, tolerance);
  if (check != ZOZZ_RESULT_OK) return check;

  ozz::animation::offline::TrackOptimizer optimizer;
  optimizer.tolerance = tolerance;
  const bool ok = optimizer(input->impl, &output->impl);
  return ok ? ZOZZ_RESULT_OK : ZOZZ_RESULT_INVALID_DATA;
}

bool zozzRawQuaternionTrackValidate(const ZozzRawQuaternionTrack* raw) {
  return raw != nullptr && raw->impl.Validate();
}

const char* zozzRawQuaternionTrackName(const ZozzRawQuaternionTrack* raw) {
  return raw == nullptr ? nullptr : raw->impl.name.c_str();
}

ZozzResult zozzRawQuaternionTrackSetName(ZozzRawQuaternionTrack* raw,
                                         const char* name) {
  return RawTrackSetName(raw, name);
}

ZozzResult zozzRawQuaternionTrackKeyframes(const ZozzRawQuaternionTrack* raw,
                                           ZozzRawQuaternionKeyframe* out,
                                           size_t count) {
  return RawTrackKeyframes(raw, out, count);
}

ZozzResult zozzRawQuaternionTrackClear(ZozzRawQuaternionTrack* raw) {
  return RawTrackClear(raw);
}

}  // extern "C"
