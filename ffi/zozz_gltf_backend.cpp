//===----------------------------------------------------------------------===//
// zozz — the -Dgltf half of the importer: wraps ozz's vendored GltfImporter
// (gltf2ozz.cc) as a ZozzImporter. Compiled only when -Dgltf is on; see
// zozz_gltf.h and build.zig.
//
// gltf2ozz.cc has no header of its own — GltfImporter is defined, not merely
// declared, directly in that .cc file, so the only way to name the type at
// all is to #include the .cc into a translation unit of ours; a bare
// -Dmain=... flag on gltf2ozz.cc itself would rename its `int main` cleanly
// enough, but would still leave GltfImporter unreachable from any other file,
// since nothing would declare it. `main` is #defined away first because that
// `int main` (the CLI entry point this binding does not use — see
// zozz_gltf.h) cannot coexist with this library's own object files.
//
// Renaming does not remove that function's body, which calls
// OzzImporter::operator() — the CLI driver, defined in import2ozz.cc, which
// this build does not compile (see zozz_gltf.h). Nothing ever calls the
// renamed function either, but it still lives in this translation unit's
// object file alongside GltfImporter, so the linker still needs
// operator()'s symbol to resolve once anything else in this file is
// referenced. The stub below satisfies that without vendoring jsoncpp: it
// is never reached.
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
