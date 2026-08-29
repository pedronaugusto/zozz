//===----------------------------------------------------------------------===//
// zozz — OzzImporter: the generic accessors (always available), the
// host-implementable interface (-Doptions), and the CLI driver stub. See
// zozz_gltf.h's module comment for the shape and the build-option split.
// zozz_gltf_backend.cpp is the -Dgltf half: the concrete GltfImporter.
//===----------------------------------------------------------------------===//

#include <cmath>
#include <utility>

#include "zozz_internal.h"
#include "zozz_gltf.h"

namespace {

ozz::animation::offline::OzzImporter::NodeType ToOzz(
    const ZozzImportNodeType& types) {
  ozz::animation::offline::OzzImporter::NodeType out{};
  out.skeleton = types.skeleton;
  out.marker = types.marker;
  out.camera = types.camera;
  out.geometry = types.geometry;
  out.light = types.light;
  out.null = types.null;
  out.any = types.any;
  return out;
}

}  // namespace

//===----------------------------------------------------------------------===//
// The host-implementable side (-Doptions)
//===----------------------------------------------------------------------===//

#ifdef ZOZZ_WITH_OPTIONS

namespace {

class HostImporter : public ozz::animation::offline::OzzImporter {
 public:
  explicit HostImporter(const ZozzImporterInterface& interface)
      : interface_(interface) {}

  bool Load(const char* filename) override {
    return interface_.load(interface_.user, filename) != 0;
  }

  bool Import(ozz::animation::offline::RawSkeleton* skeleton,
             const NodeType& types) override {
    ZozzImportNodeType c_types;
    c_types.skeleton = types.skeleton;
    c_types.marker = types.marker;
    c_types.camera = types.camera;
    c_types.geometry = types.geometry;
    c_types.light = types.light;
    c_types.null = types.null;
    c_types.any = types.any;

    ZozzRawSkeleton* flat = nullptr;
    if (zozzRawSkeletonCreate(&flat) != ZOZZ_RESULT_OK) return false;
    const bool ok =
        interface_.import_skeleton(interface_.user, c_types, flat) != 0;
    const bool built =
        ok && zozz::FlattenToNestedSkeleton(flat, skeleton) == ZOZZ_RESULT_OK;
    zozzRawSkeletonDestroy(flat);
    return built;
  }

  AnimationNames GetAnimationNames() override {
    AnimationNames names;
    if (interface_.get_animation_names != nullptr) {
      interface_.get_animation_names(interface_.user, &CollectName, &names);
    }
    return names;
  }

  bool Import(const char* animation_name,
             const ozz::animation::Skeleton& skeleton, float sampling_rate,
             ozz::animation::offline::RawAnimation* animation) override {
    if (interface_.import_animation == nullptr) return false;
    // ZozzSkeleton's only member is `impl`, of this exact reference's type,
    // so the address of one is the address of the other (standard layout) —
    // cheaper than round-tripping through a copy the host would then have to
    // free.
    const ZozzSkeleton* handle = reinterpret_cast<const ZozzSkeleton*>(&skeleton);
    ZozzRawAnimation* out = nullptr;
    if (interface_.import_animation(interface_.user, animation_name, handle,
                                    sampling_rate, &out) == 0 ||
        out == nullptr) {
      return false;
    }
    *animation = std::move(out->impl);
    zozzRawAnimationDestroy(out);
    return true;
  }

  NodeProperties GetNodeProperties(const char* node_name) override {
    NodeProperties properties;
    if (interface_.get_node_properties != nullptr) {
      interface_.get_node_properties(interface_.user, node_name,
                                     &CollectProperty, &properties);
    }
    return properties;
  }

  bool Import(const char* animation_name, const char* node_name,
             const char* track_name, NodeProperty::Type track_type,
             float sampling_rate,
             ozz::animation::offline::RawFloatTrack* track) override {
    if (interface_.import_float_track == nullptr) return false;
    ZozzRawFloatTrack* out = nullptr;
    if (interface_.import_float_track(
            interface_.user, animation_name, node_name, track_name,
            static_cast<ZozzNodePropertyType>(track_type), sampling_rate,
            &out) == 0 ||
        out == nullptr) {
      return false;
    }
    *track = std::move(out->impl);
    zozzRawFloatTrackDestroy(out);
    return true;
  }

