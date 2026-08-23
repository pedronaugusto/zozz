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
32667186311): `MemoryStream::Write` (`src/base/io/stream.cc:160`) calls
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
