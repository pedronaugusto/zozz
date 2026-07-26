//===----------------------------------------------------------------------===//
// zozz — animation clip loading and queries.
//===----------------------------------------------------------------------===//

#include "zozz_internal.h"

namespace {

/// Rejects a clip that parsed but is not sampleable. A zero or negative
/// duration would make every ratio degenerate; a track count over the joint
/// limit means the archive is not what it claimed to be.
ZozzResult ValidateAnimation(const ozz::animation::Animation& animation) {
  if (!(animation.duration() > 0.f)) return ZOZZ_ERR_BAD_FORMAT;
  const int tracks = animation.num_tracks();
  if (tracks < 0 || tracks > zozz::kMaxJoints) return ZOZZ_ERR_BAD_FORMAT;
  return ZOZZ_OK;
}

ZozzResult FinishLoad(ZozzAnimation* animation, ZozzResult load_result,
                      ZozzAnimation** out) {
  if (load_result != ZOZZ_OK) {
    zozz::Delete(animation);
    return load_result;
  }
  const ZozzResult valid = ValidateAnimation(animation->impl);
  if (valid != ZOZZ_OK) {
    zozz::Delete(animation);
    return valid;
  }
  *out = animation;
  return ZOZZ_OK;
}

}  // namespace

extern "C" {

ZozzResult zozzAnimationLoadFile(const char* path, ZozzAnimation** out) {
  if (out == nullptr) return ZOZZ_ERR_INVALID_ARGUMENT;
  *out = nullptr;
  ZozzAnimation* animation = zozz::New<ZozzAnimation>();
  if (animation == nullptr) return ZOZZ_ERR_OUT_OF_MEMORY;
  return FinishLoad(animation, zozz::LoadFromFile(path, &animation->impl), out);
}

ZozzResult zozzAnimationLoadMemory(const void* data, size_t size,
                                   ZozzAnimation** out) {
  if (out == nullptr) return ZOZZ_ERR_INVALID_ARGUMENT;
  *out = nullptr;
  ZozzAnimation* animation = zozz::New<ZozzAnimation>();
  if (animation == nullptr) return ZOZZ_ERR_OUT_OF_MEMORY;
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

}  // extern "C"
