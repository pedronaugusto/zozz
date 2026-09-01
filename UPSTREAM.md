# Vendored upstream

`libs/ozz` is a pinned copy of upstream **ozz-animation**, unmodified.

| | |
|---|---|
| Source | <https://github.com/guillaumeblanc/ozz-animation> |
| Version | 0.17.0 |
| Commit | `744eb9d99f606eda849acb0b1204f7a3dc20bca1` |
| Date | 2026-08-01 |
| License | MIT (`libs/ozz/LICENSE.md`) |

## Why upstream and not a fork

Engine-integrated forks of ozz exist, patched onto their host's no-STL house
style (custom containers, custom malloc) with the allocator hard-wired to the
host — usable only inside that host, and dragging its other dependencies into
what should be a standalone animation package.

Clean upstream has the allocator abstraction this package exposes
(`ozz::memory::Allocator`) as a first-class seam, so nothing needs patching.

## What was excluded, and why

Taken: `include/`, `src/`, `LICENSE.md`, `AUTHORS.md`, `CHANGES.md`.

| Excluded | Reason |
|---|---|
| `media/` | Sample assets; unclear per-asset provenance. Tests use synthetic fixtures instead — see below. |
| `samples/`, `howtos/`, `test/` | Upstream's own demos and GTest suite. |
| `extern/` | glfw, gtest, jsoncpp — only needed by the above. |
| `src/animation/offline/fbx` | Requires the proprietary Autodesk FBX SDK. |
| `CMakeLists.txt` (all) | Superseded by `build.zig`. |

`src/animation/offline/gltf` was **kept**, and it is worth recording exactly
what that does and does not buy. `gltf2ozz.cc` reads glTF through
`tiny_gltf.h` and `json.hpp`, both header-only and both vendored inside ozz
itself. But it is written as a subclass of `OzzImporter`
(`include/ozz/animation/offline/tools/import2ozz.h`), and that framework is
configured through **jsoncpp** — `src/animation/offline/tools/import2ozz_skel.cc`
includes `<json/json.h>` — which lives in the excluded `extern/` directory.

So these sources do not build as they stand, and a cook built on them means
vendoring jsoncpp and the tool framework as well, or reimplementing the import
against `tiny_gltf.h` directly. So `gltf2ozz.cc`'s own `main` and the CLI driver behind it do not build here,
and `Importer.run` reports `error.Unsupported` for that reason. What DOES
build is the importer underneath it: `GltfImporter` reads glTF through the
vendored `tiny_gltf.h` and needs no jsoncpp, so `-Dgltf` compiles it as a
`ZozzImporter` (`ffi/zozz_gltf_backend.cpp`) and `Importer.initFromGltf`
imports skeletons, animations and tracks. It is off by default because
tinygltf's implementation is a large translation unit no consumer should pay
for unimported.

Which translation units actually compile is decided explicitly in `build.zig`
(`ozz_runtime_sources`, `ozz_offline_sources`), never by a directory glob.

## Archive versions

ozz archives are versioned per type, and the runtime refuses anything it does
not recognise. At the pinned version, read out of the vendored headers:

<!-- BEGIN GENERATED tools/archive_versions.sh -->
| Type | Archive version | Declared in |
|---|---:|---|
| `animation::Animation` | 7 | `animation/runtime/animation.h` |
| `animation::Float2Track` | 1 | `animation/runtime/track.h` |
| `animation::Float3Track` | 1 | `animation/runtime/track.h` |
| `animation::Float4Track` | 1 | `animation/runtime/track.h` |
| `animation::FloatTrack` | 1 | `animation/runtime/track.h` |
| `animation::QuaternionTrack` | 1 | `animation/runtime/track.h` |
| `animation::Skeleton` | 2 | `animation/runtime/skeleton.h` |
| `animation::offline::RawAnimation` | 3 | `animation/offline/raw_animation.h` |
| `animation::offline::RawFloat2Track` | 1 | `animation/offline/raw_track.h` |
| `animation::offline::RawFloat3Track` | 1 | `animation/offline/raw_track.h` |
| `animation::offline::RawFloat4Track` | 1 | `animation/offline/raw_track.h` |
| `animation::offline::RawFloatTrack` | 1 | `animation/offline/raw_track.h` |
| `animation::offline::RawQuaternionTrack` | 1 | `animation/offline/raw_track.h` |
| `animation::offline::RawSkeleton` | 1 | `animation/offline/raw_skeleton.h` |
<!-- END GENERATED -->