  bool Import(const char* animation_name, const char* node_name,
             const char* track_name, NodeProperty::Type track_type,
             float sampling_rate,
             ozz::animation::offline::RawFloat2Track* track) override {
    if (interface_.import_float2_track == nullptr) return false;
    ZozzRawFloat2Track* out = nullptr;
    if (interface_.import_float2_track(
            interface_.user, animation_name, node_name, track_name,
            static_cast<ZozzNodePropertyType>(track_type), sampling_rate,
            &out) == 0 ||
        out == nullptr) {
      return false;
    }
    *track = std::move(out->impl);
    zozzRawFloat2TrackDestroy(out);
    return true;
  }

  bool Import(const char* animation_name, const char* node_name,
             const char* track_name, NodeProperty::Type track_type,
             float sampling_rate,
             ozz::animation::offline::RawFloat3Track* track) override {
    if (interface_.import_float3_track == nullptr) return false;
    ZozzRawFloat3Track* out = nullptr;
    if (interface_.import_float3_track(
            interface_.user, animation_name, node_name, track_name,
            static_cast<ZozzNodePropertyType>(track_type), sampling_rate,
            &out) == 0 ||
        out == nullptr) {
      return false;
    }
    *track = std::move(out->impl);
    zozzRawFloat3TrackDestroy(out);
    return true;
  }

  bool Import(const char* animation_name, const char* node_name,
             const char* track_name, NodeProperty::Type track_type,
             float sampling_rate,
             ozz::animation::offline::RawFloat4Track* track) override {
    if (interface_.import_float4_track == nullptr) return false;
    ZozzRawFloat4Track* out = nullptr;
    if (interface_.import_float4_track(
            interface_.user, animation_name, node_name, track_name,
            static_cast<ZozzNodePropertyType>(track_type), sampling_rate,
            &out) == 0 ||
        out == nullptr) {
      return false;
    }
    *track = std::move(out->impl);
    zozzRawFloat4TrackDestroy(out);
    return true;
  }

 private:
  static void CollectName(const char* value, void* user) {
    static_cast<AnimationNames*>(user)->push_back(ozz::string(value));
  }

  static void CollectProperty(const ZozzNodeProperty* property, void* user) {
    NodeProperty p;
    p.name = property->name;
    p.type = static_cast<NodeProperty::Type>(property->type);
    static_cast<NodeProperties*>(user)->push_back(p);
  }

  ZozzImporterInterface interface_;
};

}  // namespace

