//===----------------------------------------------------------------------===//
// zozz — compile-time layout assertions and the runtime layout report.
//
// Two independent guards live here:
//
//   1. static_asserts that fail the BUILD if a vendored ozz upgrade changes a
//      type zozz casts to or from.
//   2. zozzAbiLayout(), which lets the Zig wrapper assert in a TEST that its
//      hand-written externs still match this translation unit.
//
// Together they cover both directions of drift: C++ vs ozz, and Zig vs C.
//===----------------------------------------------------------------------===//

#include <cstddef>

#include "ozz/animation/runtime/blending_job.h"
#include "ozz/base/log.h"
#include "ozz/base/maths/simd_math.h"
#include "zozz_internal.h"

namespace {

//===----------------------------------------------------------------------===//
// ZozzFloat4x4 <-> ozz::math::Float4x4
//
// zozzLocalToModel reinterpret_casts between these. If either property below
// stops holding, that cast becomes undefined behaviour, so it must not compile.
//===----------------------------------------------------------------------===//

static_assert(sizeof(ZozzFloat4x4) == sizeof(ozz::math::Float4x4),
              "ZozzFloat4x4 must match ozz::math::Float4x4 in size");
static_assert(alignof(ZozzFloat4x4) == alignof(ozz::math::Float4x4),
              "ZozzFloat4x4 must match ozz::math::Float4x4 in alignment");
static_assert(sizeof(ozz::math::Float4x4) == 64,
              "ozz::math::Float4x4 is expected to be four 16-byte columns");

//===----------------------------------------------------------------------===//
// ZozzTransform
//
// Not cast to any ozz type — it is produced by an explicit transpose — but the
// Zig side mirrors it field for field, so the layout is still part of the ABI.
//===----------------------------------------------------------------------===//

static_assert(sizeof(ZozzTransform) == 40,
              "ZozzTransform is expected to be 10 tightly packed floats");
static_assert(offsetof(ZozzTransform, translation) == 0, "field moved");
static_assert(offsetof(ZozzTransform, rotation) == 12, "field moved");
static_assert(offsetof(ZozzTransform, scale) == 28, "field moved");

//===----------------------------------------------------------------------===//
// SoA assumptions
//
// The transposes in zozz_pose.cpp read these structs member by member and
// assume four joints per block.
//===----------------------------------------------------------------------===//

static_assert(sizeof(ozz::math::SimdFloat4) == 16, "SIMD width changed");
static_assert(sizeof(ozz::math::SoaTransform) == 160,
              "SoaTransform is expected to be 10 SimdFloat4 (4 joints)");
static_assert(alignof(ozz::math::SoaTransform) == 16,
              "SoaTransform must stay 16-byte aligned");

//===----------------------------------------------------------------------===//
// The SoA POD types are ozz's own
//
// zozz_internal.h's AsOzz reinterprets a caller's ZozzSoaTransform array as
// ozz::math::SoaTransform, and zozz_blending.cpp reinterprets a caller's
// ZozzBlendingLayer array as BlendingJob::Layer. Neither copies, so every
// size, alignment and offset below is what makes that sound rather than
// hopeful. A field reordered on either side fails to compile here.
//===----------------------------------------------------------------------===//

static_assert(sizeof(ZozzSimdFloat4) == sizeof(ozz::math::SimdFloat4),
              "ZozzSimdFloat4 must match ozz::math::SimdFloat4 in size");
static_assert(alignof(ZozzSimdFloat4) == alignof(ozz::math::SimdFloat4),
              "ZozzSimdFloat4 must match ozz::math::SimdFloat4 in alignment");

static_assert(sizeof(ZozzSoaFloat3) == sizeof(ozz::math::SoaFloat3),
              "ZozzSoaFloat3 must match ozz::math::SoaFloat3 in size");
static_assert(offsetof(ZozzSoaFloat3, x) == offsetof(ozz::math::SoaFloat3, x),
              "field moved");
static_assert(offsetof(ZozzSoaFloat3, y) == offsetof(ozz::math::SoaFloat3, y),
              "field moved");
static_assert(offsetof(ZozzSoaFloat3, z) == offsetof(ozz::math::SoaFloat3, z),
              "field moved");

static_assert(sizeof(ZozzSoaQuaternion) == sizeof(ozz::math::SoaQuaternion),
              "ZozzSoaQuaternion must match ozz::math::SoaQuaternion in size");
static_assert(offsetof(ZozzSoaQuaternion, w) ==
                  offsetof(ozz::math::SoaQuaternion, w),
              "the quaternion component order changed");

static_assert(sizeof(ZozzSoaTransform) == sizeof(ozz::math::SoaTransform),
              "ZozzSoaTransform must match ozz::math::SoaTransform in size");
static_assert(alignof(ZozzSoaTransform) == alignof(ozz::math::SoaTransform),
              "ZozzSoaTransform must match ozz::math::SoaTransform alignment");
static_assert(offsetof(ZozzSoaTransform, translation) ==
                  offsetof(ozz::math::SoaTransform, translation),
              "field moved");
static_assert(offsetof(ZozzSoaTransform, rotation) ==
                  offsetof(ozz::math::SoaTransform, rotation),
              "field moved");
static_assert(offsetof(ZozzSoaTransform, scale) ==
                  offsetof(ozz::math::SoaTransform, scale),
              "field moved");

using ZozzOzzLayer = ozz::animation::BlendingJob::Layer;
static_assert(sizeof(ZozzBlendingLayer) == sizeof(ZozzOzzLayer),
              "ZozzBlendingLayer must match BlendingJob::Layer in size");
static_assert(alignof(ZozzBlendingLayer) == alignof(ZozzOzzLayer),
              "ZozzBlendingLayer must match BlendingJob::Layer in alignment");
static_assert(offsetof(ZozzBlendingLayer, weight) ==
                  offsetof(ZozzOzzLayer, weight),
              "field moved");
static_assert(offsetof(ZozzBlendingLayer, transform) ==
                  offsetof(ZozzOzzLayer, transform),
              "field moved");
static_assert(offsetof(ZozzBlendingLayer, joint_weights) ==
                  offsetof(ZozzOzzLayer, joint_weights),
              "field moved");
static_assert(sizeof(ozz::span<const ozz::math::SoaTransform>) ==
                  sizeof(const ZozzSoaTransform*) + sizeof(size_t),
              "ozz::span is expected to be a pointer and a count");
static_assert(offsetof(ZozzBlendingLayer, num_transform) ==
                  offsetof(ZozzBlendingLayer, transform) +
                      sizeof(const ZozzSoaTransform*),
              "the count must follow its pointer, as ozz::span lays them out");
static_assert(offsetof(ZozzBlendingLayer, num_joint_weights) ==
                  offsetof(ZozzBlendingLayer, joint_weights) +
                      sizeof(const ZozzSimdFloat4*),
              "the count must follow its pointer, as ozz::span lays them out");

//===----------------------------------------------------------------------===//
// Skeleton limits
//
// ZOZZ_MAX_JOINTS is the sentinel a caller passes as LocalToModelJob's `to`
// for "the last joint", so it must be ozz's own kMaxJoints and not a literal
// that drifts from it.
//===----------------------------------------------------------------------===//

static_assert(ZOZZ_NO_PARENT == ozz::animation::Skeleton::kNoParent,
              "ZOZZ_NO_PARENT must match ozz::animation::Skeleton::kNoParent");
static_assert(ZOZZ_MAX_JOINTS == ozz::animation::Skeleton::kMaxJoints,
              "ZOZZ_MAX_JOINTS must match ozz::animation::Skeleton::kMaxJoints");

//===----------------------------------------------------------------------===//
// Allocator seam
//===----------------------------------------------------------------------===//

static_assert(sizeof(ZozzAllocator) == 3 * sizeof(void*),
              "ZozzAllocator is expected to be three pointers");

//===----------------------------------------------------------------------===//
// Log levels
//
// zozzSetLogLevel/zozzGetLogLevel static_cast directly between ZozzLogLevel
// and ozz::log::Level. These are what keep that cast valid across a vendored
// ozz upgrade.
//===----------------------------------------------------------------------===//

static_assert(static_cast<int>(ZOZZ_LOG_LEVEL_SILENT) ==
                  static_cast<int>(ozz::log::kSilent),
              "ZozzLogLevel must match ozz::log::Level");
static_assert(static_cast<int>(ZOZZ_LOG_LEVEL_STANDARD) ==
                  static_cast<int>(ozz::log::kStandard),
              "ZozzLogLevel must match ozz::log::Level");
static_assert(static_cast<int>(ZOZZ_LOG_LEVEL_VERBOSE) ==
                  static_cast<int>(ozz::log::kVerbose),
              "ZozzLogLevel must match ozz::log::Level");

//===----------------------------------------------------------------------===//
// Seek origins
//
// zozz_archive.cpp's read bridge casts a ZozzSeekOrigin straight to
// ozz::io::Stream::Origin, and back the other way when handing an origin ozz
// picked to a host's seek callback. These are what keep that cast valid
// across a vendored ozz upgrade.
//===----------------------------------------------------------------------===//

static_assert(static_cast<int>(ZOZZ_SEEK_ORIGIN_CURRENT) ==
                  static_cast<int>(ozz::io::Stream::kCurrent),
              "ZozzSeekOrigin must match ozz::io::Stream::Origin");
static_assert(static_cast<int>(ZOZZ_SEEK_ORIGIN_END) ==
                  static_cast<int>(ozz::io::Stream::kEnd),
              "ZozzSeekOrigin must match ozz::io::Stream::Origin");
static_assert(static_cast<int>(ZOZZ_SEEK_ORIGIN_SET) ==
                  static_cast<int>(ozz::io::Stream::kSet),
              "ZozzSeekOrigin must match ozz::io::Stream::Origin");

//===----------------------------------------------------------------------===//
// Endianness
//
// zozz_archive.cpp casts a ZozzEndianness straight to ozz::Endianness when
// constructing an OArchive, and back the other way to report the platform's
// own native order. These are what keep that cast valid across a vendored
// ozz upgrade.
//===----------------------------------------------------------------------===//

static_assert(static_cast<int>(ZOZZ_ENDIANNESS_BIG) ==
                  static_cast<int>(ozz::kBigEndian),
              "ZozzEndianness must match ozz::Endianness");
static_assert(static_cast<int>(ZOZZ_ENDIANNESS_LITTLE) ==
                  static_cast<int>(ozz::kLittleEndian),
              "ZozzEndianness must match ozz::Endianness");

//===----------------------------------------------------------------------===//
// Node property types
//
// zozz_gltf.cpp casts a ZozzNodePropertyType straight to
// ozz::animation::offline::OzzImporter::NodeProperty::Type, and back the
// other way when reporting a property GetNodeProperties returned. These are
// what keep that cast valid across a vendored ozz upgrade.
//===----------------------------------------------------------------------===//

using NodePropertyType =
    ozz::animation::offline::OzzImporter::NodeProperty;

static_assert(static_cast<int>(ZOZZ_NODE_PROPERTY_TYPE_FLOAT1) ==
                  static_cast<int>(NodePropertyType::kFloat1),
              "ZozzNodePropertyType must match OzzImporter::NodeProperty::Type");
static_assert(static_cast<int>(ZOZZ_NODE_PROPERTY_TYPE_FLOAT2) ==
                  static_cast<int>(NodePropertyType::kFloat2),
              "ZozzNodePropertyType must match OzzImporter::NodeProperty::Type");
static_assert(static_cast<int>(ZOZZ_NODE_PROPERTY_TYPE_FLOAT3) ==
                  static_cast<int>(NodePropertyType::kFloat3),
              "ZozzNodePropertyType must match OzzImporter::NodeProperty::Type");
static_assert(static_cast<int>(ZOZZ_NODE_PROPERTY_TYPE_FLOAT4) ==
                  static_cast<int>(NodePropertyType::kFloat4),
              "ZozzNodePropertyType must match OzzImporter::NodeProperty::Type");
static_assert(static_cast<int>(ZOZZ_NODE_PROPERTY_TYPE_POINT) ==
                  static_cast<int>(NodePropertyType::kPoint),
              "ZozzNodePropertyType must match OzzImporter::NodeProperty::Type");
static_assert(static_cast<int>(ZOZZ_NODE_PROPERTY_TYPE_VECTOR) ==
                  static_cast<int>(NodePropertyType::kVector),
              "ZozzNodePropertyType must match OzzImporter::NodeProperty::Type");

/// One past the last ZozzResult enumerator, named rather than counted so it
/// cannot drift on its own. Two guards meet here: `zozz.zig` compares this
/// against the Zig enum's field count, and the switch in zozzResultName is
/// compiled with -Wswitch, so a result added to the header and nowhere else
/// fails both.
constexpr uint32_t kResultCount =
    static_cast<uint32_t>(ZOZZ_RESULT_ALLOCATOR_IN_USE) + 1u;

}  // namespace