**This matters in practice.** `.ozz` clips produced by older ozz offline
tools circulate widely — **animation version 6** files are common — and are
rejected by this package with `BadFormat` ("Unsupported animation version 6").
Their skeletons still load, because skeleton version 2 is unchanged. Any
`.ozz` this package consumes must therefore be produced by a matching ozz
version: pin the producing toolchain to the same vendored tree rather than
trusting whatever tool produced an asset previously.

Note that this rejection is only clean because `zozz_animation.cpp` validates
after loading. ozz itself logs the version mismatch and leaves the object empty
rather than failing the load; without that check a version-6 clip would present
as a zero-duration animation and sample as garbage.

## Known upstream behaviour worked around here

Recorded so a future re-vendor can check whether any of it has been fixed, and
so the workarounds are not mistaken for arbitrary defensiveness.

**The archive reader does not check its reads.** `IArchive::operator>>` for a
primitive is `Read(&v, sizeof(v))` followed by `assert(size == sizeof(v))`.
Under `NDEBUG` the assert vanishes, so a short read leaves `v` holding stack
garbage and parsing continues — with a count read that way deciding how much
ozz allocates. The tag check is an assert too. Worked around by parsing
everything, files included, through `ConstMemoryStream`, which never returns a
short read and latches a truncation flag instead.

**An unsupported archive version is not an error.** `Animation::Load` logs
`"Unsupported animation version N."` and returns, leaving an empty object; the
caller sees no failure. Worked around by validating after load
(`duration() > 0`, joint counts in range).

**`ozz::New` does not check its allocation.** It is
`new (allocator->Allocate(...)) T(...)`, so a failed allocation is a
placement-new at address zero. Replaced by a checked `zozz::New` in
`ffi/zozz_internal.h`.

**ozz does not survive an allocation failure inside itself.** This one could
not be closed from outside, so it is recorded rather than glossed.
`Skeleton::Allocate` (`src/animation/runtime/skeleton.cc:81`) and
`Animation::Allocate` (`src/animation/runtime/animation.cc:105`) both assign
`allocation_ = allocator->Allocate(...)` and immediately construct spans over
the result with no null check; the spans are then written through. Under memory
pressure a load is a null dereference, not an error.

zozz's own allocations are checked — that is what `zozz::New` above is for — but
these happen inside a call zozz makes, so there is no position from which to
intercept them. The practical reading: load assets where an allocation failure
is not survivable anyway. Sampling, once loaded, allocates nothing.

