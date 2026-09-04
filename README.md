# zozz

[![CI](https://github.com/pedronaugusto/zozz/actions/workflows/ci.yml/badge.svg)](https://github.com/pedronaugusto/zozz/actions/workflows/ci.yml)

Zig bindings for the [ozz-animation](https://github.com/guillaumeblanc/ozz-animation)
runtime — skeletal animation sampling.

- Vendored, pinned upstream ozz (0.17.0). No fork, no patches. See [UPSTREAM.md](UPSTREAM.md).
- A C ABI (`ffi/zozz.h`) that exists because it must — ozz is C++ and Zig
  cannot call that — kept clean and tested as a real contract (the C smoke
  test consumes it with no Zig in the picture). The Zig wrapper is its one
  production consumer today.
- Host allocator injection: every ozz allocation can go through your
  `std.mem.Allocator`.
- Drift between the C header and the Zig externs is a **build failure**, not a
  memory-corruption bug: every type, signature, enumerator and constant is
  cross-checked at comptime, with no hand-kept list of what to check.

What works today: load, sample, convert, local-to-model, blend, apply IK, skin
a mesh, import glTF, and offline building — author a skeleton or clip in
memory, optimise or extract motion from it, and build it into the same runtime
objects the loaders produce. See [Scope](#scope) for what that covers and what
is not exposed, and [By the numbers](#by-the-numbers) for the version.

Every release so far has been a breaking change and there is no compatibility
layer: each job is a struct with a `run` method, mirroring ozz's own shape.
There is exactly one way to spell everything.

## Usage

The block below is not written here: it is a region of [`examples/usage.zig`](examples/usage.zig), which `zig build examples` builds and RUNS, extracted by `ci/readme_usage.sh` and compared by CI. A snippet in a README is a claim about how the library is used, and this one is a claim something executes.

<!-- BEGIN GENERATED ci/readme_usage.sh -->
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

Add it as a dependency and link the module:

```zig
const zozz_dep = b.dependency("zozz", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("zozz", zozz_dep.module("zozz"));
```

A C or C++ host takes the library and its installed header instead:

```zig
exe.root_module.linkLibrary(zozz_dep.artifact("zozz"));  // then #include <zozz.h>
```

Forward `optimize` as shown. zozz does not turn on Zig's C sanitizer for you
(see [Build hygiene](#build-hygiene)), so a mismatched build mode is a size
difference rather than an unresolved `__ubsan_handle_*` symbol — but a Debug
library inside a release executable is still not what you meant.

## Design

### The caller owns the SoA pose

ozz's job pipeline speaks structure-of-arrays: sampling writes it, blending
consumes and produces it, local-to-model reads it. A pose is a
`[]SoaTransform` — one element per four joints, `soaBlocks(n)` of them — and
every entry point takes that slice, which is exactly the `ozz::span` the C++
jobs take. Conversion to `Transform` (array-of-structs) happens only at the
edges, where you actually want it.

The layout is public and the memory is yours: a pose can live on the stack, in
an arena, inside a larger struct, or as a sub-range of a batch, and two poses
can be sub-ranges of one allocation. Blending is the same story — a
`BlendingLayer` is `ozz::animation::BlendingJob::Layer` field for field, so
`BlendingJob.run` hands your array straight to ozz with no copy and no
allocation. `ffi/zozz_abi.cpp` static_asserts every size, alignment and offset
of both against ozz's own types, so the reinterpretation cannot drift.

A C caller owns that memory too, and can therefore hand over a pointer ozz
would read with an aligned SIMD load. Every entry point taking SoA memory
checks the 16-byte boundary and returns `ZOZZ_RESULT_INVALID_ARGUMENT` rather
than faulting inside ozz.

### Allocator injection, honestly scoped

`setAllocator` routes every ozz allocation through a `std.mem.Allocator`. It is
process-wide, because [ozz's own allocator is](https://github.com/guillaumeblanc/ozz-animation/blob/master/include/ozz/base/memory/allocator.h) —
that is surfaced rather than hidden behind a per-object parameter that could
not be honoured.

The seam has one wrinkle worth knowing: ozz frees with `deallocate(block)`, no
size and no alignment, while Zig requires both. `src/memory.zig` bridges that
with a header stored ahead of each block. The C API keeps ozz's shape, so a
plain C host can still pass `malloc`/`free` in two lines.

That header also records the allocator the block came from, which is what makes
swapping one Zig allocator for another safe with blocks outstanding: each frees
through its own producer rather than through whoever happens to be installed at
destruction. Below the Zig layer the C seam cannot do that -- it holds one
`ZozzAllocator` -- so `zozzSetAllocator` refuses any call that would change
where a free lands, and reports `ZOZZ_RESULT_ALLOCATOR_IN_USE`, for as long as
`zozzAllocatorLiveBlocks()` is non-zero. A call that leaves the same allocator
in place is not such a change: reinstalling the identical one, or resetting
while none is installed, always succeeds. That counter doubles as a leak check
for a host whose own allocator has none.

The counter has to see *every* outstanding block for that refusal to mean
anything, including the ones ozz's own allocator handed out before any host was
installed -- ozz frees through whichever allocator is installed at destruction
time, not through the one that made the block, so a load before `setAllocator`
and a `deinit` after it would otherwise hand malloc'd memory to the Zig bridge.
So zozz takes ozz's global allocator slot at start-up and forwards to ozz's own
allocator until a host arrives, which is what makes the count total and the
refusal honest.

**Thread safety, and what it rests on.** Distinct handles may be used
concurrently as long as the installed allocator is thread-safe, because every
entry point that allocates arrives at this one seam; a single handle is not
internally synchronised, and neither is installing or resetting the allocator
-- do that from one thread before any other is inside zozz.
`src/concurrency_test.zig` runs the claim rather than restating it: four
threads, each with its own sampling context, poses and matrices, sharing one
skeleton and one clip, creating and destroying handles for two hundred frames
each against a `DebugAllocator` that accounts for every block.

### Validation at the boundary

ozz checks nothing in a release build. `IArchive::operator>>` for a primitive
is `Read(&v, sizeof(v))` followed by `assert(size == sizeof(v))` — and under
`NDEBUG` that assert is gone, so a short read leaves `v` holding stack garbage
and parsing continues. A count read that way decides how much ozz allocates and
copies. The tag check is an assert too. An unsupported archive version is
logged and leaves you an empty object with no error returned.

So the loaders here bracket ozz's parser with the checks it does not perform:

- **Tag-test before parsing** — wrong-type or non-ozz input is `BadFormat`, not
  a parse of unrelated bytes.
- **Truncation detection** — every archive, *including files*, is parsed
  through `ConstMemoryStream`, which satisfies each read in full, zero-fills
  past the end and latches a flag the loader checks. Zeros are the safe filler:
  a zeroed count is zero, so ozz's loops do nothing rather than run wild, and
  no partially-overwritten count can round upward. Files are buffered whole
  rather than handed to ozz's own `File` stream precisely because that stream
  returns the short reads ozz fails to check.
- **Sanity-check after parsing** — joint counts within ozz's own limit, arrays
  of consistent length, positive duration. This is what turns a
  version-mismatched clip into `BadFormat` instead of a zero-duration animation
  that samples to garbage.
- **Real out-of-memory handling, as far as it goes** — `ozz::New` is a
  placement-new on an unchecked allocation, so a failed allocation constructs
  at address zero. `ffi/zozz_internal.h` replaces it with a checked version,
  which is what makes the `OutOfMemory` paths reachable rather than decorative.
  What that does **not** cover is ozz's own internal allocations: `Skeleton`
  and `Animation` each build spans over an unchecked `Allocate` and write
  through them, so a load under memory pressure is a null dereference inside
  ozz. That is not fixable from outside; it is documented with file and line in
  [UPSTREAM.md](UPSTREAM.md). Sampling, once loaded, allocates nothing.

Every prefix of a valid archive, across both fixtures, is verified to be
rejected, and the whole archives still load. NaN ratios and misaligned matrix
buffers are refused too, rather than faulting inside SIMD code.

What this does **not** claim: ozz's parser is not hardened against arbitrary
hostile input, and zozz cannot make it so from the outside. The guarantee here
is that truncation and type confusion fail cleanly and deterministically, with
counts bounded rather than attacker-influenced. If you ever need to load `.ozz`
from an untrusted source, put a length-and-checksum container around it and
validate that first.

### The ABI guard

The Zig side hand-writes its `extern` declarations rather than running
translate-c, so the wrapper gets exactly the types it wants and the shipped
module never compiles C. Nothing in either compiler checks that those
declarations still agree with `ffi/zozz.h`, and a `size_t` narrowed to an `int`
links cleanly and corrupts. Three checks close that, on three different axes:

- **`src/abi_check.zig` — the header against the declarations.** A comptime
  `@cImport` of the real header, compared against `src/c.zig` by reflection:
  every struct field paired **by name** with its own offset, every scalar's
  size, alignment, signedness and int-versus-float, every function's arity and
  variadic-ness, every enumerator's value, every constant. There is **no
  hand-maintained list** — declarations are discovered by reflection and a
  declaration the check cannot classify is a compile error rather than a silent
  pass. It also sweeps the other direction, so a symbol the header exports but
  `c.zig` never declares (or declares as something that is not an extern) fails
  too. The `@cImport` happens in a test only; the shipped module stays
  translate-c-free.
- **`zozzAbiLayout()` — the compiled library against the declarations.** The
  header is a source file and the library is a binary; they can describe
  different structs while looking identical. This one asks the linked
  translation unit what it really laid out. Neither check replaces the other.
- **`static_assert`s in `ffi/zozz_abi.cpp` — ozz against the C++.** These fail
  the build if a vendored ozz upgrade changes a type this package casts to or
  from.

The first of those is the one that guards everything else, and it is the one
test here that cannot test itself: a refactor that quietly makes it vacuous
looks exactly like a passing build. `ci/check-abi-drift.sh` is the answer —
twelve deliberate drifts applied one at a time, each of which must be refused,
including the field swap that leaves every offset in the struct unchanged and
so defeats any positional or offsets-only comparison. It runs as its own CI job
and under `ci/run.sh`.

Because the check pairs an enum's fields to the header by name, the naming
convention is load-bearing rather than cosmetic:

| Zig side | C side |
|---|---|
| type `Foo` | `ZozzFoo` |
| function `zozzFoo` | `zozzFoo` |
| constant `foo_bar` | `ZOZZ_FOO_BAR` |
| enum `Foo`'s field `bar` | `ZOZZ_FOO_BAR` |

Enumerators take the **full type name**, always: `ZOZZ_RESULT_IO`, not
`ZOZZ_ERR_IO`. A C enum reaches Zig as a plain integer alias with no record of
which enumerators belonged to it, so the strict prefix is the only thing that
can pair one back to its enum. **No enumerator may be negative**, either — C
leaves an enum's underlying type to the implementation and the implementations
disagree, and every value being non-negative is what makes that unobservable.
The guard enforces both.

### Build hygiene

- Source lists are explicit, never globs — a re-vendor cannot silently change
  what compiles.
- No `-fno-access-control`. The FFI layer uses only ozz's public API, so it has
  no reason to defeat C++ access checking and no coupling to ozz internals.
- UBSan is **not** blanket-disabled, and it is **not** on by default either.
  `-Dsanitize_c=true` turns it on and zozz's own CI runs Debug that way, so
  real undefined behaviour surfaces instead of being suppressed. It stays off
  by default because Zig's C sanitizer emits calls into a runtime linked only
  into a compilation that is itself sanitized: a consumer who forgets to
  forward `optimize` would get an `undefined symbol: __ubsan_handle_*` link
  failure naming nothing they can act on. A library does not get to decide
  that its consumers are running a sanitizer.
- Build options are declared once and mirrored into a Zig `options` module, so
  the wrapper cannot disagree with how the C++ was compiled.
- One translation unit per concern on both sides of the boundary.

## Testing

```sh
zig build test
```

The suite is self-contained: assets are built at test time through ozz's own
offline builders and serialised in memory (`tests/fixture.cpp`), so it is always
version-matched to the vendored runtime and ships no third-party clips. That
fixture doubles as proof the offline builders compile and link — the foundation
of a future cook.

`zig build test-c` runs the C-level smoke test on its own, proving the header
is a real C contract rather than a private detail of the Zig wrapper, and that
the allocator seam is genuinely in use (it asserts allocations balance).

`zig build examples` builds and runs everything in `examples/`, and `zig build
test` includes it. An example that is only compiled proves the names still
resolve; running it is what proves the sequence still works — and the Usage
block at the top of this file is extracted from one, so it cannot drift from
code that executes.

```sh
zig build --build-file tests/consumer/build.zig run
```

builds zozz the way a downstream package does — through `b.dependency`, which
resolves the artifact by scanning the dependency's install step and the header
by its installed spelling. Neither of those is exercised by anything in `src/`
or `tests/`, so both can break while the whole suite stays green. The Zig
module and the C artifact are each driven by a real consumer there.

Zig's C sanitizer is off by default, so a plain `zig build test` runs
everything. Turning it on skips one test:

```sh
zig build test -Dsanitize_c=true    # skips the truncated-archive test
```

Not because that test fails, but because upstream ozz forms member accesses on
a null pointer when a keyframe array has zero entries — the exact shape a
zero-filled count produces. That is real, if benign, undefined behaviour *in
ozz*, and being able to see it is worth more than switching the sanitizer off
globally to silence it. See [UPSTREAM.md](UPSTREAM.md).

To additionally check a real asset on disk:

```sh
zig build test -Dskeleton_path=path/to/skeleton.ozz \
               -Danimation_path=path/to/clip.ozz
```

Both are held to the same assertions: unit-length quaternions, finite
transforms, parent-precedes-child joint ordering, root joints whose model
matrix matches their local translation, a clip that demonstrably moves, and a
NaN ratio that is refused.

### By the numbers

<!-- BEGIN GENERATED ci/measurements.sh --markdown -->
| | |
|---:|---|
| **0.4.0** | version, the same in `build.zig.zon` and `ffi/zozz_core.h` |
| **359** | C entry points (`ZOZZ_API` in `ffi/*.h`) |
| **359** | Zig externs (`pub extern fn` in `src/c.zig`) |
| **21** | installed public headers |
| **97** | ozz public names with a binding |
| **418** | ozz public names in the bound areas |
| **199** | Zig tests `zig build test` executes |
| **10** | tests it skips, each needing a build option or an on-disk asset |
| **206** | assertions in the standalone C smoke test |
| **41** | vendored ozz translation units `build.zig` compiles |
| **20** | zozz C++ translation units (`ffi/*.cpp`) |
| **14690** | Zig source lines (`src/`) |
| **9728** | C++ source lines (`ffi/`) |
| **18** | deliberate drifts `ci/check-abi-drift.sh` must refuse |
| **32** | steps `ci/run.sh` runs |
| **7** | further targets `ci/run.sh` cross-compiles |
<!-- END GENERATED -->

Not one of those is typed into this file. `ci/measurements.sh` recomputes them
from the tree, `ci/check-docs.sh` regenerates the block and fails the build if
what is committed differs, and the same gate refuses any other hand-written
number in these documents unless `tools/doc_numbers.txt` says why it cannot go
stale. Adding a claim means adding its measurement.

**What the numbers do not say.** A count is a count. Names *with a binding* are
matched by spelling, which proves neither that a binding is correct nor that an
unbound name is worth having — `ci/check-coverage.sh` holds those verdicts one
by one. Source lines measure volume, not surface. And the gate itself has three
blind spots: a number spelled as a word, a number inside `code` — where it is
an identifier or a citation rather than a claim — and a sentence that is wrong
without containing a number at all.

### Continuous integration

CI runs the whole suite on **Linux, macOS and Windows**, in every optimize
mode — Debug twice, once with the C sanitizer on and once without it, because
the malformed-input test needs it off — plus the standalone C test, both
optional build halves in each of the three combinations that are not the
default, the downstream-consumer build, and on Windows the MSVC ABI as well as
the gnu one. It also cross-compiles the further targets listed in `ci/run.sh`,
verifies the vendored tree against upstream, and runs the ABI drift mutation
test twice — once on the Itanium ABI and once on MSVC's, because
`src/abi_check.zig` compares `src/c.zig` against the header *as preprocessed
for a target*, and a C enum is `int` under one and `unsigned int` under the
other. See [`.github/workflows/ci.yml`](.github/workflows/ci.yml).

Locally, `ci/run.sh` runs the drift proof on this host's ABI only; the second
arm is `ci/run.sh --drift-target=<triple>`, or `ci/check-abi-drift.sh
-Dtarget=<triple>` on its own. It is opt-in because it rebuilds eighteen times
and `ci/run.sh` is installable as a pre-push hook — CI runs it on every push,
and a release should run both arms here.

The same matrix runs locally, so a failure is reproducible on your machine
before it is a red mark on a pull request:

```sh
ci/run.sh            # the full matrix
ci/run.sh --quick    # native Debug only, for the inner loop
ci/install-hooks.sh  # run it automatically before every push
```

It reports every failure rather than stopping at the first.

### Platform coverage

| | Suite executed by CI | Compile-checked by CI |
|---|---|---|
| Linux | x86_64 (glibc) | + aarch64, musl |
| macOS | aarch64 | + x86_64 |
| Windows | x86_64, both gnu and MSVC ABI | + aarch64 |

Compiling proves the sources and build graph are portable; only an executed
configuration proves behaviour, which is why the two are separate jobs.

That table describes the matrix, not a promise: **the badge at the top of this
file is the authority on whether those runs have actually happened and passed.**
The whole matrix has been executed — the suite on Linux, macOS and Windows,
including the Windows MSVC ABI, alongside the cross-compilation and
vendor-integrity jobs. What the badge tells you that this paragraph cannot is
whether it still passes on the commit you are reading.

## Scope

One header per concern, gathered by the umbrella `ffi/zozz.h`. Every C entry
point is mirrored by a Zig wrapper that a reflective cross-check pairs at build
time:

- Skeleton and animation loading, from file or memory
- Sampling with a frame-coherency context
- SoA pose storage, and SoA ↔ AoS conversion
- Local-to-model, over the whole hierarchy or over ozz's own `from`/`to`
  joint range, for re-running only the chain an IK correction touched
- Pose blending (`BlendingJob`): weighted, additive, and per-joint partial
  blending
- Two-bone and aim IK, and folding a correction back into a pose
- Matrix-palette skinning (`SkinningJob`)
- `ozz::math` as Zig rather than as foreign calls: SimdFloat4 and SimdInt4
  lane operations, quaternions, `Float4x4` including its `*`, `+` and `-`,
  `Transform` composition, and `Box`
- Runtime tracks (`Track`): five value types — float, float2, float3, float4,
  quaternion — plus edge-triggering over a `FloatTrack`
- Root-motion blending
- Skeleton and animation utilities: single-joint rest pose, hierarchy
  traversal, name lookup, per-track keyframe counts
- Offline building: author a skeleton (`RawSkeleton`) or clip (`RawAnimation`)
  at runtime and build it into the same runtime objects the loaders produce
- Offline animation processing: the animation optimizer (key-frame reduction),
  raw-animation sampling and re-timing, the additive animation builder, and
  root-motion extraction
- Raw tracks: the same five value types on the authoring side, with their own
  builders and optimizers
- The archive: saving a skeleton, a clip or a track to a host-controlled
  stream (or straight to a file) with `OArchive`, and reading them back from
  one with `IArchive` — including a tag test that answers "is the next object
  a T?" without consuming it, for a host reading a mixed archive
- Importing: `OzzImporter` in both directions — a glTF-backed importer
  (`Importer.initFromGltf`, `-Dgltf`) and a host-implementable
  `ImporterInterface` for a host with its own source format (`-Doptions`)

**What the importer is and is not.** `-Dgltf` compiles ozz's own
`GltfImporter`, which reads glTF and glb through the vendored `tiny_gltf.h`,
and hands back the same `RawSkeleton` and `RawAnimation` the offline builders
take — so a glTF file can be imported, optimised and built entirely in
process. Both options are off by default: each pulls in a large translation
unit, and a library must not charge every consumer for a feature it does not
use. With one off, the calls behind it return `error.Unsupported` rather than
failing to compile.

What is **not** there is `gltf2ozz`'s command line. Its driver
(`OzzImporter::operator()`, `Importer.run`) is configured through jsoncpp,
which lives in upstream's excluded `extern/`, so `run` always reports
`error.Unsupported`. A cook is a host's own program over `initFromGltf`, the
optimizer and `OArchive`, not a vendored executable.

The **FBX** importer is not a candidate at all: it needs the proprietary
Autodesk FBX SDK, and its sources are excluded for that reason.

Deliberately out of scope: a blend tree, a state machine, a clock, or an asset
system. Those are a host's job, and keeping them out is what makes this package
reusable.

## Contributing

Issues and pull requests are welcome. Two things to know before opening one:

- **`libs/ozz` is vendored verbatim and must not be edited.** Changes there are
  lost at the next re-vendor. If upstream needs fixing, fix it upstream; if
  zozz needs to work around upstream, do it in `ffi/` and record it in
  [UPSTREAM.md](UPSTREAM.md).
- **Run `ci/run.sh` before pushing** — or `ci/install-hooks.sh` once, and it
  runs itself. It is the same matrix CI runs.
- **Comments state a contract, not a narrative.** `ci/check-comments.sh`
  enforces two things and will fail a pull request over either. A block above
  one declaration is at most six lines; a file header, or a block under a
  `//===---===//` banner, at most fourteen. And the register is documentation,
  not conversation — no "we", "our", "note that", "which is why", "turns out",
  "you might expect".

  The cap never justifies dropping a fact. Units, ownership, lifetime,
  nullability, error conditions and ordering constraints come first; if a block
  cannot hold them in six lines, shorten the prose around them.

New source files are added to the explicit lists in `build.zig` deliberately;
there are no globs, so nothing starts compiling by accident.

## Licence

MIT, see [LICENSE](LICENSE), which covers this package's own code. Vendored
ozz-animation is MIT, copyright Guillaume Blanc and contributors; its licence
text ships with the package at `libs/ozz/LICENSE.md` and its authors at
`libs/ozz/AUTHORS.md`.
