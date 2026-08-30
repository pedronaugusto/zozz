//===----------------------------------------------------------------------===//
// zozz — ozz::animation::offline::OzzImporter, ozz's converter interface, in
// both directions: a concrete glTF-backed importer (-Dgltf, off by default —
// tinygltf's JSON parser is weight a runtime-only consumer should not carry),
// and a host-implementable ZozzImporterInterface (-Doptions) for a host with
// its own source format. Every entry point is declared unconditionally and
// returns ZOZZ_RESULT_UNSUPPORTED when its option is off. zozzImporterRun (the
// CLI driver) always returns ZOZZ_RESULT_UNSUPPORTED, on every build, because
// its jsoncpp dependency is not vendored; it stays declared so this is
// discoverable rather than silently missing. A ZozzImporter handle is opaque
// regardless of which side created it: every entry point drives it through
// OzzImporter's own virtual interface, so a host-implemented importer gets the
// same accessors a glTF import does.
//===----------------------------------------------------------------------===//

#ifndef ZOZZ_GLTF_H_
#define ZOZZ_GLTF_H_

#include <stddef.h>
#include <stdint.h>

#ifndef __cplusplus
#include <stdbool.h>
#endif

#include "zozz.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ZozzImporter ZozzImporter;

//===----------------------------------------------------------------------===//
// Skeleton import
//===----------------------------------------------------------------------===//

/// Mirrors OzzImporter::NodeType exactly: which source node kinds should be
/// considered skeleton joints. Plain bools, not C++ bitfields — a bitfield's
/// layout is not something a C ABI can rely on.
typedef struct ZozzImportNodeType {
  bool skeleton;
  bool marker;
  bool camera;
  bool geometry;
  bool light;
  bool null;
  bool any;
} ZozzImportNodeType;

//===----------------------------------------------------------------------===//
// Track / property types
//===----------------------------------------------------------------------===//

/// Mirrors OzzImporter::NodeProperty::Type exactly (checked in
/// ffi/zozz_abi.cpp).
typedef enum ZozzNodePropertyType {
  ZOZZ_NODE_PROPERTY_TYPE_FLOAT1 = 0,
  ZOZZ_NODE_PROPERTY_TYPE_FLOAT2 = 1,
  ZOZZ_NODE_PROPERTY_TYPE_FLOAT3 = 2,
  ZOZZ_NODE_PROPERTY_TYPE_FLOAT4 = 3,
  ZOZZ_NODE_PROPERTY_TYPE_POINT = 4,
  ZOZZ_NODE_PROPERTY_TYPE_VECTOR = 5,
} ZozzNodePropertyType;

/// One property GetNodeProperties reports. `name` is borrowed and valid only
/// for the duration of the ZozzNodePropertyVisitor call it is passed to.
typedef struct ZozzNodeProperty {
  const char* name;
  ZozzNodePropertyType type;
} ZozzNodeProperty;

/// Visits one string. `value` is borrowed and valid only for the call.
typedef void (*ZozzStringVisitor)(const char* value, void* user);

/// Visits one node property. `property` is borrowed and valid only for the
/// call (including the ZozzNodeProperty::name it points to).
typedef void (*ZozzNodePropertyVisitor)(const ZozzNodeProperty* property,
                                        void* user);

//===----------------------------------------------------------------------===//
// The host-implementable side
//
// One function pointer per OzzImporter pure virtual. `load`, `import_skeleton`
// and `import_animation` are required: zozzImporterCreate rejects a NULL one
// with ZOZZ_RESULT_INVALID_ARGUMENT at the call, the same way zozzOArchiveCreate
// rejects a ZozzStream missing a callback its direction needs, rather than
// crashing on the first call that would have needed it. The rest are
// optional; leave NULL to report "nothing here" (no animations, no
// properties, no track of that width) the way GltfImporter itself does for
// tracks and properties, which it does not support.
//===----------------------------------------------------------------------===//

typedef struct ZozzImporterInterface {
  /// Mirrors OzzImporter::Load. Return non-zero on success.
  int (*load)(void* user, const char* filename);

  /// Mirrors OzzImporter::Import(RawSkeleton*, NodeType): fill `out` via
  /// zozzRawSkeletonAddJoint (and the other zozzRawSkeleton* entry points) —
  /// the same handle zozzSkeletonBuild accepts. Return non-zero on success.
  int (*import_skeleton)(void* user, ZozzImportNodeType types,
                         ZozzRawSkeleton* out);

  /// Mirrors OzzImporter::GetAnimationNames. Call `visitor` once per
  /// animation name, in any order. Optional: leave NULL to report none.
  void (*get_animation_names)(void* user, ZozzStringVisitor visitor,
                              void* visitor_user);

  /// Mirrors OzzImporter::Import(name, Skeleton&, rate, RawAnimation*): build
  /// `*out` via zozzRawAnimationCreate (sized from `skeleton`) and the
  /// zozzRawAnimationPush* entry points — the duration must be known before
  /// creating it, the same constraint any RawAnimation author has. Return
  /// non-zero on success.
  int (*import_animation)(void* user, const char* animation_name,
                          const ZozzSkeleton* skeleton, float sampling_rate,
                          ZozzRawAnimation** out);

  /// Mirrors OzzImporter::GetNodeProperties. Call `visitor` once per property
  /// of `node_name`. Optional: leave NULL to report no properties for any
  /// node.
  void (*get_node_properties)(void* user, const char* node_name,
                              ZozzNodePropertyVisitor visitor,
                              void* visitor_user);

  /// Mirror OzzImporter::Import(anim, node, track, type, rate,
  /// Raw*Track*) — one per track width. Optional: leave NULL to reject every
  /// track of that width.
  int (*import_float_track)(void* user, const char* animation_name,
                            const char* node_name, const char* track_name,
                            ZozzNodePropertyType track_type,
                            float sampling_rate, ZozzRawFloatTrack** out);
  int (*import_float2_track)(void* user, const char* animation_name,
                             const char* node_name, const char* track_name,
                             ZozzNodePropertyType track_type,
                             float sampling_rate, ZozzRawFloat2Track** out);
  int (*import_float3_track)(void* user, const char* animation_name,
                             const char* node_name, const char* track_name,
                             ZozzNodePropertyType track_type,
                             float sampling_rate, ZozzRawFloat3Track** out);
  int (*import_float4_track)(void* user, const char* animation_name,
                             const char* node_name, const char* track_name,
                             ZozzNodePropertyType track_type,
                             float sampling_rate, ZozzRawFloat4Track** out);

  /// Opaque host pointer, passed back to every callback above.
  void* user;
} ZozzImporterInterface;