**Serialising an empty array memcpy's a null source.** The save side of the
same class as the entry below, found by CI's sanitized ubuntu arm (run
`32667186311`): `MemoryStream::Write` (`src/base/io/stream.cc:160`) calls
`std::memcpy(buffer_ + tell_, _buffer, _size)` without a size check, and an
empty `ozz::vector` hands the archive a null data pointer — `memcpy`'s source
is declared nonnull even for size 0, so the sanitizer traps. Unlike the load
side, this fires on WELL-FORMED input: every short animation has an empty
`iframe_entries`, so any save of a small clip reaches it. Handled differently
for that reason: the vendored TUs are compiled with
`-fno-sanitize=nonnull-attribute` (that one check class, vendored code only —
see build.zig; zozz's own ffi keeps the full sanitizer) rather than by
excusing the affected tests from the sanitizer, which would have unsanitized
the whole normal path.

**Zero-length keyframe arrays trigger undefined behaviour.** With a zero count,
`Animation::Load` reaches `_keys->values` through a null pointer
(`animation.cc:214`). Harmless in practice — the surrounding loop has zero
iterations — but Zig's C sanitizer traps it, which is how it was found. Not
worked around: it is upstream's to fix, it only occurs on malformed input that
zozz already rejects, and suppressing the sanitizer to hide it would cost more
than it saves. The truncated-archive test therefore runs with
`-Dsanitize_c=false`.

**`IKAimJob` has no weight-0 early-out, and its result is an ESTIMATE.**
`IKTwoBoneJob::Run` starts with `if (weight <= 0.f)` and assigns
`SimdQuaternion::identity()` (`src/animation/runtime/ik_two_bone_job.cc`).
`IKAimJob::Run` has no such branch: at any `weight < 1` it returns
`NormalizeEst4(Lerp(identity, q, weight))`
(`src/animation/runtime/ik_aim_job.cc`). `NormalizeEst4` is `_mm_rsqrt_ps` on
the SSE backend, a 12-bit estimate — `rsqrt(1.0)` is `0.999755859375`, so the
"identity" a weight-0 aim returns is identity to ozz's own
`kNormalizationToleranceEstSq` (`2e-3`) and no tighter. Not worked around:
this is the precision ozz documents for its `Est` family, and forcing an exact
normalisation would be a local patch to upstream behaviour. Recorded because
it looks exactly like a binding defect from the outside, and because it is
BACKEND-DEPENDENT.

**The reference backend's estimates and shifts are undefined behaviour by the
letter of C++.** Two sites, both in
`include/ozz/base/maths/internal/simd_math_ref-inl.h`, both deliberate and both
invisible on x86-64 because the SSE backend lowers the same calls to
instructions with no such rule. `OZZ_RCP_EST` (line `57`) seeds a
Newton-Raphson reciprocal with `(0x3f800000 * 2) - uf.i` over the input float's
bit pattern; a negative input leaves `uf.i` negative and the subtraction passes
`INT_MAX`. `ShiftL` (line `1491`) left-shifts each `int` lane, and a lane
holding a comparison mask is negative. The bit manipulation IS the routine in
both, so there is nothing to fix at the site, and the tree stays pristine.
Handled the way the entry above is: the vendored TUs, and `tests/mathref.cpp`
which is a dispatcher into ozz's inline maths and adds no arithmetic of its
own, are compiled with `-fno-sanitize=signed-integer-overflow` and
`-fno-sanitize=shift-base` -- those two check classes, ozz's arithmetic only.
zozz's own ffi and `tests/fixture.cpp` keep the full sanitizer. `RcpEst` and
`RSqrtEst` are called from `blending_job.cc`, `sampling_job.cc` and both IK
jobs, so this is the runtime and not only the test harness. Reproducible on any
host with `-Dsimd_ref=true`.

**ozz ships two SIMD backends: `ref` (scalar) and `sse`. There is no NEON
one.** `include/ozz/base/maths/internal/` contains `simd_math_ref-inl.h` and
`simd_math_sse-inl.h` only. An x86-64 build runs the SSE kernels; an
Apple-Silicon or other non-x86 build runs the SCALAR reference kernels, where
`NormalizeEst4` is an exact `1/sqrt` and the weight-0 aim above returns exactly
1.0. A number measured on one architecture is not a number measured on the
other — for precision or for speed.

## Re-vendoring procedure

`ci/verify-vendor.sh` fetches the pinned commit and diffs it against
`libs/`, so the claim that this copy is unmodified is checked rather than
asserted. It runs as its own CI job. Run it after any step below.

1. Clone upstream at the new tag; copy `include/` and `src/` over `libs/ozz/`,
   re-applying the exclusions above.
2. Update the table at the top of this file and `zozzOzzVersion()` in
   `ffi/zozz_core.cpp`.
3. Re-check the archive versions above against the `OZZ_IO_TYPE_VERSION` lines
   in `animation.h` and `skeleton.h`.
4. `zig build test`. The `static_assert`s in `ffi/zozz_abi.cpp` fail the build
   if a type zozz casts to or from has changed shape; the ABI test fails if the
   Zig externs have drifted.
5. Add any new source files to `build.zig` deliberately — the explicit lists
   exist so a re-vendor cannot silently change what gets compiled.
