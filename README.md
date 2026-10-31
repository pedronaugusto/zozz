# zozz

[![CI](https://github.com/pedronaugusto/zozz/actions/workflows/ci.yml/badge.svg)](https://github.com/pedronaugusto/zozz/actions/workflows/ci.yml)

Zig bindings for the [ozz-animation](https://github.com/guillaumeblanc/ozz-animation)
runtime: load a skeleton and a clip, sample, blend, apply IK, skin a mesh, and
build those assets offline. Upstream ozz `0.17.0` is vendored unmodified and
reached through a C ABI of this package's own, with a Zig wrapper over it.

## Usage

A region of [`examples/usage.zig`](examples/usage.zig), which the tests build
and run; the gate fails when this file and that example differ.

<!-- BEGIN GENERATED zig build docs -- usage -->
```zig
const zozz = @import("zozz");

try zozz.setAllocator(gpa);
// Runs last, and can fail: restoring ozz's own allocator is refused while
// blocks this one produced are still live.
defer zozz.resetAllocator() catch |e| std.debug.panic("zozz: {s}", .{@errorName(e)});

// A handle is destroyed through a pointer, so it is a `var`: `deinit`
// nulls it, which makes a second destroy a no-op and a use after it a
// checked panic rather than a read of freed memory.
var skeleton = try zozz.Skeleton.initFromFile("skeleton.ozz");
defer skeleton.deinit();

var clip = try zozz.Animation.initFromFile("walk.ozz");
defer clip.deinit();

// The caller owns the pose. It can be a stack array, an arena slice, or a
// sub-range of a batch; `soaBlocks` says how long it has to be.
const blocks = try zozz.soaBlocks(skeleton.numJoints());
const pose = try gpa.alloc(zozz.SoaTransform, blocks);
defer gpa.free(pose);

var context = try zozz.SamplingContext.initForSkeleton(skeleton);
defer context.deinit();

// Per frame:
try skeleton.restPoseSoa(pose);
try (zozz.SamplingJob{
    .animation = clip,
    .context = context,
    // `.loop` wraps in both directions; `.clamp` holds the end poses.
    .ratio = clip.ratioAt(time_seconds, .loop),
    .out = pose,
}).run();

// Either read local transforms out...
const locals = try gpa.alloc(zozz.Transform, skeleton.numJoints());
defer gpa.free(locals);
try zozz.pose.toLocalTransforms(pose, locals);

// ...or flatten the hierarchy to model space. Note the 16-byte alignment.
const models = try gpa.alignedAlloc(zozz.Mat4, .@"16", skeleton.numJoints());
defer gpa.free(models);
try (zozz.LocalToModelJob{
    .skeleton = skeleton,
    .locals = pose,
    .root = null,
    .out = models,
}).run();

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
try skeleton.restPoseSoa(rest);
try (zozz.BlendingJob{
    .layers = &.{ zozz.blending.layer(0.5, walk), zozz.blending.layer(0.5, run) },
    .rest_pose = rest,
    .out = pose,
}).run();

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

## Design

### The caller owns the SoA pose

ozz's job pipeline speaks structure-of-arrays: sampling writes it, blending
consumes and produces it, local-to-model reads it. A pose is a
`[]SoaTransform` — one element per four joints, `soaBlocks(n)` of them — and
every entry point takes that slice, which is exactly the `ozz::span` the C++
jobs take. Conversion to `Transform` happens only at the edges. The memory is
yours: a pose can live on the stack, in an arena, or as a sub-range of a batch,
and a `BlendingLayer` is `ozz::animation::BlendingJob::Layer` field for field,
so `BlendingJob.run` hands your array straight to ozz with no copy. Every entry
point taking SoA memory checks the 16-byte boundary and returns
`ZOZZ_RESULT_INVALID_ARGUMENT` rather than letting ozz fault on an aligned SIMD
load.

### Allocators

`setAllocator` routes every ozz allocation through a `std.mem.Allocator`. It is
process-wide, because ozz's own allocator is a single global and no ozz entry
point takes an allocator parameter. Installing or resetting is refused with
`ZOZZ_RESULT_ALLOCATOR_IN_USE` while `zozzAllocatorLiveBlocks()` is non-zero and
the call would change where a free lands; reinstalling the identical allocator,
or resetting while none is installed, always succeeds. Swapping one Zig
allocator for another is safe with blocks live, because each block records its
producer and frees through it. The count covers every outstanding ozz block, not
only the host's, so it doubles as a leak check for a host whose allocator has
none.

Distinct handles may be used concurrently as long as the installed allocator is
thread-safe, because every entry point that allocates arrives at this one seam.
A single handle is not internally synchronised, and neither is installing or
resetting: do that from one thread before any other is inside zozz.
[docs/allocators.md](docs/allocators.md) has the mechanism.

### Validation at the boundary

ozz's archive reader guards its reads and its tag check with `assert`s, which
`NDEBUG` removes, so the loaders here bracket it: a tag test before parsing,
every archive — files included — read through a stream that cannot return
short, and a sanity check of joint counts, array lengths and duration after.
Malformed and truncated input is `BadFormat`; NaN ratios and misaligned matrix
buffers are refused rather than faulting inside SIMD code. An allocation
failure inside ozz itself is a null dereference there, with no position to
intercept it from.
[docs/validation.md](docs/validation.md) has each check;
[UPSTREAM.md](UPSTREAM.md) the upstream sites with file and line.

### The ABI guard

`src/c.zig` hand-writes its `extern` declarations rather than running
translate-c, so the shipped module never compiles C. Three checks hold those
declarations to reality: `src/abi_test.zig` compares them against `ffi/zozz.h`
by reflection, `zozzAbiLayout()` compares them against the linked library, and
`static_assert`s in `ffi/zozz_abi.cpp` compare the C++ against ozz.
`bay probe` proves the first one fires: each drift in `ci/probes/` must fail
it. That check pairs declarations to the header by name, so the naming
convention in
[BINDING.md](BINDING.md) is a build requirement.
[docs/abi-guard.md](docs/abi-guard.md) has what each check covers;
[docs/build-hygiene.md](docs/build-hygiene.md) the rules `build.zig` keeps.

## Scope

The scope is ozz-animation at the vendored version: ozz `0.17.0`, commit
pinned, taken unmodified. `zig build check-vendor` fetches that commit and
diffs it against `libs/` in the gate, and [UPSTREAM.md](UPSTREAM.md) records what
was left out of the vendored tree and every upstream behaviour worked around
here.

Every public name ozz declares in its include tree is accounted for, and
`zig build check-coverage` is what says so: it enumerates them from ozz's own
headers, requires a verdict for each — bound across the C ABI, delivered as a C
callback, provided in Zig, provided by the Zig language, or internal to ozz —
and fails the build on one that has none. Every directory under
`libs/ozz/include/ozz` counts. Not available:

- **The FBX importer**, which needs the proprietary Autodesk FBX SDK. Its
  sources are not vendored.
- **`gltf2ozz`'s command line.** Its driver (`OzzImporter::operator()`,
  `Importer.run`) is configured through jsoncpp, in upstream's excluded
  `extern/`, and reports `error.Unsupported`. The importer underneath it does
  build: `Importer.initFromGltf` reads glTF and glb through the vendored
  `tiny_gltf.h` and hands back the `RawSkeleton` and `RawAnimation` the offline
  builders take, so a file is imported, optimised and built in process.
- **Assets from an older toolchain.** ozz versions its archives per type and
  refuses what it does not recognise; animation version 6 files are common and
  load as `BadFormat` here, though their skeletons still load.

## Platforms

| Platform | Suite executed by CI | Also compile-checked by CI |
|---|---|---|
| Linux | x86_64 glibc | aarch64 glibc, x86_64 and aarch64 musl |
| macOS | aarch64 | x86_64 |
| Windows | x86_64, gnu ABI and MSVC ABI | aarch64 gnu |

Every job in that matrix passed on run
[`34779004370`](https://github.com/pedronaugusto/zozz/actions/runs/34779004370).
Where the suite runs it runs in every optimize mode, plus the standalone C test,
the three non-default combinations of `-Dgltf` and `-Doptions`, ozz's scalar
reference SIMD backend, and the downstream-consumer build.

## Testing

```sh
bay test                # the gate: every suite arm, the checks, lint, docs
zig build test          # the suite arms alone, examples/ included
zig build test-c        # the C header on its own, no Zig in the picture
bay probe               # each invariant in ci/probes/, mutated, must fail
```

Assets are built at test time through ozz's own offline builders and serialised
in memory (`tests/fixture.cpp`), so the suite is version-matched to the vendored
runtime and ships no third-party clips. `zig build check-consumer` builds zozz
the way a downstream package does, through `b.dependency` — a path nothing in
`src/` or `tests/` exercises.

`-Dsanitize_c=true` skips the truncated-archive test: upstream ozz forms member
accesses on a null pointer when a keyframe array has zero entries, the exact
shape a zero-filled count produces. `-Dskeleton_path=` and `-Danimation_path=`
add a real asset on disk, held to unit-length quaternions, finite transforms,
parent-precedes-child joint ordering, root joints whose model matrix matches
their local translation, a clip that moves, and a refused NaN ratio.

### By the numbers

<!-- BEGIN GENERATED zig build measurements -->
| | |
|---:|---|
| **0.5.0** | version, the same in `build.zig.zon` and `ffi/zozz_core.h` |
| **359** | C entry points (`ZOZZ_API` in `ffi/*.h`), each with its Zig extern |
| **19** | installed public headers: `zozz.h` and those it includes |
| **321** | public ozz names no entry point spells out, each carrying a verdict in `ci/coverage/` |
| **36** | of them reachable through the C boundary under another name (`BOUND`) |
| **5** | C++ virtuals delivered as C callbacks (`EXTENSION`) |
| **212** | provided in Zig without crossing the boundary (`ZIG`) |
| **36** | provided by the Zig language (`LANGUAGE`) |
| **32** | internal to ozz or compiled by no source here (`INTERNAL`) |
| **206** | assertions in the standalone C smoke test |
| **41** | vendored ozz translation units `build.zig` compiles |
| **20** | zozz C++ translation units (`ffi/*.cpp`) |
| **18** | invariants `bay probe` mutates, each with the test that must notice |
<!-- END GENERATED -->

`zig build measurements` recomputes these from the tree, and the gate fails if
the committed block differs, or if a document states a number by hand that
`ci/numbers.zig` does not account for.

## Contributing

Issues and pull requests are welcome; [BINDING.md](BINDING.md) is the contract
a new area has to satisfy. `libs/ozz` is vendored verbatim and must not be
edited — changes there are lost at the next re-vendor, so work around upstream
in `ffi/` and record it in [UPSTREAM.md](UPSTREAM.md). Run `bay test` before
pushing. Comments state a contract, not a narrative, and `zig build
check-comments` enforces the length cap
and the register; the cap never justifies dropping a fact, so units, ownership,
lifetime, nullability, error conditions and ordering constraints come first.
New source files go into the explicit lists in `build.zig` deliberately.

## Licence

MIT, see [LICENSE](LICENSE), which covers this package's own code. Vendored
ozz-animation is MIT, copyright Guillaume Blanc and contributors; its licence
text ships at `libs/ozz/LICENSE.md` and its authors at `libs/ozz/AUTHORS.md`.
