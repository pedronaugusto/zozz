//===----------------------------------------------------------------------===//
// zozz — animation clip loading and queries.
//===----------------------------------------------------------------------===//

#include "zozz_internal.h"

namespace zozz {

/// Rejects a clip that parsed but is not sampleable. A zero or negative
/// duration would make every ratio degenerate; a track count over the joint
/// limit means the archive is not what it claimed to be.
ZozzResult ValidateAnimation(const ozz::animation::Animation& animation) {
  if (!(animation.duration() > 0.f)) return ZOZZ_RESULT_BAD_FORMAT;
  const int tracks = animation.num_tracks();
  if (tracks < 0 || tracks > zozz::kMaxJoints) return ZOZZ_RESULT_BAD_FORMAT;
  return ZOZZ_RESULT_OK;
}

}  // namespace zozz

namespace {

ZozzResult FinishLoad(ZozzAnimation* animation, ZozzResult load_result,
                      ZozzAnimation** out) {
  if (load_result != ZOZZ_RESULT_OK) {
    zozz::Delete(animation);
    return load_result;
  }
  const ZozzResult valid = zozz::ValidateAnimation(animation->impl);
  if (valid != ZOZZ_RESULT_OK) {
    zozz::Delete(animation);
    return valid;
  }
  *out = animation;
  return ZOZZ_RESULT_OK;
}

/// The control streams for one channel, or nullptr for a channel value the
/// host made up. Taken as a raw integer: reading an out-of-range enum is
/// undefined behaviour, so it is converted once with zozz::RawEnum at the
/// entry point and travels inward as an int.
const ozz::animation::Animation::KeyframesCtrlConst* CtrlFor(
    const ozz::animation::Animation& animation, int32_t channel,
    ozz::animation::Animation::KeyframesCtrlConst* storage) {
  switch (channel) {
    case ZOZZ_KEYFRAME_CHANNEL_TRANSLATION:
      *storage = animation.translations_ctrl();
      return storage;
    case ZOZZ_KEYFRAME_CHANNEL_ROTATION:
      *storage = animation.rotations_ctrl();
      return storage;
    case ZOZZ_KEYFRAME_CHANNEL_SCALE:
      *storage = animation.scales_ctrl();
      return storage;
    default:
      return nullptr;
  }
}

template <typename T>
ZozzResult CopySpan(ozz::span<const T> source, T* out, size_t count) {
  if (out == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  if (count < source.size()) return ZOZZ_RESULT_BUFFER_TOO_SMALL;
  if (!source.empty()) std::memcpy(out, source.data(), source.size() * sizeof(T));
  return ZOZZ_RESULT_OK;
}

}  // namespace

extern "C" {

ZozzResult zozzAnimationLoadFile(const char* path, ZozzAnimation** out) {
  if (out == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  *out = nullptr;
  ZozzAnimation* animation = zozz::New<ZozzAnimation>();
  if (animation == nullptr) return ZOZZ_RESULT_OUT_OF_MEMORY;
  return FinishLoad(animation, zozz::LoadFromFile(path, &animation->impl), out);
}

ZozzResult zozzAnimationLoadMemory(const void* data, size_t size,
                                   ZozzAnimation** out) {
  if (out == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  *out = nullptr;
  ZozzAnimation* animation = zozz::New<ZozzAnimation>();
  if (animation == nullptr) return ZOZZ_RESULT_OUT_OF_MEMORY;
  return FinishLoad(
      animation, zozz::LoadFromMemory(data, size, &animation->impl), out);
}

void zozzAnimationDestroy(ZozzAnimation* animation) { zozz::Delete(animation); }

float zozzAnimationDuration(const ZozzAnimation* animation) {
  return animation == nullptr ? 0.f : animation->impl.duration();
}

int zozzAnimationNumTracks(const ZozzAnimation* animation) {
  return animation == nullptr ? 0 : animation->impl.num_tracks();
}

const char* zozzAnimationName(const ZozzAnimation* animation) {
  return animation == nullptr ? "" : animation->impl.name();
}

int zozzAnimationNumSoaTracks(const ZozzAnimation* animation) {
  return animation == nullptr ? 0 : animation->impl.num_soa_tracks();
}

size_t zozzAnimationSize(const ZozzAnimation* animation) {
  return animation == nullptr ? 0 : animation->impl.size();
}

int zozzAnimationNumTimepoints(const ZozzAnimation* animation) {
  return animation == nullptr
             ? 0
             : static_cast<int>(animation->impl.timepoints().size());
}

ZozzResult zozzAnimationTimepoints(const ZozzAnimation* animation, float* out,
                                   size_t count) {
  if (animation == nullptr || out == nullptr) {
    return ZOZZ_RESULT_INVALID_ARGUMENT;
  }
  const ozz::span<const float> timepoints = animation->impl.timepoints();
  if (count < timepoints.size()) return ZOZZ_RESULT_BUFFER_TOO_SMALL;
  std::memcpy(out, timepoints.data(), timepoints.size() * sizeof(float));
  return ZOZZ_RESULT_OK;
}

ZozzResult zozzAnimationKeyframesCtrl(const ZozzAnimation* animation,
                                      ZozzKeyframeChannel channel,
                                      ZozzKeyframesCtrl* out) {
  if (animation == nullptr || out == nullptr) {
    return ZOZZ_RESULT_INVALID_ARGUMENT;
  }
  ozz::animation::Animation::KeyframesCtrlConst storage;
  const ozz::animation::Animation::KeyframesCtrlConst* ctrl =
      CtrlFor(animation->impl, zozz::RawEnum(channel), &storage);
  if (ctrl == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  out->num_ratio_bytes = ctrl->ratios.size();
  out->num_previouses = ctrl->previouses.size();
  out->num_iframe_entry_bytes = ctrl->iframe_entries.size();
  out->num_iframe_desc = ctrl->iframe_desc.size();
  out->iframe_interval = ctrl->iframe_interval;
  return ZOZZ_RESULT_OK;
}

ZozzResult zozzAnimationKeyframeRatios(const ZozzAnimation* animation,
                                       ZozzKeyframeChannel channel,
                                       uint8_t* out, size_t count) {
  if (animation == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  ozz::animation::Animation::KeyframesCtrlConst storage;
  const ozz::animation::Animation::KeyframesCtrlConst* ctrl =
      CtrlFor(animation->impl, zozz::RawEnum(channel), &storage);
  if (ctrl == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  return CopySpan(ozz::span<const uint8_t>(
                      reinterpret_cast<const uint8_t*>(ctrl->ratios.data()),
                      ctrl->ratios.size()),
                  out, count);
}

ZozzResult zozzAnimationKeyframePreviouses(const ZozzAnimation* animation,
                                           ZozzKeyframeChannel channel,
                                           uint16_t* out, size_t count) {
  if (animation == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  ozz::animation::Animation::KeyframesCtrlConst storage;
  const ozz::animation::Animation::KeyframesCtrlConst* ctrl =
      CtrlFor(animation->impl, zozz::RawEnum(channel), &storage);
  if (ctrl == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  return CopySpan(ctrl->previouses, out, count);
}

ZozzResult zozzAnimationKeyframeIframeEntries(const ZozzAnimation* animation,
                                              ZozzKeyframeChannel channel,
                                              uint8_t* out, size_t count) {
  if (animation == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  ozz::animation::Animation::KeyframesCtrlConst storage;
  const ozz::animation::Animation::KeyframesCtrlConst* ctrl =
      CtrlFor(animation->impl, zozz::RawEnum(channel), &storage);
  if (ctrl == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  return CopySpan(
      ozz::span<const uint8_t>(
          reinterpret_cast<const uint8_t*>(ctrl->iframe_entries.data()),
          ctrl->iframe_entries.size()),
      out, count);
}

ZozzResult zozzAnimationKeyframeIframeDesc(const ZozzAnimation* animation,
                                           ZozzKeyframeChannel channel,
                                           uint32_t* out, size_t count) {
  if (animation == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  ozz::animation::Animation::KeyframesCtrlConst storage;
  const ozz::animation::Animation::KeyframesCtrlConst* ctrl =
      CtrlFor(animation->impl, zozz::RawEnum(channel), &storage);
  if (ctrl == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  return CopySpan(ctrl->iframe_desc, out, count);
}

}  // extern "C"
