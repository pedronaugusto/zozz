// The work of each bench row, written in C++ against ozz directly: the number
// the binding's own row is read against. Each loops `times` times inside C++,
// so no call crosses from Zig per unit, and each sets ozz up as the binding's
// boundary does (ffi/zozz_skeleton.cpp, ffi/zozz_sampling.cpp,
// ffi/zozz_blending.cpp, ffi/zozz_skinning.cpp, ffi/zozz_ik.cpp): objects come
// from ozz's allocator, a load reads a borrowed image through an IArchive, and
// every job is ozz's own, built over the caller's buffers and run. None of the
// boundary's own checks is repeated: that difference is what the rows time.
#include <stdint.h>
#include <string.h>

#include "ozz/animation/runtime/animation.h"
#include "ozz/animation/runtime/blending_job.h"
#include "ozz/animation/runtime/ik_two_bone_job.h"
#include "ozz/animation/runtime/local_to_model_job.h"
#include "ozz/animation/runtime/sampling_job.h"
#include "ozz/animation/runtime/skeleton.h"
#include "ozz/base/io/archive.h"
#include "ozz/base/io/stream.h"
#include "ozz/base/maths/simd_math.h"
#include "ozz/base/maths/simd_quaternion.h"
#include "ozz/base/maths/soa_transform.h"
#include "ozz/base/memory/allocator.h"
#include "ozz/base/span.h"
#include "ozz/geometry/runtime/skinning_job.h"

namespace {

namespace m = ozz::math;
using ozz::animation::Animation;
using ozz::animation::BlendingJob;
using ozz::animation::SamplingJob;
using ozz::animation::Skeleton;

/// A read-only stream over borrowed bytes: what a C++ host loading an archive
/// from memory writes, since ozz's MemoryStream would copy the image first.
class ImageStream : public ozz::io::Stream {
 public:
  ImageStream(const void* data, size_t size) : data_(static_cast<const uint8_t*>(data)), size_(size) {}
  bool opened() const override { return data_ != nullptr; }
  size_t Read(void* buffer, size_t size) override {
    const size_t n = size < size_ - tell_ ? size : size_ - tell_;
    memcpy(buffer, data_ + tell_, n);
    tell_ += n;
    return n;
  }
  size_t Write(const void*, size_t) override { return 0; }
  int Seek(int offset, Origin origin) override {
    const int64_t base = origin == kCurrent ? static_cast<int64_t>(tell_) : origin == kEnd ? static_cast<int64_t>(size_) : 0;
    const int64_t target = base + offset;
    if (target < 0 || target > static_cast<int64_t>(size_)) return -1;
    tell_ = static_cast<size_t>(target);
    return 0;
  }
  int Tell() const override { return static_cast<int>(tell_); }
  size_t Size() const override { return size_; }

 private:
  const uint8_t* data_;
  size_t size_;
  size_t tell_ = 0;
};

/// One object of type T read from an archive image, allocated through ozz, or
/// null when the image holds something else.
template <typename T>
T* Load(const void* image, size_t size) {
  ImageStream stream(image, size);
  ozz::io::IArchive archive(&stream);
  if (!archive.TestTag<T>()) return nullptr;
  T* object = ozz::New<T>();
  archive >> *object;
  return object;
}

struct World {
  Skeleton* skeleton;
  Animation* animation;
  SamplingJob::Context* context;
};

}  // namespace