/// Wraps a host's ZozzImporterInterface as a ZozzImporter handle. Behind
/// -Doptions (see the module comment above); returns
/// ZOZZ_RESULT_UNSUPPORTED when it is off. `interface` is copied by value.
ZOZZ_API ZozzResult zozzImporterCreate(const ZozzImporterInterface* interface,
                                       ZozzImporter** out);

//===----------------------------------------------------------------------===//
// The concrete glTF backend (-Dgltf)
//===----------------------------------------------------------------------===//

/// Constructs a GltfImporter and Loads `path` (.gltf or .glb, guessed from
/// the extension) in one call — the shape "import a skeleton/animation from
/// this file" wants; a host-implemented importer instead Loads explicitly
/// via zozzImporterLoad below, since it may not load from a path at all.
/// Behind -Dgltf; returns ZOZZ_RESULT_UNSUPPORTED when it is off.
ZOZZ_API ZozzResult zozzGltfImporterCreate(const char* path,
                                           ZozzImporter** out);

//===----------------------------------------------------------------------===//
// Generic accessors — drive any ZozzImporter, glTF-backed or host-backed,
// through the OzzImporter interface it implements. Always available: neither
// depends on tinygltf or the option parser.
//===----------------------------------------------------------------------===//

ZOZZ_API void zozzImporterDestroy(ZozzImporter* importer);

/// Loads (or reloads) source data. Most callers only need this when
/// zozzGltfImporterCreate did not already Load, or to point a host-backed
/// importer at its source.
ZOZZ_API ZozzResult zozzImporterLoad(ZozzImporter* importer,
                                     const char* filename);

/// Imports a skeleton, handed back as the same flat ZozzRawSkeleton handle
/// zozzRawSkeletonAddJoint builds by hand.
ZOZZ_API ZozzResult zozzImporterImportSkeleton(ZozzImporter* importer,
                                               ZozzImportNodeType types,
                                               ZozzRawSkeleton** out);

/// Calls `visitor` once per animation name available from the source data.
ZOZZ_API ZozzResult zozzImporterIterateAnimationNames(
    ZozzImporter* importer, ZozzStringVisitor visitor, void* user);

/// Imports one named animation against `skeleton`'s joints, handed back as
/// the same ZozzRawAnimation handle zozzRawAnimationCreate builds by hand.
/// `sampling_rate` of 0 means "let the importer choose".
ZOZZ_API ZozzResult zozzImporterImportAnimation(ZozzImporter* importer,
                                                const char* animation_name,
                                                const ZozzSkeleton* skeleton,
                                                float sampling_rate,
                                                ZozzRawAnimation** out);

/// Calls `visitor` once per property available for `node_name`.
ZOZZ_API ZozzResult zozzImporterIterateNodeProperties(
    ZozzImporter* importer, const char* node_name,
    ZozzNodePropertyVisitor visitor, void* user);

/// Track imports, one per value width, matching ZozzImporterInterface's
/// import_float*_track callbacks and OzzImporter's four Import(...Raw*Track*)
/// overloads.
ZOZZ_API ZozzResult zozzImporterImportFloatTrack(
    ZozzImporter* importer, const char* animation_name, const char* node_name,
    const char* track_name, ZozzNodePropertyType track_type,
    float sampling_rate, ZozzRawFloatTrack** out);

ZOZZ_API ZozzResult zozzImporterImportFloat2Track(
    ZozzImporter* importer, const char* animation_name, const char* node_name,
    const char* track_name, ZozzNodePropertyType track_type,
    float sampling_rate, ZozzRawFloat2Track** out);

ZOZZ_API ZozzResult zozzImporterImportFloat3Track(
    ZozzImporter* importer, const char* animation_name, const char* node_name,
    const char* track_name, ZozzNodePropertyType track_type,
    float sampling_rate, ZozzRawFloat3Track** out);

ZOZZ_API ZozzResult zozzImporterImportFloat4Track(
    ZozzImporter* importer, const char* animation_name, const char* node_name,
    const char* track_name, ZozzNodePropertyType track_type,
    float sampling_rate, ZozzRawFloat4Track** out);

//===----------------------------------------------------------------------===//
// The CLI driver — OzzImporter::operator()(argc, argv). See the module
// comment above: always ZOZZ_RESULT_UNSUPPORTED, on every build
// configuration, because jsoncpp is not vendored.
//===----------------------------------------------------------------------===//

/// Parses `argv` as ozz's own importer CLI would, reads a JSON config file
/// and writes .ozz files to disk. Currently always unsupported; see the
/// module comment above.
ZOZZ_API ZozzResult zozzImporterRun(ZozzImporter* importer, int argc,
                                    const char* const* argv);

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // ZOZZ_GLTF_H_
