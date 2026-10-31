# zozz

[![CI](https://github.com/pedronaugusto/zozz/actions/workflows/ci.yml/badge.svg)](https://github.com/pedronaugusto/zozz/actions/workflows/ci.yml)

Zig bindings for the [ozz-animation](https://github.com/guillaumeblanc/ozz-animation)
runtime: load a skeleton and a clip, sample, blend, apply IK, skin a mesh, and
build those assets offline. Upstream ozz `0.17.0` is vendored with only the
defect fixes in `libs/patches` applied, and reached through a C ABI of this
package's own, with a Zig wrapper over it.

## Usage

A region of [`examples/usage.zig`](examples/usage.zig), which the tests build
and run; the gate fails when this file and that example differ.

<!-- BEGIN GENERATED zig build docs -- usage -->
```zig
const zozz = @import("zozz");

// Every call that can fail takes a `Failure`, which a refusal leaves
// holding the entry point that refused and the result it gave.
var failure: zozz.Failure = .{};
try zozz.setAllocator(gpa, &failure);
// Runs last, and can fail: restoring ozz's own allocator is refused while
// blocks this one produced are still live.
defer zozz.resetAllocator(&failure) catch |e| std.debug.panic("zozz: {s}", .{@errorName(e)});

// A handle is destroyed through a pointer, so it is a `var`: `deinit`
// nulls it, which makes a second destroy a no-op and a use after it a
// checked panic rather than a read of freed memory.
var skeleton = try zozz.Skeleton.initFromFile("skeleton.ozz", &failure);
defer skeleton.deinit();

var clip = try zozz.Animation.initFromFile("walk.ozz", &failure);
defer clip.deinit();

// The caller owns the pose. It can be a stack array, an arena slice, or a
// sub-range of a batch; `soaBlocks` says how long it has to be.
const blocks = try zozz.soaBlocks(skeleton.numJoints(), &failure);
const pose = try gpa.alloc(zozz.SoaTransform, blocks);
defer gpa.free(pose);

var context = try zozz.SamplingContext.initForSkeleton(skeleton, &failure);
defer context.deinit();

// Per frame:
try skeleton.restPoseSoa(pose, &failure);
try (zozz.SamplingJob{
    .animation = clip,
    .context = context,
    // `.loop` wraps in both directions; `.clamp` holds the end poses.
    .ratio = clip.ratioAt(time_seconds, .loop),
    .out = pose,
}).run(&failure);

// Either read local transforms out...
const locals = try gpa.alloc(zozz.Transform, skeleton.numJoints());
defer gpa.free(locals);
try zozz.pose.toLocalTransforms(pose, locals, &failure);

// ...or flatten the hierarchy to model space. Note the 16-byte alignment.
const models = try gpa.alignedAlloc(zozz.Mat4, .@"16", skeleton.numJoints());
defer gpa.free(models);
try (zozz.LocalToModelJob{
    .skeleton = skeleton,
    .locals = pose,
    .root = null,
    .out = models,
}).run(&failure);

// Blending takes the same spans and allocates nothing per call. `walk`
// and `run` here are two more poses, sampled the same way as `pose`.
const walk = try gpa.alloc(zozz.SoaTransform, blocks);
defer gpa.free(walk);
const run = try gpa.alloc(zozz.SoaTransform, blocks);
defer gpa.free(run);
const rest = try gpa.alloc(zozz.SoaTransform, blocks);
defer gpa.free(rest);
@memcpy(walk, pose);
@memcpy(run, pose);
try skeleton.restPoseSoa(rest, &failure);
try (zozz.BlendingJob{
    .layers = &.{ zozz.blending.layer(0.5, walk), zozz.blending.layer(0.5, run) },
    .rest_pose = rest,
    .out = pose,
}).run(&failure);

// A joint's skinning matrix is its model matrix times its inverse bind
// pose — the inverse of where the joint sat when the mesh was authored.
const joint = 1;
const inverse_bind = zozz.math.mat4.invert(models[joint], null);
const skinning = zozz.math.mat4.mul(models[joint], inverse_bind);
```
<!-- END GENERATED -->

## Install

```sh
zig fetch --save git+https://github.com/pedronaugusto/zozz#v0.5.0
```

```zig
const zozz_dep = b.dependency("zozz", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("zozz", zozz_dep.module("zozz"));

// A C or C++ host takes the library and its installed header instead:
exe.root_module.linkLibrary(zozz_dep.artifact("zozz"));  // then #include <zozz.h>
```

Forward `optimize` as shown: zozz does not turn on Zig's C sanitizer for you,
so a mismatched build mode is a size difference rather than a link failure, but
a Debug library inside a release executable is still not what you meant. There
are no package dependencies — ozz is vendored under `libs/ozz`. Zig `0.17.0` or
newer.

## The API

`src/zozz.zig` re-exports one name per concern and `ffi/zozz.h` gathers one
header per concern. Every C entry point has a Zig wrapper, paired at build time
by a reflective cross-check.

- Loading a skeleton or a clip from file or memory; sampling with a
  frame-coherency context; SoA ↔ AoS pose conversion
- Local-to-model over the whole hierarchy, or over ozz's own `from`/`to` joint
  range for re-running only the chain an IK correction touched
- Blending (`BlendingJob`): weighted, additive, per-joint partial. Two-bone and
  aim IK, and folding a correction back into a pose. Matrix-palette skinning
  (`SkinningJob`). Root-motion blending
- `ozz::math` as Zig rather than as foreign calls: SimdFloat4 and SimdInt4
  lane operations, quaternions, `Float4x4` including its `*`, `+` and `-`,
  `Transform` composition, `Box`
- Runtime tracks in five value types — float, float2, float3, float4,
  quaternion — plus edge-triggering over a `FloatTrack`; skeleton and animation
  utilities: single-joint rest pose, hierarchy traversal, name lookup,
  per-track keyframe counts
- Offline: author a `RawSkeleton` or `RawAnimation` at runtime and build it into
  the same runtime objects the loaders produce, with the animation optimizer,
  raw-animation sampling and re-timing, the additive animation builder,
  root-motion extraction, and the five raw track types
- The archive: `OArchive` writes a skeleton, clip or track to a host-controlled
  stream or a file, `IArchive` reads them back, and a tag test answers "is the
  next object a T?" without consuming it
- Importing: `OzzImporter` in both directions — the glTF backend
  (`Importer.initFromGltf`, `-Dgltf`) and a host-implementable
  `ImporterInterface` for a host with its own source format (`-Doptions`)

Sampling and blending allocate nothing per call; handle constructors and the
offline builders allocate through the installed allocator. Every release so far
has been a breaking change and there is no compatibility layer. A job is a
struct with a `run` method, mirroring ozz's own shape.

## Build options

| Option | Default | Effect |
|---|---|---|
| `-Dgltf` | off | Compile ozz's glTF importer backend. Pulls in tinygltf's whole implementation. |
| `-Doptions` | off | Compile ozz's command-line option parser and the `OzzImporter` interface. `options.cc` writes to `<iostream>`, which zozz otherwise never includes. |
| `-Dshared` | off | Build the C library as a shared object. |
| `-Denable_asserts` | on in Debug | Keep ozz's internal asserts. |
| `-Dsanitize_c` | off | Compile the C and C++ with Zig's undefined-behaviour sanitizer. |
| `-Dsimd_ref` | off | Compile ozz's scalar reference SIMD backend instead of this target's. |

With `-Dgltf` or `-Doptions` off, the calls behind them return
`error.Unsupported` rather than failing to compile. `zozz.buildFeatures()` asks
the linked library what it was compiled with, which tells a feature absent from
this build apart from a call that failed.

| Type | Archive version | Declared in |
|---|---:|---|
| `animation::Animation` | 7 | `include/ozz/animation/runtime/animation.h` |
| `animation::Float2Track` | 1 | `include/ozz/animation/runtime/track.h` |
| `animation::Float3Track` | 1 | `include/ozz/animation/runtime/track.h` |
| `animation::Float4Track` | 1 | `include/ozz/animation/runtime/track.h` |
| `animation::FloatTrack` | 1 | `include/ozz/animation/runtime/track.h` |
| `animation::QuaternionTrack` | 1 | `include/ozz/animation/runtime/track.h` |
| `animation::Skeleton` | 2 | `include/ozz/animation/runtime/skeleton.h` |
| `animation::offline::RawAnimation::JointTrack` | 1 | `src/animation/offline/raw_animation_archive.cc` |
| `animation::offline::RawAnimation::RotationKey` | 1 | `src/animation/offline/raw_animation_archive.cc` |
| `animation::offline::RawAnimation::ScaleKey` | 1 | `src/animation/offline/raw_animation_archive.cc` |
| `animation::offline::RawAnimation::TranslationKey` | 1 | `src/animation/offline/raw_animation_archive.cc` |
| `animation::offline::RawAnimation` | 3 | `include/ozz/animation/offline/raw_animation.h` |
| `animation::offline::RawFloat2Track` | 1 | `include/ozz/animation/offline/raw_track.h` |
| `animation::offline::RawFloat3Track` | 1 | `include/ozz/animation/offline/raw_track.h` |
| `animation::offline::RawFloat4Track` | 1 | `include/ozz/animation/offline/raw_track.h` |
| `animation::offline::RawFloatTrack` | 1 | `include/ozz/animation/offline/raw_track.h` |
| `animation::offline::RawQuaternionTrack` | 1 | `include/ozz/animation/offline/raw_track.h` |
| `animation::offline::RawSkeleton::Joint` | 1 | `src/animation/offline/raw_skeleton_archive.cc` |
| `animation::offline::RawSkeleton` | 1 | `include/ozz/animation/offline/raw_skeleton.h` |
ndary check, the ABI guard, what upstream does that the
boundary stands in front of, and how the vendored copy is checked and updated.

## Scope

ozz-animation at the vendored version: ozz `0.17.0`, its commit pinned, taken
with only the patches in `libs/patches` applied, each listed in
[docs/design.md](docs/design.md#patches); `zig build check-vendor` fetches that
commit, applies them and diffs the result against `libs/` in the gate. Every public name ozz declares in its include tree is
accounted for: `zig build check-coverage` enumerates them from ozz's headers,
requires a verdict for each (bound across the C ABI, delivered as a C callback,
provided in Zig, provided by the Zig language, or internal to ozz) and fails on
one that has none. Not available:

- **The FBX importer**, which needs the proprietary Autodesk FBX SDK. Its
  sources are not vendored.
- **`gltf2ozz`'s command line.** Its driver (`OzzImporter::operator()`,
  `Importer.run`) is configured through jsoncpp, which upstream keeps outside
  the vendored tree, and reports `error.Unsupported`. The importer underneath
  builds: `Importer.initFromGltf` reads glTF and glb and hands back the
  `RawSkeleton` and `RawAnimation` the offline builders take, so a file is
  imported, optimised and built in process.
- **Assets from another ozz version.** ozz versions its archives per type and
  refuses a version it does not know, so an `.ozz` file loads here only if the
  ozz that wrote it declared the versions below. Animation version 6 files are
  common and load as `BadFormat`, though their skeletons still load.

<!-- BEGIN GENERATED zig build archive-versions -->
| Type | Archive version | Declared in |
|---|---:|---|
| `animation::Animation` | 7 | `include/ozz/animation/runtime/animation.h` |
| `animation::Float2Track` | 1 | `include/ozz/animation/runtime/track.h` |
| `animation::Float3Track` | 1 | `include/ozz/animation/runtime/track.h` |
| `animation::Float4Track` | 1 | `include/ozz/animation/runtime/track.h` |
| `animation::FloatTrack` | 1 | `include/ozz/animation/runtime/track.h` |
| `animation::QuaternionTrack` | 1 | `include/ozz/animation/runtime/track.h` |
| `animation::Skeleton` | 2 | `include/ozz/animation/runtime/skeleton.h` |
| `animation::offline::RawAnimation::JointTrack` | 1 | `src/animation/offline/raw_animation_archive.cc` |
| `animation::offline::RawAnimation::RotationKey` | 1 | `src/animation/offline/raw_animation_archive.cc` |
| `animation::offline::RawAnimation::ScaleKey` | 1 | `src/animation/offline/raw_animation_archive.cc` |
| `animation::offline::RawAnimation::TranslationKey` | 1 | `src/animation/offline/raw_animation_archive.cc` |
| `animation::offline::RawAnimation` | 3 | `include/ozz/animation/offline/raw_animation.h` |
| `animation::offline::RawFloat2Track` | 1 | `include/ozz/animation/offline/raw_track.h` |
| `animation::offline::RawFloat3Track` | 1 | `include/ozz/animation/offline/raw_track.h` |
| `animation::offline::RawFloat4Track` | 1 | `include/ozz/animation/offline/raw_track.h` |
| `animation::offline::RawFloatTrack` | 1 | `include/ozz/animation/offline/raw_track.h` |
| `animation::offline::RawQuaternionTrack` | 1 | `include/ozz/animation/offline/raw_track.h` |
| `animation::offline::RawSkeleton::Joint` | 1 | `src/animation/offline/raw_skeleton_archive.cc` |
| `animation::offline::RawSkeleton` | 1 | `include/ozz/animation/offline/raw_skeleton.h` |
<!-- END GENERATED -->

## Platforms

CI is preflight's (`.github/workflows/ci.yml`, generated from
`ci/workflow.json`). Its nightly matrix runs the suite in Debug and
ReleaseSafe on Linux x86_64 (ReleaseFast too) and aarch64, glibc; macOS
aarch64; and Windows x86_64 and aarch64, gnu ABI; and in Debug on riscv64
Linux under QEMU. It compiles every target in `ci/workflow.json` and
ReleaseSmall, and links the macOS and Windows targets,
`x86_64-windows-msvc` among them, against their SDKs. The suite on
`x86_64-windows-msvc` is executed on a Windows machine before each release,
in every optimize mode, until preflight's matrix executes it.

## Testing

```sh
bay test                # the gate: every suite arm, the checks, lint, docs
zig build test          # the suite arms alone, examples/ included
zig build test-c        # the C header on its own, no Zig in the picture
bay probe               # each invariant in ci/probes/, mutated, must fail
```

The suite runs in seven arms (under the C sanitizer, as a consumer builds it,
with the asserts flipped, with each optional half and both, and on ozz's scalar
SIMD backend) and builds its assets at test time through ozz's own offline
builders, so it ships no third-party clips. `-Dsanitize_c=true` skips the
truncated-archive test, for an upstream null-pointer member access
docs/design.md records. `bay dev bench` times each binding beside the same ozz
work in C++.

## By the numbers

<!-- BEGIN GENERATED zig build measurements -->
| | |
|---:|---|
| **0.5.0** | version, the same in `build.zig.zon` and `ffi/zozz_core.h` |
| **359** | C entry points (`ZOZZ_API` in `ffi/*.h`), each with its Zig extern |
| **19** | installed public headers: `zozz.h` and those it includes |
| **414** | public ozz names no entry point spells out, each carrying a verdict in `ci/coverage/` |
| **122** | of them reachable through the C boundary under another name (`BOUND`) |
| **5** | C++ virtuals delivered as C callbacks (`EXTENSION`) |
| **217** | provided in Zig without crossing the boundary (`ZIG`) |
| **38** | provided by the Zig language (`LANGUAGE`) |
| **32** | internal to ozz or compiled by no source here (`INTERNAL`) |
| **207** | assertions in the standalone C smoke test |
| **41** | vendored ozz translation units `build.zig` compiles |
| **20** | zozz C++ translation units (`ffi/*.cpp`) |
| **18** | invariants `bay probe` mutates, each with the test that must notice |
<!-- END GENERATED -->

`zig build measurements` recomputes these from the tree, and the gate fails if
the committed block differs, or if a document states a number by hand that
`ci/numbers.zig` does not account for.


## Contributing

Issues and pull requests are welcome. The rules a change has to satisfy, and
the binding conventions a new area follows, are in
[docs/design.md](docs/design.md); `bay test` is green before a push.

## Licence

MIT, see [LICENSE](LICENSE), which covers this package's own code. Vendored
ozz-animation is MIT, copyright Guillaume Blanc and contributors; its licence
text ships at `libs/ozz/LICENSE.md` and its authors at `libs/ozz/AUTHORS.md`.
