//===----------------------------------------------------------------------===//
// zozz — the -Dgltf half of the importer: wraps ozz's vendored GltfImporter
// (gltf2ozz.cc) as a ZozzImporter. Compiled only when -Dgltf is on; see
// zozz_gltf.h and build.zig.
//
// GltfImporter is defined, not merely declared, in gltf2ozz.cc, which has no
// header, so the only way to name the type is to #include the .cc here.
// `main` is #defined away first: that file's `int main` (the CLI entry this
// binding skips, see zozz_gltf.h) cannot coexist with this library's object
// files. Renaming leaves the function body intact, still calling the CLI
// driver OzzImporter::operator() from import2ozz.cc, not compiled here; the
// stub below resolves that link-time reference without vendoring jsoncpp —
// it is never reached.
//===----------------------------------------------------------------------===//

#define main ZozzGltf2ozzUnusedMain
#include "animation/offline/gltf/gltf2ozz.cc"
#undef main

#include "zozz_internal.h"
#include "zozz_gltf.h"

namespace ozz {
namespace animation {
namespace offline {

int OzzImporter::operator()(int, const char**) {
  return -1;  // Unreachable: see the module comment above.
}

}  // namespace offline
}  // namespace animation
}  // namespace ozz

extern "C" {

ZozzResult zozzGltfImporterCreate(const char* path, ZozzImporter** out) {
  if (out == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  *out = nullptr;
  if (path == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;

  // Typed as the base here, not GltfImporter: Load is a private override in
  // GltfImporter (overriding OzzImporter's public one), which is legal C++
  // and calling it through the base's own public access works — accessing it
  // through GltfImporter's type directly would not.
  ozz::animation::offline::OzzImporter* backend = zozz::New<GltfImporter>();
  if (backend == nullptr) return ZOZZ_RESULT_OUT_OF_MEMORY;

  if (!backend->Load(path)) {
    zozz::Delete(backend);
    return ZOZZ_RESULT_BAD_FORMAT;
  }

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