extern "C" {

void zozzAbiLayout(ZozzAbiLayout* out) {
  if (out == nullptr) return;
  out->layout_size = static_cast<uint32_t>(sizeof(ZozzAbiLayout));

  out->transform_size = static_cast<uint32_t>(sizeof(ZozzTransform));
  out->transform_align = static_cast<uint32_t>(alignof(ZozzTransform));
  out->transform_offset_translation =
      static_cast<uint32_t>(offsetof(ZozzTransform, translation));
  out->transform_offset_rotation =
      static_cast<uint32_t>(offsetof(ZozzTransform, rotation));
  out->transform_offset_scale =
      static_cast<uint32_t>(offsetof(ZozzTransform, scale));

  out->float4x4_size = static_cast<uint32_t>(sizeof(ZozzFloat4x4));
  out->float4x4_align = static_cast<uint32_t>(alignof(ZozzFloat4x4));

  out->simd_float4_size = static_cast<uint32_t>(sizeof(ZozzSimdFloat4));
  out->simd_float4_align = static_cast<uint32_t>(alignof(ZozzSimdFloat4));

  out->soa_transform_size = static_cast<uint32_t>(sizeof(ZozzSoaTransform));
  out->soa_transform_align = static_cast<uint32_t>(alignof(ZozzSoaTransform));
  out->soa_transform_offset_translation =
      static_cast<uint32_t>(offsetof(ZozzSoaTransform, translation));
  out->soa_transform_offset_rotation =
      static_cast<uint32_t>(offsetof(ZozzSoaTransform, rotation));
  out->soa_transform_offset_scale =
      static_cast<uint32_t>(offsetof(ZozzSoaTransform, scale));

  out->blending_layer_size = static_cast<uint32_t>(sizeof(ZozzBlendingLayer));
  out->blending_layer_align =
      static_cast<uint32_t>(alignof(ZozzBlendingLayer));
  out->blending_layer_offset_weight =
      static_cast<uint32_t>(offsetof(ZozzBlendingLayer, weight));
  out->blending_layer_offset_transform =
      static_cast<uint32_t>(offsetof(ZozzBlendingLayer, transform));
  out->blending_layer_offset_num_transform =
      static_cast<uint32_t>(offsetof(ZozzBlendingLayer, num_transform));
  out->blending_layer_offset_joint_weights =
      static_cast<uint32_t>(offsetof(ZozzBlendingLayer, joint_weights));
  out->blending_layer_offset_num_joint_weights =
      static_cast<uint32_t>(offsetof(ZozzBlendingLayer, num_joint_weights));

  out->allocator_size = static_cast<uint32_t>(sizeof(ZozzAllocator));
  out->allocator_align = static_cast<uint32_t>(alignof(ZozzAllocator));
  out->allocator_offset_allocate =
      static_cast<uint32_t>(offsetof(ZozzAllocator, allocate));
  out->allocator_offset_deallocate =
      static_cast<uint32_t>(offsetof(ZozzAllocator, deallocate));
  out->allocator_offset_user =
      static_cast<uint32_t>(offsetof(ZozzAllocator, user));

  out->result_count = kResultCount;
}

}  // extern "C"
