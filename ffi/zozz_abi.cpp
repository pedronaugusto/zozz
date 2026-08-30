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

/// One past the last ZozzResult enumerator. Update alongside the enum; the
/// switch in zozzResultName is compiled with -Wswitch, so adding a result
/// without handling it is already a warning there.
constexpr uint32_t kResultCount =
    static_cast<uint32_t>(ZOZZ_RESULT_UNSUPPORTED) + 1u;

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