extern "C" {

void* zozz_baseline_open(const uint8_t* skeleton, size_t skeleton_size, const uint8_t* animation,
                         size_t animation_size) {
  World* world = ozz::New<World>();
  world->skeleton = Load<Skeleton>(skeleton, skeleton_size);
  world->animation = Load<Animation>(animation, animation_size);
  world->context = nullptr;
  if (world->skeleton == nullptr || world->animation == nullptr) {
    ozz::Delete(world->animation);
    ozz::Delete(world->skeleton);
    ozz::Delete(world);
    return nullptr;
  }
  world->context = ozz::New<SamplingJob::Context>(world->skeleton->num_joints());
  return world;
}

void zozz_baseline_close(void* opened) {
  World* world = static_cast<World*>(opened);
  ozz::Delete(world->context);
  ozz::Delete(world->animation);
  ozz::Delete(world->skeleton);
  ozz::Delete(world);
}

uint64_t zozz_baseline_load_skeleton(const uint8_t* image, size_t size, uint64_t times) {
  uint64_t joints = 0;
  for (uint64_t i = 0; i < times; ++i) {
    Skeleton* skeleton = Load<Skeleton>(image, size);
    if (skeleton == nullptr) return UINT64_MAX;
    joints += static_cast<uint64_t>(skeleton->num_joints());
    ozz::Delete(skeleton);
  }
  return joints;
}

uint64_t zozz_baseline_load_animation(const uint8_t* image, size_t size, uint64_t times) {
  uint64_t tracks = 0;
  for (uint64_t i = 0; i < times; ++i) {
    Animation* animation = Load<Animation>(image, size);
    if (animation == nullptr) return UINT64_MAX;
    tracks += static_cast<uint64_t>(animation->num_tracks());
    ozz::Delete(animation);
  }
  return tracks;
}

/// Sample `i` of the run is taken at `ratios[i % count]`, into `out`.
bool zozz_baseline_sample(void* opened, const float* ratios, size_t count, m::SoaTransform* out, size_t blocks,
                          uint64_t times, float* checksum) {
  World* world = static_cast<World*>(opened);
  float sum = 0;
  for (uint64_t i = 0; i < times; ++i) {
    SamplingJob job;
    job.animation = world->animation;
    job.context = world->context;
    job.ratio = ratios[i % count];
    job.output = ozz::span<m::SoaTransform>(out, blocks);
    if (!job.Run()) return false;
    sum += m::GetX(out[0].translation.x);
  }
  *checksum = sum;
  return true;
}

bool zozz_baseline_local_to_model(void* opened, const m::SoaTransform* locals, size_t blocks, m::Float4x4* models,
                                  uint64_t times, float* checksum) {
  const World* world = static_cast<const World*>(opened);
  const size_t joints = static_cast<size_t>(world->skeleton->num_joints());
  float sum = 0;
  for (uint64_t i = 0; i < times; ++i) {
    ozz::animation::LocalToModelJob job;
    job.skeleton = world->skeleton;
    job.input = ozz::span<const m::SoaTransform>(locals, blocks);
    job.output = ozz::span<m::Float4x4>(models, joints);
    if (!job.Run()) return false;
    sum += m::GetX(models[joints - 1].cols[3]);
  }
  *checksum = sum;
  return true;
}

/// Layer `i` is `poses[i]` at `weights[i]`; at most four layers.
bool zozz_baseline_blend(const m::SoaTransform* const* poses, const float* weights, size_t count,
                         const m::SoaTransform* rest, m::SoaTransform* out, size_t blocks, uint64_t times,
                         float* checksum) {
  BlendingJob::Layer layers[4];
  if (count > 4) return false;
  for (size_t i = 0; i < count; ++i) {
    layers[i].weight = weights[i];
    layers[i].transform = ozz::span<const m::SoaTransform>(poses[i], blocks);
  }
  float sum = 0;
  for (uint64_t i = 0; i < times; ++i) {
    BlendingJob job;
    job.layers = ozz::span<const BlendingJob::Layer>(layers, count);
    job.rest_pose = ozz::span<const m::SoaTransform>(rest, blocks);
    job.output = ozz::span<m::SoaTransform>(out, blocks);
    if (!job.Run()) return false;
    sum += m::GetX(out[0].rotation.w);
  }
  *checksum = sum;
  return true;
}

/// Positions and normals, three floats a vertex, each vertex weighted by
/// `influences` joints: `influences - 1` weights, the last implied.
bool zozz_baseline_skin(const m::Float4x4* matrices, size_t joints, const uint16_t* indices, const float* weights,
                        const float* positions, const float* normals, float* out_positions, float* out_normals,
                        int vertices, int influences, uint64_t times, float* checksum) {
  const size_t count = static_cast<size_t>(vertices);
  const size_t per = static_cast<size_t>(influences);
  float sum = 0;
  for (uint64_t i = 0; i < times; ++i) {
    ozz::geometry::SkinningJob job;
    job.vertex_count = vertices;
    job.influences_count = influences;
    job.joint_matrices = ozz::span<const m::Float4x4>(matrices, joints);
    job.joint_indices = ozz::span<const uint16_t>(indices, count * per);
    job.joint_indices_stride = per * sizeof(uint16_t);
    job.joint_weights = ozz::span<const float>(weights, count * (per - 1));
    job.joint_weights_stride = (per - 1) * sizeof(float);
    job.in_positions = ozz::span<const float>(positions, count * 3);
    job.in_positions_stride = 3 * sizeof(float);
    job.in_normals = ozz::span<const float>(normals, count * 3);
    job.in_normals_stride = 3 * sizeof(float);
    job.out_positions = ozz::span<float>(out_positions, count * 3);
    job.out_positions_stride = 3 * sizeof(float);
    job.out_normals = ozz::span<float>(out_normals, count * 3);
    job.out_normals_stride = 3 * sizeof(float);
    if (!job.Run()) return false;
    sum += out_positions[0];
  }
  *checksum = sum;
  return true;
}

/// Solve `i` of the run reaches for `targets[i % count]`, at ozz's defaults.
bool zozz_baseline_two_bone(const m::Float4x4* start, const m::Float4x4* mid, const m::Float4x4* end,
                            const m::SimdFloat4* targets, size_t count, uint64_t times, float* checksum) {
  float sum = 0;
  for (uint64_t i = 0; i < times; ++i) {
    m::SimdQuaternion start_correction;
    m::SimdQuaternion mid_correction;
    bool reached = false;
    ozz::animation::IKTwoBoneJob job;
    job.target = targets[i % count];
    job.start_joint = start;
    job.mid_joint = mid;
    job.end_joint = end;
    job.start_joint_correction = &start_correction;
    job.mid_joint_correction = &mid_correction;
    job.reached = &reached;
    if (!job.Run()) return false;
    sum += m::GetX(start_correction.xyzw) + (reached ? 1.f : 0.f);
  }
  *checksum = sum;
  return true;
}

}  // extern "C"