extern "C" {

ZozzResult zozzImporterCreate(const ZozzImporterInterface* interface,
                              ZozzImporter** out) {
  if (out == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  *out = nullptr;
  if (interface == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  // Required callbacks are validated here, not on first use — the same rule
  // zozzOArchiveCreate/zozzIArchiveCreate apply to ZozzStream.
  if (interface->load == nullptr || interface->import_skeleton == nullptr ||
      interface->import_animation == nullptr) {
    return ZOZZ_RESULT_INVALID_ARGUMENT;
  }

  HostImporter* backend = zozz::New<HostImporter>(*interface);
  if (backend == nullptr) return ZOZZ_RESULT_OUT_OF_MEMORY;

  ZozzImporter* importer = zozz::New<ZozzImporter>();
  if (importer == nullptr) {
    zozz::Delete(backend);
    return ZOZZ_RESULT_OUT_OF_MEMORY;
  }
  importer->impl = backend;
  *out = importer;
  return ZOZZ_RESULT_OK;
}

}  // extern "C"

#else  // !ZOZZ_WITH_OPTIONS

extern "C" {

ZozzResult zozzImporterCreate(const ZozzImporterInterface*, ZozzImporter** out) {
  if (out != nullptr) *out = nullptr;
  return ZOZZ_RESULT_UNSUPPORTED;
}

}  // extern "C"

#endif  // ZOZZ_WITH_OPTIONS

//===----------------------------------------------------------------------===//
// The concrete glTF backend's stub — real zozzGltfImporterCreate lives in
// zozz_gltf_backend.cpp, compiled only when -Dgltf is on.
//===----------------------------------------------------------------------===//

#ifndef ZOZZ_WITH_GLTF

extern "C" {

ZozzResult zozzGltfImporterCreate(const char*, ZozzImporter** out) {
  if (out != nullptr) *out = nullptr;
  return ZOZZ_RESULT_UNSUPPORTED;
}

}  // extern "C"

#endif  // !ZOZZ_WITH_GLTF

//===----------------------------------------------------------------------===//
// Generic accessors — always available.
//===----------------------------------------------------------------------===//

extern "C" {

void zozzImporterDestroy(ZozzImporter* importer) {
  if (importer == nullptr) return;
  zozz::Delete(importer->impl);  // Virtual dtor: GltfImporter or HostImporter.
  zozz::Delete(importer);
}

ZozzResult zozzImporterLoad(ZozzImporter* importer, const char* filename) {
  if (importer == nullptr || filename == nullptr) {
    return ZOZZ_RESULT_INVALID_ARGUMENT;
  }
  return importer->impl->Load(filename) ? ZOZZ_RESULT_OK : ZOZZ_RESULT_BAD_FORMAT;
}

ZozzResult zozzImporterImportSkeleton(ZozzImporter* importer,
                                      ZozzImportNodeType types,
                                      ZozzRawSkeleton** out) {
  if (importer == nullptr || out == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  *out = nullptr;
  ozz::animation::offline::RawSkeleton nested;
  if (!importer->impl->Import(&nested, ToOzz(types))) {
    return ZOZZ_RESULT_INVALID_DATA;
  }
  return zozz::BuildFlatSkeleton(nested, out);
}

ZozzResult zozzImporterIterateAnimationNames(ZozzImporter* importer,
                                             ZozzStringVisitor visitor,
                                             void* user) {
  if (importer == nullptr || visitor == nullptr) {
    return ZOZZ_RESULT_INVALID_ARGUMENT;
  }
  for (const ozz::string& name : importer->impl->GetAnimationNames()) {
    visitor(name.c_str(), user);
  }
  return ZOZZ_RESULT_OK;
}

ZozzResult zozzImporterImportAnimation(ZozzImporter* importer,
                                       const char* animation_name,
                                       const ZozzSkeleton* skeleton,
                                       float sampling_rate,
                                       ZozzRawAnimation** out) {
  if (importer == nullptr || animation_name == nullptr || skeleton == nullptr ||
      out == nullptr) {
    return ZOZZ_RESULT_INVALID_ARGUMENT;
  }
  *out = nullptr;
  if (!std::isfinite(sampling_rate) || sampling_rate < 0.f) {
    return ZOZZ_RESULT_INVALID_ARGUMENT;
  }

  ZozzRawAnimation* handle = zozz::New<ZozzRawAnimation>();
  if (handle == nullptr) return ZOZZ_RESULT_OUT_OF_MEMORY;
  if (!importer->impl->Import(animation_name, skeleton->impl, sampling_rate,
                              &handle->impl)) {
    zozz::Delete(handle);
    return ZOZZ_RESULT_INVALID_DATA;
  }
  *out = handle;
  return ZOZZ_RESULT_OK;
}

ZozzResult zozzImporterIterateNodeProperties(ZozzImporter* importer,
                                             const char* node_name,
                                             ZozzNodePropertyVisitor visitor,
                                             void* user) {
  if (importer == nullptr || node_name == nullptr || visitor == nullptr) {
    return ZOZZ_RESULT_INVALID_ARGUMENT;
  }
  const auto properties = importer->impl->GetNodeProperties(node_name);
  for (const auto& property : properties) {
    const ZozzNodeProperty c_property = {
        property.name.c_str(),
        static_cast<ZozzNodePropertyType>(property.type)};
    visitor(&c_property, user);
  }
  return ZOZZ_RESULT_OK;
}

}  // extern "C"

namespace {

/// Shared shape of the four track-import entry points below: validate,
/// allocate the handle, dispatch to the OzzImporter overload C++ picks by
/// `Handle::impl`'s type, unwind on failure.
template <typename Handle>
ZozzResult ImportTrack(ZozzImporter* importer, const char* animation_name,
                       const char* node_name, const char* track_name,
                       ZozzNodePropertyType track_type, float sampling_rate,
                       Handle** out) {
  if (importer == nullptr || animation_name == nullptr ||
      node_name == nullptr || track_name == nullptr || out == nullptr) {
    return ZOZZ_RESULT_INVALID_ARGUMENT;
  }
  *out = nullptr;
  const int32_t raw_type = zozz::RawEnum(track_type);
  if (raw_type < ZOZZ_NODE_PROPERTY_TYPE_FLOAT1 ||
      raw_type > ZOZZ_NODE_PROPERTY_TYPE_VECTOR) {
    return ZOZZ_RESULT_INVALID_ARGUMENT;
  }
  if (!std::isfinite(sampling_rate) || sampling_rate < 0.f) {
    return ZOZZ_RESULT_INVALID_ARGUMENT;
  }

  Handle* handle = zozz::New<Handle>();
  if (handle == nullptr) return ZOZZ_RESULT_OUT_OF_MEMORY;
  const auto type =
      static_cast<ozz::animation::offline::OzzImporter::NodeProperty::Type>(
          raw_type);
  if (!importer->impl->Import(animation_name, node_name, track_name, type,
                              sampling_rate, &handle->impl)) {
    zozz::Delete(handle);
    return ZOZZ_RESULT_INVALID_DATA;
  }
  *out = handle;
  return ZOZZ_RESULT_OK;
}

}  // namespace

extern "C" {

ZozzResult zozzImporterImportFloatTrack(ZozzImporter* importer,
                                        const char* animation_name,
                                        const char* node_name,
                                        const char* track_name,
                                        ZozzNodePropertyType track_type,
                                        float sampling_rate,
                                        ZozzRawFloatTrack** out) {
  return ImportTrack(importer, animation_name, node_name, track_name,
                     track_type, sampling_rate, out);
}

ZozzResult zozzImporterImportFloat2Track(ZozzImporter* importer,
                                         const char* animation_name,
                                         const char* node_name,
                                         const char* track_name,
                                         ZozzNodePropertyType track_type,
                                         float sampling_rate,
                                         ZozzRawFloat2Track** out) {
  return ImportTrack(importer, animation_name, node_name, track_name,
                     track_type, sampling_rate, out);
}

ZozzResult zozzImporterImportFloat3Track(ZozzImporter* importer,
                                         const char* animation_name,
                                         const char* node_name,
                                         const char* track_name,
                                         ZozzNodePropertyType track_type,
                                         float sampling_rate,
                                         ZozzRawFloat3Track** out) {
  return ImportTrack(importer, animation_name, node_name, track_name,
                     track_type, sampling_rate, out);
}

ZozzResult zozzImporterImportFloat4Track(ZozzImporter* importer,
                                         const char* animation_name,
                                         const char* node_name,
                                         const char* track_name,
                                         ZozzNodePropertyType track_type,
                                         float sampling_rate,
                                         ZozzRawFloat4Track** out) {
  return ImportTrack(importer, animation_name, node_name, track_name,
                     track_type, sampling_rate, out);
}

//===----------------------------------------------------------------------===//
// The CLI driver — always unsupported. See zozz_gltf.h's module comment:
// OzzImporter::operator() needs import2ozz_config.cc's JSON handling, which
// needs jsoncpp, which UPSTREAM.md records as deliberately excluded from the
// vendored tree ("What was excluded, and why").
//===----------------------------------------------------------------------===//

ZozzResult zozzImporterRun(ZozzImporter*, int, const char* const*) {
  return ZOZZ_RESULT_UNSUPPORTED;
}

}  // extern "C"
