# zozz design

How the package is built, what each layer holds, what upstream does that the
boundary stands in front of, and how each claim the README makes is checked.

## Layers

ozz is C++, and C++ does not cross a linking boundary intact, so the package
is three layers and a new capability lands in each.

1. **`libs/ozz` is upstream with its listed patches, and nothing else.**
   `zig build check-vendor` applies `libs/patches` to the pinned commit and
   compares the result with `libs/ozz` both ways, failing on any other edit,
   a file upstream does not have, or a patch that no longer applies. A patch
   closes one class of defect at its cause, where no outer layer can reach
   it ([Patches](#patches)); behaviour upstream lacks belongs in the next layer.
2. **`ffi/` is the C boundary.** One translation unit per concern
   (`zozz_sampling.cpp`, `zozz_archive.cpp`, …), each entry point `ZOZZ_API`
   and `zozz`-prefixed, declared in one header per concern that `ffi/zozz.h`
   gathers. A mirrored layout gets a `static_assert` in `ffi/zozz_abi.cpp`
   against upstream's type, so a re-vendor that moves anything fails the
   build. Validation lives here too: what upstream would trust is checked
   before upstream sees it, and each case is recorded under
   [Known upstream behaviour](#known-upstream-behaviour).
3. **`src/` is the Zig layer.** `src/c.zig` holds every `extern`, written by
   hand; the wrappers, one module per concern, call through it. The shipped
   module translates no header; the test module does, and
   [the ABI guard](#the-abi-guard) holds the externs to it.

`ci/layers.zig` holds the order of the Zig modules: the C boundary and the
maths, errors, the runtime objects and jobs, sampling and raw tracks, memory,
offline, the optimizer and importer, the archive, and the root. A module
imports only from the layers below it.

## Binding conventions

How a new area gets bound, so every one comes out the same shape.

### Start with recon

```sh
zig build recon -- BlendingJob
```

What decides whether a binding of a C++ class is correct is not in its
signatures: it is an `assert()` in a method body, a `Validate()` that rejects
what the signature suggests is fine, a span the job expects the caller to
keep alive, a private constructor. `zig build recon` prints those lines with
their file and line: a page instead of a file. It is a lead generator, not
an oracle.

### One entry point, all the way through

`ffi/zozz_sampling.h`
```c
ZOZZ_API ZozzResult zozzSamplingContextCreate(int max_tracks,
                                              ZozzSamplingContext** out);
```

`ffi/zozz_sampling.cpp`
```cpp
ZozzResult zozzSamplingContextCreate(int max_tracks,
                                     ZozzSamplingContext** out) {
  if (out == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  *out = nullptr;                       // clear the out BEFORE any failure
  if (max_tracks <= 0 || max_tracks > zozz::kMaxJoints) {
    return ZOZZ_RESULT_INVALID_ARGUMENT;
  }
  // ... allocate through ozz::memory::default_allocator(), which is the
  // host allocator once zozzSetAllocator has run.
}
```

`src/c.zig`
```zig
pub extern fn zozzSamplingContextCreate(max_tracks: c_int, out: **SamplingContext) Result;
```

`src/sampling.zig`
```zig
pub fn init(max_tracks: u32, failure: *err.Failure) err.Error!SamplingContext {
    const tracks = try err.narrow(failure, .sampling_context_create, c_int, max_tracks);
    var handle: *c.SamplingContext = undefined;
    try err.check(failure, .sampling_context_create, c.zozzSamplingContextCreate(tracks, &handle));
    return .{ .handle = handle };
}
```

Then one re-export line in `src/zozz.zig`, and in `build.zig` the `.h` in the
public header list, the `.cpp` in the FFI source list and any new ozz `.cc`
in `ozz_runtime_sources` or `ozz_offline_sources`.

A handle is for state ozz itself owns and hides. **Plain data does not get
one**: a pose, a weight mask and a blending layer are caller-owned spans of
POD, laid out exactly as ozz lays them out, so a job takes them with no copy
and no allocation (`ffi/zozz_pose.h`, and the `static_assert`s in
`ffi/zozz_abi.cpp` that hold the layouts).

A handle wrapper holds `handle: ?*c.Thing`, and its `deinit` takes `*Self`,
nulls the handle and is therefore idempotent. Every use reads it through
`err.live`, so a destroyed handle used again through the same variable stops
in every build, ReleaseFast included, through `aegis.assert.never`. Zig cannot delete a copy constructor, so a copy taken before
`deinit` still holds the old pointer and dangles exactly as a raw pointer
would. ozz deletes the copy constructor; this binding cannot.

### Naming is load-bearing

`src/abi_test.zig` pairs the two sides by name with no hand-maintained list,
so a name that breaks convention is a build failure:

| Zig side | C side |
|---|---|
| type `Foo` | `ZozzFoo` |
| function `zozzFoo` | `zozzFoo` |
| constant `foo_bar` | `ZOZZ_FOO_BAR` |
| enum `Foo`'s field `bar` | `ZOZZ_FOO_BAR` |

Enumerators take the full type name: `ZOZZ_RESULT_ERR_IO`, never
`ZOZZ_ERR_IO`. translate-c flattens a C enum to a plain integer alias, so the
strict prefix is the only thing that pairs an enumerator back to its enum.

**No enumerator may be negative.** C leaves an enum's underlying type to the
implementation, and the implementations disagree: clang and gcc pick
unsigned when no enumerator is negative, MSVC uses `int`. Every value being
non-negative is what makes that unobservable, and the guard enforces it. A
negative sentinel is a fixed-width constant, as `ZOZZ_NO_PARENT` is, declared
in `src/c.zig`, the file the guard walks.

### The C ABI

- **Every fallible entry point returns `ZozzResult`** and delivers its answer
  through an out-parameter. Infallible ones return the value directly.
- **Every out-parameter is cleared before the first failure return**, so a
  refused call leaves the caller's outputs defined.
- **A null pointer is refused** with `ZOZZ_RESULT_INVALID_ARGUMENT`.
- **A job's `Validate()` returning false is an error path**, mapped to
  `ZOZZ_RESULT_JOB_INVALID`; ozz jobs run whatever they are given when it is
  skipped. `ZOZZ_RESULT_INVALID_ARGUMENT` is for what this layer refuses: a
  null handle, a negative count, a NaN. The two apart tell a caller "the
  arguments are nonsense" from "ozz would not accept this job".
- **The declared surface never depends on build options.** A header whose
  contents move with a `-D` flag cannot be checked.
- **Allocation goes through `ozz::memory::default_allocator()`**, never
  `new` or `malloc`. That allocator is the host's once `zozzSetAllocator` has
  run, and the suite fails on an unbalanced seam.
- **Spans do not own.** ozz jobs take `ozz::span` into memory the caller
  owns; the C boundary takes a pointer and a count and documents who keeps it
  alive across the call.
- **Nothing unwinds out of a callback**, and a Zig callback never returns a
  Zig error across the C boundary: it stashes the error in the user context,
  and the wrapper raises it after the call returns.

### The Zig wrapper

- A call that can fail takes the caller's `*Failure` last. `ZozzResult`
  becomes `Error!T` through `err.check(failure, .call, c.zozzCall(...))`,
  which pushes one `Frame` naming the entry point and its result; a refusal
  the wrapper makes before calling C goes through `err.refuse` or
  `err.narrow` and names the call it was about to make. A call that only
  passes a refusal on pushes nothing, so one refusal is one frame. A loader
  goes through `err.checkLoad` instead, which carries the loader's
  `c.Refusal` into its frame and stops in every build if one arrives beside a
  result other than `bad_format` or `io`. Tests in
  `src/error.zig` read the modules and fail when a frame names another call,
  when an error leaves any other way, or when a module makes a `Failure` of
  its own. `err.map`, which pushes none, is only for a result
  `aegis.assert.never` rules out (`getAllocator`, `setLogLevel`).
- A caller's integer going to a narrower C parameter is `err.narrow`, a
  refusal, never `@intCast`; a count the boundary reports comes back through
  `err.reported`, which stops in every build if it does not fit.
- Bytes a loader parses arrive as `Bytes` (`aegis.input.Untrusted`), and an
  archive's input stream as `InputStream`; they leave that type only at the
  call that hands them to the boundary's checked reader.
- A count-then-fill pair becomes a slice, with the allocator taken
  explicitly.
- A lifetime the C side did not promise is never widened.
- A doc comment says what ozz does, not what would be tidy.

## Allocators

`setAllocator` routes every ozz allocation through a `std.mem.Allocator`. It
is process-wide, because ozz's allocator is a single global
(`ozz::memory::default_allocator()`, `include/ozz/base/memory/allocator.h`)
and no ozz entry point takes an allocator parameter: a per-object allocator
here would be a parameter zozz could not honour.

### The block header

ozz frees with `deallocate(block)`: no size, no alignment. A
`std.mem.Allocator` needs both at free, so `src/memory.zig` stores a header
ahead of every block holding its length, its alignment and the allocator it
came from. The recorded allocator makes swapping one Zig allocator for
another safe with blocks outstanding: each block frees through its producer,
not through whichever is installed when it is destroyed.

### Why zozz takes ozz's slot at start-up

Below the Zig layer the C seam holds one `ZozzAllocator`, so it cannot route
a free back to its producer. `zozzSetAllocator` therefore refuses any call
that would change where a free lands, with `ZOZZ_RESULT_ALLOCATOR_IN_USE`,
while `zozzAllocatorLiveBlocks()` is non-zero.

That refusal holds only if the count sees every outstanding block, the ones
ozz's own allocator handed out before a host was installed included. ozz
frees through whichever allocator is installed at destruction, so a skeleton
loaded before `setAllocator` and destroyed after it would hand `malloc`'d
memory to the Zig bridge. zozz occupies ozz's allocator slot from the start
of the process and forwards to ozz's own allocator until a host arrives; the
count is then total, and the refusal holds in both directions (CHANGELOG
0.5.0 has the failure this fixed). A call that leaves the same allocator in
place changes no destination: reinstalling the identical allocator, or
resetting while none is installed, succeeds with blocks live. The count
doubles as a leak check for a host whose allocator has none.

### Threads

Every entry point that allocates arrives at this one seam, so distinct
handles may be used concurrently while the installed allocator is
thread-safe. A single handle is not internally synchronised, and neither is
installing or resetting the allocator: that happens on one thread before any
other is inside zozz. `src/concurrency_test.zig` runs four threads, each with
its own sampling context, poses and matrices, sharing one skeleton and one
clip, creating and destroying handles for two hundred frames each against a
`DebugAllocator` that accounts for every block.

A C host keeps ozz's shape and passes `malloc` and `free` in two lines.

## Validation at the boundary

### What ozz does not check

`IArchive::operator>>` for a primitive is `Read(&v, sizeof(v))` followed by
`assert(size == sizeof(v))`. Under `NDEBUG` the assert is gone, so a short
read leaves `v` holding stack garbage and parsing continues, and a count read
that way decides how much ozz allocates and copies. The tag check is an
assert too. An unsupported archive version is logged and leaves an empty
object, with no error returned.

### What the loaders add

- **A tag test before parsing.** Wrong-type or non-ozz input is `BadFormat`,
  not a parse of unrelated bytes.
- **Truncation detection.** Every archive, files included, is parsed through
  `ConstMemoryStream`, which satisfies each read in full, zero-fills past the
  end and latches a flag the loader checks. Zeros are the safe filler: a
  zeroed count is zero, so ozz's loops do nothing, and no partly overwritten
  count can round upward. Files are buffered whole rather than handed to
  ozz's own `File` stream, because that stream returns the short reads ozz
  fails to check.
- **A sanity check after parsing.** Joint counts within ozz's limit, arrays
  of consistent length, a positive duration. This turns a version-mismatched
  clip into `BadFormat` instead of a zero-duration animation that samples to
  garbage.
- **Checked allocation.** `ffi/` allocates its handles through a checked
  `zozz::New` (`ffi/zozz_internal.h`), and a load or build that ozz could
  not allocate for, which it now reports ([Patches](#patches)), returns
  `ZOZZ_RESULT_OUT_OF_MEMORY`. A `zozzIArchive` that ran out of memory stays
  so, its stream left inside the object.

**The refusal record.** Every loader (`*LoadMemory`, `*LoadFile`,
`zozzIArchiveLoad<Type>`) takes a `ZozzRefusal*` last, NULL allowed, and
clears it on entry. It is filled with the name of the version, count or
invariant that failed (`Skeleton.num_joints`), what the archive held and the
bound it broke, from two places. For an invariant the pair says where: the
joint, key or iframe that broke it and how many there are, a parent and the
joint it belongs to, or the iframes held and those the interval seeks to. ozz's own `Load` refuses through
`IArchive`'s record ([Patches](#patches)), which `zozz::LoadTagged` and
`LoadTaggedObject` carry out through `zozz::RefusedBy`; a post-parse check
refuses through `zozz::Refuse` (`ffi/zozz_internal.h`). Either returns
`ZOZZ_RESULT_BAD_FORMAT`, or `ZOZZ_RESULT_IO` when a count runs past the bytes
the archive has left, since an archive that ends before what it claims cannot
be told from a truncated one; `limit` is then what fits. No other result
carries one. A stream that ran short before the refusal makes it IO with no
record, the zeros it fed the parse being the cause. `what` is a static string,
never freed. A wrong tag, a missing file or a duration that is not positive
leave the record empty. The Zig wrapper copies the record into the refusal's
frame (`Frame.refusal`), so `error.BadFormat` says which count broke and by
how much. The host-stream bridge measures its stream's length by seeking to
the end and back, as `ozz::io::File::Size` does, since every count is checked
against the bytes left; and a `zozzIArchive` that refused stays refused, its
stream left inside the refused object.

NaN ratios are refused, and every entry point taking SoA memory or a matrix
buffer checks the 16-byte boundary and returns
`ZOZZ_RESULT_INVALID_ARGUMENT`, rather than letting ozz fault on an aligned
SIMD load.

### What it does not cover

A standard container inside ozz cannot report a refused allocation: `resize`
and `push_back` have no failure path, and the build has no exceptions. ozz's
`StdAllocator` stops the process there instead (`std::abort`) rather than
handing the container a null block ([Patches](#patches)). Every count an
archive gives a container is checked against the bytes left before it is
resized, so a crafted archive is refused by count and only real exhaustion
reaches the abort; the raw loaders, offline builders and optimizers, which
build containers, are where it can. Every other allocation ozz makes is
checked and comes back as `OutOfMemory`. Sampling, once loaded, allocates
nothing.

ozz's parser is not hardened against arbitrary hostile input, and zozz cannot
make it so from outside. What holds is that truncation and type confusion
fail cleanly and deterministically, that every version and count is
checked against ozz's limits and the bytes left before anything is sized from
it, and that what a job walks (names, parents, ratios, the key chains and
iframes) is checked before a loaded object reaches one ([Patches](#patches)). To load `.ozz` from an untrusted source, put a
length-and-checksum container around it and validate that first.

Every prefix of a valid archive, across both fixtures, is tested to be
refused, and the whole archives still load.

## The ABI guard

`src/c.zig` hand-writes the `extern` declarations for `ffi/zozz.h` rather
than running translate-c, so the wrapper gets the types it wants and the
shipped module never compiles C. Neither compiler checks that those
declarations still agree with the header: a `size_t` narrowed to an `int`
links cleanly and corrupts. Three checks close that, on three axes.

- **`src/abi_test.zig`: the header against the declarations.** The real
  header, translated by the build's translate-c step, compared against
  `src/c.zig` by reflection: every struct field paired by name with its
  offset, every scalar's size, alignment, signedness and int-versus-float,
  every function's arity and variadic-ness, every enumerator's value, every
  constant. Declarations are discovered by reflection, and one the check
  cannot classify is a compile error. It sweeps the other direction too, so a
  symbol the header exports that `c.zig` never declares, or declares as
  something other than an extern, fails as well. The `@cImport` happens in a
  test only.
- **`zozzAbiLayout()`: the compiled library against the declarations.** The
  header is a source file and the library a binary; they can describe
  different structs while looking identical. This entry point asks the
  linked translation unit what it laid out.
- **`static_assert`s in `ffi/zozz_abi.cpp`: ozz against the C++.** They fail
  the build if a vendored ozz upgrade changes a type this package casts to or
  from: the SoA pose, the blending layer, the transform and matrix types.

`src/abi_test.zig` guards the other two and cannot test itself: a refactor
that quietly makes it vacuous looks exactly like a passing build. `bay probe`
applies the drifts in `ci/probes/` one at a time and requires each to be
refused, a field swap that leaves every offset in the struct unchanged among
them, which defeats any positional or offsets-only comparison.

It compares `src/c.zig` against the header as preprocessed for a target, so
firing on the Itanium ABI proves nothing about MSVC's, where a C enum is
`int` rather than `unsigned int`, a difference `ZozzResult` and
`ZozzTrackInterpolation` cross in signatures and in struct fields. A drift is
a compile error, so the check fires wherever the tests compile, and the gate
compiles them for `x86_64-windows-msvc` as well as the Itanium targets. The
probes run outside the gate, because each rebuilds the suite, and on the
host's ABI only.

## Build hygiene

- **Source lists are explicit, never globs.** `ozz_runtime_sources`,
  `ozz_offline_sources` and the FFI source list name every file, so a
  re-vendor cannot silently change what compiles.
- **No `-fno-access-control`.** The FFI layer uses only ozz's public API.
- **The C sanitizer is opt-in.** `-Dsanitize_c=true` turns it on, and the
  gate runs a suite arm and the C smoke test that way. It stays off by
  default because Zig's C sanitizer emits calls into a runtime linked only
  into a compilation that is itself sanitized: a consumer who forgets to
  forward `optimize` would get an `undefined symbol: __ubsan_handle_*` link
  failure naming nothing they can act on.
- **Three sanitizer check classes are off for ozz's arithmetic only**: the
  vendored translation units and `tests/mathref.cpp`, which dispatches into
  ozz's inline maths and adds none of its own. `nonnull-attribute`,
  `signed-integer-overflow` and `shift-base`, each answering one upstream
  site under [Known upstream behaviour](#known-upstream-behaviour). zozz's own
  `ffi/` and `tests/fixture.cpp` keep the full sanitizer.
- **`-Denable_asserts` holds in every mode.** Zig 0.17 defines `NDEBUG` for C
  by itself in ReleaseFast and ReleaseSmall, so the flag passes `-UNDEBUG`
  after the toolchain's own flags.
- **Build options are declared once and mirrored into a Zig `options`
  module**, so the wrapper cannot disagree with how the C++ was compiled; a
  test holds the mirror to what the linked library reports
  (`zozz.buildFeatures()`).
- **One translation unit per concern**, on both sides of the boundary.
- **The version has one home.** `build.zig` fails to compile if
  `build.zig.zon` and `ffi/zozz_core.h` disagree, and a test holds
  `zozzVersion()` to the same number.

## The vendored upstream

`libs/ozz` is a pinned copy of upstream ozz-animation with the patches below
applied, and nothing else.

| | |
|---|---|
| Source | <https://github.com/guillaumeblanc/ozz-animation> |
| Version | 0.17.0 |
| Commit | `744eb9d99f606eda849acb0b1204f7a3dc20bca1` |
| Date | 2026-08-01 |
| License | MIT (`libs/ozz/LICENSE.md`) |

Upstream rather than a fork: engine-integrated forks of ozz exist, patched
onto their host's containers and allocator and usable only inside that host.
Clean upstream has the allocator abstraction this package exposes
(`ozz::memory::Allocator`) as a first-class seam, so nothing is patched for
integration; a patch is only ever a defect fix.

### Patches

Vendored at upstream head, 0.17.0; nothing upstream fixes these as of
2026-10-31. Each patch in `libs/patches` closes one class of defect at its
cause, opens with what it changes and the evidence for it, keeps upstream's
style and failure paths, and is written to be offered upstream as it stands.
`ci/vendor.zig` lists them in the order they apply, and `check-vendor` fails
when one stops applying or this list does not name it. A re-vendor that
finds one fixed upstream drops it.

| Patch | Defect it closes |
|---|---|
| `ozz-archive-counts.patch` | Every `Load` sized allocations from counts read off the archive unchecked, and an unsupported version loaded as an empty object. `IArchive` gains a refusal record, the bytes left and a count check; every version and count is checked against ozz's own limits and the bytes left before anything is allocated, and `RawSkeleton` nesting is bounded. |
| `ozz-checked-allocation.patch` | Every allocation ozz made was written through unchecked: `Skeleton`, `Animation` and `Track` `Allocate`, `ozz::New`, a suppressed log line's stream, `MemoryStream::Resize`. Each now reports the failure (a load leaves its object empty and marks the archive out of memory, a builder returns null). `StdAllocator`, behind every standard container, aborts instead, since a container has no failure path. |
| `ozz-archive-invariants.patch` | `Load` trusted what an archive held once its counts fit, and the jobs read past a buffer on what ozz's builders never produce: a name with no terminator, a parent that is not an earlier joint, a track's first ratio past 0, animation keys naming no timepoint, previous-key chains that break, iframes holding other keys or an interval seeking past the last. Each `Load` refuses those through the record, and a refused `Load` leaves its object empty: `Deallocate` clears every span over the block it frees. |
| `ozz-gv4-padding.patch` | `DecodeGV4` loads four bytes per value, up to three past an iframe's entries, and `Animation::Allocate` relied on the name after them to cover that: an unnamed clip seeking its last iframe read past its block. Three bytes now follow everything a block with iframe entries holds. |
| `ozz-arrays-of-none.patch` | An `Extern` that saves or loads an array of structs takes the address of its first element's members, and an array of none is often an empty span, whose data is null: a member access through null for an animation of no tracks, which ozz's builder makes from a raw one, or a track of no keys of any value type but float. `internal::Array`, through which every array reaches its `Extern`, calls none for an array of none. |
| `ozz-raw-track-interpolation.patch` | A raw track keyframe's interpolation is one byte in the archive, and `Load` cast any byte to `RawTrackInterpolation::Value`, which holds only `kStep` and `kLinear`: undefined to read back, and `TrackBuilder` reads it. A mode past `kLinear` is refused through the record. |
| `ozz-rest-pose-rotations.patch` | `LocalToModelJob` asserts every lane of a pose it converts holds a unit rotation, padding lanes included, and `Skeleton::Load` took whatever rest pose an archive held: an archive aborted the host at the job. A rest pose block whose rotations are not unit by the job's own estimate is refused through the record. |

### What was taken, and what was left behind

Taken: `include/`, `src/`, `LICENSE.md`, `AUTHORS.md`, `CHANGES.md`.

| Excluded | Reason |
|---|---|
| `media/` | Sample assets of unclear per-asset provenance; the tests build their own fixtures. |
| `samples/`, `howtos/`, `test/` | Upstream's demos and GTest suite. |
| `extern/` | glfw, gtest and jsoncpp, needed only by the above. |
| `src/animation/offline/fbx` | Needs the proprietary Autodesk FBX SDK. |
| `CMakeLists.txt` (all) | Superseded by `build.zig`. |

`src/animation/offline/gltf` was kept. `gltf2ozz.cc` reads glTF through
`tiny_gltf.h` and `json.hpp`, both header-only and vendored inside ozz, but it
is a subclass of `OzzImporter` (`include/ozz/animation/offline/tools/import2ozz.h`),
and that framework is configured through jsoncpp
(`src/animation/offline/tools/import2ozz_skel.cc` includes `<json/json.h>`),
which is in the excluded `extern/`. So `gltf2ozz.cc`'s `main` and the command
line driver behind it do not build here, and `Importer.run` reports
`error.Unsupported`. The importer underneath does build: `GltfImporter` needs
no jsoncpp, so `-Dgltf` compiles it as a `ZozzImporter`
(`ffi/zozz_gltf_backend.cpp`) and `Importer.initFromGltf` imports skeletons,
animations and tracks. It is off by default because tinygltf's
implementation is a large translation unit no consumer should pay for
unimported.

### Archive versions

ozz versions its archives per type and refuses what it does not recognise;
the README's table is generated from the vendored tree. Upstream logs a
version mismatch and leaves the object empty rather than failing the load,
so a version-6 clip presents as a zero-duration animation and a skeleton as
an empty one. `ozz-archive-counts.patch` refuses it through the record
instead, naming the version found and the one expected.

### Known upstream behaviour

Recorded so a re-vendor can check whether any of it has been fixed, and so
each check here is not mistaken for arbitrary defensiveness.

| Upstream | What zozz does |
|---|---|
| `IArchive::operator>>` reads a primitive and only asserts the size (`include/ozz/base/io/archive.h`); under `NDEBUG` a short read leaves stack garbage. The tag check is an assert too. | Every archive, files included, is parsed through `ConstMemoryStream`, which never reads short and latches a truncation flag; a tag test runs first. |
| Every `Load` sizes allocations from counts it reads, and an unsupported version logs and returns an empty object; the caller sees no failure. | Patched at the cause: `ozz-archive-counts.patch`. `ffi/` still validates after load: `duration() > 0`, joint counts in range. |
| `ozz::New` is `new (allocator->Allocate(...)) T(...)`: a failed allocation is a placement-new at address zero. | Patched at the cause for ozz's own callers (`ozz-checked-allocation.patch`); `ffi/` allocates through its own checked `zozz::New` (`ffi/zozz_internal.h`). |
| `MemoryStream::Write` (`src/base/io/stream.cc:160`) calls `memcpy` without a size check, and an empty `ozz::vector` hands it a null source, which `memcpy` declares nonnull even for size 0. Every short clip's empty `iframe_entries` reaches it on save; found by a sanitized CI arm (run `32667186311`). | The vendored units compile with `-fno-sanitize=nonnull-attribute`, rather than excusing the affected tests from the sanitizer, which would unsanitize the normal path. |
| With a zero keyframe count, `Animation::Load` forms `_keys->values` through a null pointer (`src/animation/runtime/animation.cc:214`); the loop around it runs zero times. | Not worked around: only malformed input reaches it, and zozz refuses that input. The truncated-archive test skips under `-Dsanitize_c=true`. |
| `IKTwoBoneJob::Run` returns identity at `weight <= 0`; `IKAimJob::Run` has no such branch and returns `NormalizeEst4(Lerp(identity, q, weight))` (`src/animation/runtime/ik_aim_job.cc`). On the SSE backend `NormalizeEst4` is `_mm_rsqrt_ps`, an estimate: `rsqrt(1.0)` is `0.999755859375`, identity only to `kNormalizationToleranceEstSq` (`2e-3`). | Not worked around: it is the precision ozz documents for its `Est` family. Recorded because it looks like a binding defect from outside, and it depends on the backend. |
| The reference backend's `OZZ_RCP_EST` (`include/ozz/base/maths/internal/simd_math_ref-inl.h:57`) seeds a reciprocal with `(0x3f800000 * 2) - uf.i` over the input's bit pattern; a negative input passes `INT_MAX`. `ShiftL` (`:1493`) left-shifts each `int` lane, and a comparison mask is negative. Both are the routine itself, and the SSE backend lowers the same calls to instructions with no such rule. `RcpEst` and `RSqrtEst` are called from the blending, sampling and both IK jobs. | The vendored units and `tests/mathref.cpp` compile with `-fno-sanitize=signed-integer-overflow` and `-fno-sanitize=shift-base`. Reproducible on any host with `-Dsimd_ref=true`. |
| ozz ships two SIMD backends, `ref` (scalar) and `sse`, and no NEON one (`include/ozz/base/maths/internal/`). A non-x86 build runs the scalar kernels, where `NormalizeEst4` is an exact `1/sqrt` and the weight-0 aim above returns exactly 1.0. | `-Dsimd_ref` compiles the scalar backend on any host, and the gate runs a suite arm with it. A number measured on one architecture is not a number for the other, for precision or speed. |

### Re-vendoring

`zig build check-vendor` fetches the pinned commit, applies `libs/patches`
and diffs the result against `libs/`, and runs in the gate. Run it after each
step.

1. Clone upstream at the new tag; copy `include/` and `src/` over
   `libs/ozz/`, applying the exclusions above, then each patch in order
   (`git apply`). A patch that no longer applies is rebased onto the new
   tree, or dropped if upstream now fixes its defect.
2. Update the table at the top of this section, the `ozz` pin in
   `build.zig.zon` and `zozzOzzVersion()` in `ffi/zozz_core.cpp`.
3. `bay test`. The docs check fails until the README's archive-version
   table is regenerated (`zig build archive-versions`); the
   `static_assert`s in `ffi/zozz_abi.cpp` fail if a type zozz casts to or
   from has changed shape; the ABI test fails if the Zig externs have
   drifted; `zig build check-coverage` fails on a public name without a
   verdict.
4. Re-read [Known upstream behaviour](#known-upstream-behaviour) against the
   new tree, site by site.
5. Add any new source files to `build.zig` deliberately.

## Testing

`bay test` runs the gate: formatting, structure, lint and documentation, the
checks in `ci/`, a consumer build, and the suite in seven arms: against the
C++ under Zig's undefined-behaviour sanitizer, as a consumer builds it, with
the asserts flipped from the mode's default, with `-Doptions`, `-Dgltf` and
both, and on ozz's scalar SIMD backend under the sanitizer. The C smoke test
(`tests/c_smoke.c`) runs plain and sanitized against the installed headers,
with a host allocator that knows nothing about Zig, and the shared library and
the asserts-flipped sanitized library are built.

Assets are built at test time through ozz's own offline builders and
serialised in memory (`tests/fixture.cpp`), so the suite is version-matched to
the vendored runtime and ships no third-party clips. `-Dskeleton_path=` and
`-Danimation_path=` add a real asset on disk, held to unit-length
quaternions, finite transforms, parent-precedes-child joint ordering, root
joints whose model matrix matches their local translation, a clip that
moves, and a refused NaN ratio.

`bay probe` breaks each invariant in `ci/probes/` on purpose and requires
the failure it names; it runs outside the gate, a rebuild per probe.

## Contributing

These are the rules that fail a build.

- **`libs/ozz` is edited only by a patch in `libs/patches`.** `zig build
  check-vendor` applies them to the pinned commit and compares. Work around
  upstream in `ffi/` where that reaches the defect, and record the reason
  under [Known upstream behaviour](#known-upstream-behaviour); patch it, one
  patch per class of defect, only where nothing outside can.
- **`bay test` is green before a push**, in every optimize mode a change can
  reach.
- **A new public ozz name gets a verdict in `ci/coverage/`**: bound across
  the C ABI, delivered as a C callback, provided in Zig, provided by the Zig
  language, or internal to ozz. `zig build check-coverage` enumerates the
  names from ozz's headers and fails on one without a verdict.
- **A new C entry point gets checks in `tests/c_smoke.c`**, and follows
  [Binding conventions](#binding-conventions).
- **A new invariant gets a probe in `ci/probes/`** naming the failure it must
  produce; `bay probe` reports a probe the suite survives.
- **A number a document states comes from a generator**
  (`ci/measurements.zig`, `ci/archive_versions.zig`), and the docs check fails
  while a committed block is stale; `zig build check-numbers` refuses one
  written by hand.
- **Comments state a contract**: `zig build check-comments` caps every
  comment block at the lengths `ci/comments.zig` declares, a public C
  header's doc blocks longest, since they are the contract a C caller reads.
  The cap never justifies dropping a fact: units, ownership, lifetime,
  nullability, error conditions and ordering come first.
