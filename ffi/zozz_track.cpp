//===----------------------------------------------------------------------===//
// zozz — runtime user tracks and edge triggering.
//===----------------------------------------------------------------------===//

#include "zozz_internal.h"
#include "zozz_track_types.h"
#include "zozz_track.h"

#include <cmath>
#include <cstdint>

#include "ozz/animation/runtime/track.h"
#include "ozz/animation/runtime/track_sampling_job.h"
#include "ozz/animation/runtime/track_triggering_job.h"

//===----------------------------------------------------------------------===//
// Handle definitions. Only this translation unit needs the concrete layout,
// so — unlike ZozzSkeleton and friends — these live here rather than in
// zozz_internal.h.
//===----------------------------------------------------------------------===//

// The iterator's job pointer (`job_` in ozz's Iterator) is only ever valid
// for as long as the TrackTriggeringJob it was built from is alive, so the
// two are allocated together: the handle IS the job's lifetime.
struct ZozzTrackTriggeringIterator {
  ozz::animation::TrackTriggeringJob job;
  ozz::animation::TrackTriggeringJob::Iterator it;
};

namespace {

//===----------------------------------------------------------------------===//
// Shared load / destroy / name, generic over the five track handle types.
//===----------------------------------------------------------------------===//

template <typename Handle>
ZozzResult TrackLoadFile(const char* path, Handle** out) {
  if (out == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  *out = nullptr;
  Handle* handle = zozz::New<Handle>();
  if (handle == nullptr) return ZOZZ_RESULT_OUT_OF_MEMORY;
  const ZozzResult result = zozz::LoadFromFile(path, &handle->impl);
  if (result != ZOZZ_RESULT_OK) {
    zozz::Delete(handle);
    return result;
  }
  *out = handle;
  return ZOZZ_RESULT_OK;
}

template <typename Handle>
ZozzResult TrackLoadMemory(const void* data, size_t size, Handle** out) {
  if (out == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  *out = nullptr;
  Handle* handle = zozz::New<Handle>();
  if (handle == nullptr) return ZOZZ_RESULT_OUT_OF_MEMORY;
  const ZozzResult result = zozz::LoadFromMemory(data, size, &handle->impl);
  if (result != ZOZZ_RESULT_OK) {
    zozz::Delete(handle);
    return result;
  }
  *out = handle;
  return ZOZZ_RESULT_OK;
}

template <typename Handle>
const char* TrackName(const Handle* track) {
  return track == nullptr ? "" : track->impl.name();
}

//===----------------------------------------------------------------------===//
// Sampling, generic over the *TrackSamplingJob type. `N` is the value type's
// width in floats (1, 2, 3 or 4); the static_assert is what pins that number
// to the actual C++ value type rather than trusting each call site to have
// counted right.
//===----------------------------------------------------------------------===//

template <typename Job, int N, typename Handle>
ZozzResult SampleTrack(const Handle* track, float ratio, float* out) {
  using ValueType = typename Job::ValueType;
  static_assert(sizeof(ValueType) == static_cast<size_t>(N) * sizeof(float),
                "track value type does not match the output width");

  if (out == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  std::memset(out, 0, static_cast<size_t>(N) * sizeof(float));

  if (track == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  // Run()'s own range checks (ratio <= 0, ratio >= 1) are false for NaN, so a
  // NaN ratio falls through to the interpolation branch and trips ozz's
  // "ratio >= tk0 && ratio < tk1" assert instead of being clamped.
  if (!std::isfinite(ratio)) return ZOZZ_RESULT_INVALID_ARGUMENT;

  ValueType value{};
  Job job;
  job.track = &track->impl;
  job.ratio = ratio;
  job.result = &value;

  if (!job.Validate()) return ZOZZ_RESULT_JOB_INVALID;
  if (!job.Run()) return ZOZZ_RESULT_JOB_INVALID;

  std::memcpy(out, &value, static_cast<size_t>(N) * sizeof(float));
  return ZOZZ_RESULT_OK;
}

//===----------------------------------------------------------------------===//
// Keyframe read-back, generic over the five track handle types. `ratios()`
// gives the authoritative keyframe count: `values()` always matches it by
// construction (TrackBuilder::Allocate sizes both spans together), and
// `steps()` is a packed bitset sized in bytes rather than keys.
//===----------------------------------------------------------------------===//

template <typename Handle>
int TrackNumKeyframes(const Handle* track) {
  return track == nullptr ? 0 : static_cast<int>(track->impl.ratios().size());
}

template <typename Handle>
ZozzResult TrackRatios(const Handle* track, float* out, size_t count) {
  if (track == nullptr || out == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  const ozz::span<const float> ratios = track->impl.ratios();
  if (count < ratios.size()) return ZOZZ_RESULT_BUFFER_TOO_SMALL;
  std::memcpy(out, ratios.data(), ratios.size() * sizeof(float));
  return ZOZZ_RESULT_OK;
}

/// `out` accepts any pointer type wide enough to hold one ValueType per
/// keyframe (a plain float* for FloatTrack, a float(*)[N] for the vector and
/// quaternion tracks) — every call site passes its own array parameter
/// straight through, which converts to void* implicitly.
template <typename ValueType, int N, typename Handle>
ZozzResult TrackValues(const Handle* track, void* out, size_t count) {
  static_assert(sizeof(ValueType) == static_cast<size_t>(N) * sizeof(float),
                "track value type does not match the output width");
  if (track == nullptr || out == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  const ozz::span<const ValueType> values = track->impl.values();
  if (count < values.size()) return ZOZZ_RESULT_BUFFER_TOO_SMALL;
  std::memcpy(out, values.data(), values.size() * sizeof(ValueType));
  return ZOZZ_RESULT_OK;
}

/// Decodes Track::steps() — one bit per key, bit i of byte i/8, packed
/// least-significant-bit first by TrackBuilder (track_builder.cc) — into one
/// ZozzTrackInterpolation per key, so a host never indexes the bitset itself.
template <typename Handle>
ZozzResult TrackSteps(const Handle* track, ZozzTrackInterpolation* out,
                      size_t count) {
  if (track == nullptr || out == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  const size_t num_keys = track->impl.ratios().size();
  if (count < num_keys) return ZOZZ_RESULT_BUFFER_TOO_SMALL;
  const ozz::span<const uint8_t> steps = track->impl.steps();
  for (size_t i = 0; i < num_keys; ++i) {
    const bool is_step = ((steps[i / 8] >> (i % 8)) & 1u) != 0;
    out[i] = is_step ? ZOZZ_TRACK_INTERPOLATION_STEP
                     : ZOZZ_TRACK_INTERPOLATION_LINEAR;
  }
  return ZOZZ_RESULT_OK;
}

}  // namespace

extern "C" {

//===----------------------------------------------------------------------===//
// FloatTrack
//===----------------------------------------------------------------------===//

ZozzResult zozzFloatTrackLoadFile(const char* path, ZozzFloatTrack** out) {
  return TrackLoadFile(path, out);
}

ZozzResult zozzFloatTrackLoadMemory(const void* data, size_t size,
                                    ZozzFloatTrack** out) {
  return TrackLoadMemory(data, size, out);
}

void zozzFloatTrackDestroy(ZozzFloatTrack* track) { zozz::Delete(track); }

const char* zozzFloatTrackName(const ZozzFloatTrack* track) {
  return TrackName(track);
}

ZozzResult zozzFloatTrackSample(const ZozzFloatTrack* track, float ratio,
                                float* out) {
  return SampleTrack<ozz::animation::FloatTrackSamplingJob, 1>(track, ratio,
                                                                out);
}

int zozzFloatTrackNumKeyframes(const ZozzFloatTrack* track) {
  return TrackNumKeyframes(track);
}

ZozzResult zozzFloatTrackRatios(const ZozzFloatTrack* track, float* out,
                                size_t count) {
  return TrackRatios(track, out, count);
}

ZozzResult zozzFloatTrackValues(const ZozzFloatTrack* track, float* out,
                                size_t count) {
  return TrackValues<float, 1>(track, out, count);
}

ZozzResult zozzFloatTrackSteps(const ZozzFloatTrack* track,
                               ZozzTrackInterpolation* out, size_t count) {
  return TrackSteps(track, out, count);
}

//===----------------------------------------------------------------------===//
// Float2Track
//===----------------------------------------------------------------------===//

ZozzResult zozzFloat2TrackLoadFile(const char* path, ZozzFloat2Track** out) {
  return TrackLoadFile(path, out);
}

ZozzResult zozzFloat2TrackLoadMemory(const void* data, size_t size,
                                     ZozzFloat2Track** out) {
  return TrackLoadMemory(data, size, out);
}

void zozzFloat2TrackDestroy(ZozzFloat2Track* track) { zozz::Delete(track); }

const char* zozzFloat2TrackName(const ZozzFloat2Track* track) {
  return TrackName(track);
}

ZozzResult zozzFloat2TrackSample(const ZozzFloat2Track* track, float ratio,
                                 float out[2]) {
  return SampleTrack<ozz::animation::Float2TrackSamplingJob, 2>(track, ratio,
                                                                 out);
}

int zozzFloat2TrackNumKeyframes(const ZozzFloat2Track* track) {
  return TrackNumKeyframes(track);
}

ZozzResult zozzFloat2TrackRatios(const ZozzFloat2Track* track, float* out,
                                 size_t count) {
  return TrackRatios(track, out, count);
}

ZozzResult zozzFloat2TrackValues(const ZozzFloat2Track* track,
                                 float out[][2], size_t count) {
  return TrackValues<ozz::math::Float2, 2>(track, out, count);
}

ZozzResult zozzFloat2TrackSteps(const ZozzFloat2Track* track,
                                ZozzTrackInterpolation* out, size_t count) {
  return TrackSteps(track, out, count);
}

//===----------------------------------------------------------------------===//
// Float3Track
//===----------------------------------------------------------------------===//

ZozzResult zozzFloat3TrackLoadFile(const char* path, ZozzFloat3Track** out) {
  return TrackLoadFile(path, out);
}

ZozzResult zozzFloat3TrackLoadMemory(const void* data, size_t size,
                                     ZozzFloat3Track** out) {
  return TrackLoadMemory(data, size, out);
}

void zozzFloat3TrackDestroy(ZozzFloat3Track* track) { zozz::Delete(track); }

const char* zozzFloat3TrackName(const ZozzFloat3Track* track) {
  return TrackName(track);
}

ZozzResult zozzFloat3TrackSample(const ZozzFloat3Track* track, float ratio,
                                 float out[3]) {
  return SampleTrack<ozz::animation::Float3TrackSamplingJob, 3>(track, ratio,
                                                                 out);
}

int zozzFloat3TrackNumKeyframes(const ZozzFloat3Track* track) {
  return TrackNumKeyframes(track);
}

ZozzResult zozzFloat3TrackRatios(const ZozzFloat3Track* track, float* out,
                                 size_t count) {
  return TrackRatios(track, out, count);
}

ZozzResult zozzFloat3TrackValues(const ZozzFloat3Track* track,
                                 float out[][3], size_t count) {
  return TrackValues<ozz::math::Float3, 3>(track, out, count);
}

ZozzResult zozzFloat3TrackSteps(const ZozzFloat3Track* track,
                                ZozzTrackInterpolation* out, size_t count) {
  return TrackSteps(track, out, count);
}

//===----------------------------------------------------------------------===//
// Float4Track
//===----------------------------------------------------------------------===//

ZozzResult zozzFloat4TrackLoadFile(const char* path, ZozzFloat4Track** out) {
  return TrackLoadFile(path, out);
}

ZozzResult zozzFloat4TrackLoadMemory(const void* data, size_t size,
                                     ZozzFloat4Track** out) {
  return TrackLoadMemory(data, size, out);
}

void zozzFloat4TrackDestroy(ZozzFloat4Track* track) { zozz::Delete(track); }

const char* zozzFloat4TrackName(const ZozzFloat4Track* track) {
  return TrackName(track);
}

ZozzResult zozzFloat4TrackSample(const ZozzFloat4Track* track, float ratio,
                                 float out[4]) {
  return SampleTrack<ozz::animation::Float4TrackSamplingJob, 4>(track, ratio,
                                                                 out);
}

int zozzFloat4TrackNumKeyframes(const ZozzFloat4Track* track) {
  return TrackNumKeyframes(track);
}

ZozzResult zozzFloat4TrackRatios(const ZozzFloat4Track* track, float* out,
                                 size_t count) {
  return TrackRatios(track, out, count);
}

ZozzResult zozzFloat4TrackValues(const ZozzFloat4Track* track,
                                 float out[][4], size_t count) {
  return TrackValues<ozz::math::Float4, 4>(track, out, count);
}

ZozzResult zozzFloat4TrackSteps(const ZozzFloat4Track* track,
                                ZozzTrackInterpolation* out, size_t count) {
  return TrackSteps(track, out, count);
}

//===----------------------------------------------------------------------===//
// QuaternionTrack
//===----------------------------------------------------------------------===//

ZozzResult zozzQuaternionTrackLoadFile(const char* path,
                                       ZozzQuaternionTrack** out) {
  return TrackLoadFile(path, out);
}

ZozzResult zozzQuaternionTrackLoadMemory(const void* data, size_t size,
                                         ZozzQuaternionTrack** out) {
  return TrackLoadMemory(data, size, out);
}

void zozzQuaternionTrackDestroy(ZozzQuaternionTrack* track) {
  zozz::Delete(track);
}

const char* zozzQuaternionTrackName(const ZozzQuaternionTrack* track) {
  return TrackName(track);
}

ZozzResult zozzQuaternionTrackSample(const ZozzQuaternionTrack* track,
                                     float ratio, float out[4]) {
  return SampleTrack<ozz::animation::QuaternionTrackSamplingJob, 4>(
      track, ratio, out);
}

int zozzQuaternionTrackNumKeyframes(const ZozzQuaternionTrack* track) {
  return TrackNumKeyframes(track);
}

ZozzResult zozzQuaternionTrackRatios(const ZozzQuaternionTrack* track,
                                     float* out, size_t count) {
  return TrackRatios(track, out, count);
}

ZozzResult zozzQuaternionTrackValues(const ZozzQuaternionTrack* track,
                                     float out[][4], size_t count) {
  return TrackValues<ozz::math::Quaternion, 4>(track, out, count);
}

ZozzResult zozzQuaternionTrackSteps(const ZozzQuaternionTrack* track,
                                    ZozzTrackInterpolation* out,
                                    size_t count) {
  return TrackSteps(track, out, count);
}

//===----------------------------------------------------------------------===//
// Track edge triggering
//===----------------------------------------------------------------------===//

ZozzResult zozzFloatTrackTriggeringJobRun(
    const ZozzFloatTrack* track, float from, float to, float threshold,
    ZozzTrackTriggeringIterator** out) {
  if (out == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  *out = nullptr;
  if (track == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  if (!std::isfinite(from) || !std::isfinite(to) || !std::isfinite(threshold)) {
    return ZOZZ_RESULT_INVALID_ARGUMENT;
  }

  ZozzTrackTriggeringIterator* handle =
      zozz::New<ZozzTrackTriggeringIterator>();
  if (handle == nullptr) return ZOZZ_RESULT_OUT_OF_MEMORY;

  handle->job.track = &track->impl;
  handle->job.from = from;
  handle->job.to = to;
  handle->job.threshold = threshold;
  handle->job.iterator = &handle->it;

  if (!handle->job.Validate()) {
    zozz::Delete(handle);
    return ZOZZ_RESULT_INVALID_ARGUMENT;
  }
  if (!handle->job.Run()) {
    zozz::Delete(handle);
    return ZOZZ_RESULT_INVALID_ARGUMENT;
  }

  *out = handle;
  return ZOZZ_RESULT_OK;
}

void zozzTrackTriggeringIteratorDestroy(
    ZozzTrackTriggeringIterator* iterator) {
  zozz::Delete(iterator);
}

bool zozzTrackTriggeringIteratorValid(
    const ZozzTrackTriggeringIterator* iterator) {
  if (iterator == nullptr) return false;
  return iterator->it != iterator->job.end();
}

ZozzResult zozzTrackTriggeringIteratorNext(
    ZozzTrackTriggeringIterator* iterator) {
  if (iterator == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  // ozz's operator++ asserts (UB in release) when called on an end iterator;
  // this is the check that turns that precondition into a real error path.
  if (iterator->it == iterator->job.end()) return ZOZZ_RESULT_INVALID_ARGUMENT;
  ++iterator->it;
  return ZOZZ_RESULT_OK;
}

ZozzResult zozzTrackTriggeringIteratorGet(
    const ZozzTrackTriggeringIterator* iterator, ZozzTrackEdge* out) {
  if (out == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  out->ratio = 0.f;
  out->rising = false;
  if (iterator == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  // Dereferencing an end iterator is an ozz assert (UB in release); same
  // precondition as Next, guarded the same way.
  if (iterator->it == iterator->job.end()) return ZOZZ_RESULT_INVALID_ARGUMENT;

  const ozz::animation::TrackTriggeringJob::Edge& edge = *iterator->it;
  out->ratio = edge.ratio;
  out->rising = edge.rising;
  return ZOZZ_RESULT_OK;
}

}  // extern "C"
