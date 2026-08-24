//===----------------------------------------------------------------------===//
// zozz — runtime user tracks and edge triggering.
//===----------------------------------------------------------------------===//

#include "zozz_internal.h"
#include "zozz_track.h"

#include <cmath>

#include "ozz/animation/runtime/track.h"
#include "ozz/animation/runtime/track_sampling_job.h"
#include "ozz/animation/runtime/track_triggering_job.h"

//===----------------------------------------------------------------------===//
// Handle definitions. Only this translation unit needs the concrete layout,
// so — unlike ZozzSkeleton and friends — these live here rather than in
// zozz_internal.h.
//===----------------------------------------------------------------------===//

struct ZozzFloatTrack {
  ozz::animation::FloatTrack impl;
};
struct ZozzFloat2Track {
  ozz::animation::Float2Track impl;
};
struct ZozzFloat3Track {
  ozz::animation::Float3Track impl;
};
struct ZozzFloat4Track {
  ozz::animation::Float4Track impl;
};
struct ZozzQuaternionTrack {
  ozz::animation::QuaternionTrack impl;
};

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

  if (!job.Validate()) return ZOZZ_RESULT_INVALID_ARGUMENT;
  if (!job.Run()) return ZOZZ_RESULT_INVALID_ARGUMENT;

  std::memcpy(out, &value, static_cast<size_t>(N) * sizeof(float));
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
