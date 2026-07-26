# Vendored upstream

`libs/ozz` is a pinned copy of upstream **ozz-animation**, unmodified.

| | |
|---|---|
| Source | <https://github.com/guillaumeblanc/ozz-animation> |
| Version | 0.16.0 |
| Commit | `6cbdc790123aa4731d82e255df187b3a8a808256` |
| Date | 2025-01-19 |
| License | MIT (`libs/ozz/LICENSE.md`) |

## Why upstream and not a fork

The Forge ships its own copy of ozz, patched onto its no-STL house style
(`stb_ds` containers, `tf_malloc`). That fork is not usable here for two
reasons: it is not built into `libThe-Forge.a` — `SamplingJob::Run`,
`Animation::Load` and `Skeleton::Load` are all undefined symbols there, so its
sources would have to be compiled anyway — and its allocator is hard-wired to
Forge's, which would drag a renderer dependency into an animation package.

Clean upstream has the allocator abstraction this package exposes
(`ozz::memory::Allocator`) as a first-class seam, so nothing needs patching.

## What was excluded, and why

Taken: `include/`, `src/`, `LICENSE.md`, `AUTHORS.md`, `CHANGES.md`.

| Excluded | Reason |
|---|---|
| `media/` (90 MB) | Sample assets; unclear per-asset provenance. Tests use synthetic fixtures instead — see below. |
| `samples/`, `howtos/`, `test/` | Upstream's own demos and GTest suite. |
| `extern/` | glfw, gtest, jsoncpp — only needed by the above. |
| `src/animation/offline/fbx` | Requires the proprietary Autodesk FBX SDK. |
| `CMakeLists.txt` (all) | Superseded by `build.zig`. |

`src/animation/offline/gltf` was **kept**: its only dependencies are the
header-only `tiny_gltf.h` and `json.hpp`, vendored inside ozz itself. It is not
compiled today, but it is the foundation of a future glTF → `.ozz` cook and
costs nothing on disk.

Which translation units actually compile is decided explicitly in `build.zig`
(`ozz_runtime_sources`, `ozz_offline_sources`), never by a directory glob.

## Archive versions

ozz archives are versioned per type, and the runtime refuses anything it does
not recognise. At the pinned version:

| Type | Archive version |
|---|---|
| `Skeleton` | 2 |
| `Animation` | 7 |

**This matters in practice.** The Forge's bundled sample clips under
`Art/Animation/*/animations/*.ozz` are **animation version 6** and are rejected
by this package with `BadFormat` ("Unsupported animation version 6"). Their
skeletons still load, because skeleton version 2 is unchanged. Any `.ozz` this
package consumes must therefore be produced by a matching ozz version — which
is the reason the cook, when it lands, has to be pinned to the same vendored
tree rather than to whatever tool produced an asset previously.

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

**Zero-length keyframe arrays trigger undefined behaviour.** With a zero count,
`Animation::Load` reaches `_keys->values` through a null pointer
(`animation.cc:214`). Harmless in practice — the surrounding loop has zero
iterations — but Zig's C sanitizer traps it, which is how it was found. Not
worked around: it is upstream's to fix, it only occurs on malformed input that
zozz already rejects, and suppressing the sanitizer to hide it would cost more
than it saves. The truncated-archive test therefore runs with
`-Dsanitize_c=false`.

## Re-vendoring procedure

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
