# zozz

Zig bindings for the [ozz-animation](https://github.com/guillaumeblanc/ozz-animation)
runtime — skeletal animation sampling, in a package with no renderer, no engine
and no asset system attached.

- Vendored, pinned upstream ozz (0.16.0). No fork, no patches. See [UPSTREAM.md](UPSTREAM.md).
- A real C ABI (`ffi/zozz.h`) that stands on its own — the Zig wrapper is one
  consumer of it, not its only reason to exist.
- Host allocator injection: every ozz allocation can go through your
  `std.mem.Allocator`.
- Layout drift between the C header and the Zig externs is a **test failure**,
  not a memory-corruption bug.

Status: **v0.1** — load, sample, convert, local-to-model. Blending, IK and the
offline cook are not exposed yet; see [Scope](#scope).

## Usage

```zig
const zozz = @import("zozz");

try zozz.setAllocator(gpa);
defer zozz.resetAllocator();

const skeleton = try zozz.Skeleton.initFromFile("skeleton.ozz");
defer skeleton.deinit();

const clip = try zozz.Animation.initFromFile("walk.ozz");
defer clip.deinit();

const pose = try zozz.SoaPose.initForSkeleton(skeleton);
defer pose.deinit();

const context = try zozz.SamplingContext.initForSkeleton(skeleton);
defer context.deinit();

// Per frame:
try pose.setRestPose(skeleton);
try zozz.sample(clip, context, clip.ratioAt(time_seconds), pose);

// Either read local transforms out...
try pose.toLocalTransforms(locals);

// ...or flatten the hierarchy to model space. Note the 16-byte alignment.
const models = try gpa.alignedAlloc(zozz.Mat4, .@"16", skeleton.numJoints());
try zozz.localToModel(skeleton, pose, null, models);
```

Add it as a dependency and link the module:

```zig
const zozz_dep = b.dependency("zozz", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("zozz", zozz_dep.module("zozz"));
```

## Design

### The SoA pose is opaque, and stays that way

ozz's job pipeline speaks structure-of-arrays: sampling writes it, blending
consumes and produces it, local-to-model reads it. `SoaPose` wraps that buffer
without exposing the SIMD layout, so jobs chain with no conversion between them
and no consumer ends up depending on how ozz packs four joints into a register.
Conversion to `Transform` (array-of-structs) happens only at the edges, where
you actually want it.

### Allocator injection, honestly scoped

`setAllocator` routes every ozz allocation through a `std.mem.Allocator`. It is
process-wide, because [ozz's own allocator is](https://github.com/guillaumeblanc/ozz-animation/blob/master/include/ozz/base/memory/allocator.h) —
that is surfaced rather than hidden behind a per-object parameter that could
not be honoured.

The seam has one wrinkle worth knowing: ozz frees with `deallocate(block)`, no
size and no alignment, while Zig requires both. `src/memory.zig` bridges that
with a header stored ahead of each block. The C API keeps ozz's shape, so a
plain C host can still pass `malloc`/`free` in two lines.

### Validation at the boundary

ozz is a release-build-`assert`-free library: a wrong-type archive, a truncated
file or an unsupported version generally leaves you holding a silently empty
object. Every loader here tag-tests before parsing and sanity-checks after, so
those cases surface as `BadFormat` instead of a zero-duration clip that samples
to garbage. NaN ratios and misaligned matrix buffers are rejected too, rather
than being passed through to fault inside SIMD code.

### The ABI guard

The Zig side hand-writes `extern struct`s mirroring `zozz.h`. Nothing in either
compiler checks those two declarations still agree — a field reordered on one
side and not the other is silent corruption. `zozzAbiLayout()` reports what the
C++ actually compiled to, and a test asserts every size and offset against the
Zig declarations. In the other direction, `static_assert`s in `ffi/zozz_abi.cpp`
fail the **build** if a vendored ozz upgrade changes a type this package casts
to or from.

This is deliberate: it is the check that comparable C++-to-Zig bindings tend to
skip, and the one whose absence is hardest to debug.

### Build hygiene

- Source lists are explicit, never globs — a re-vendor cannot silently change
  what compiles.
- No `-fno-access-control`. The FFI layer uses only ozz's public API, so it has
  no reason to defeat C++ access checking and no coupling to ozz internals.
- UBSan is **not** blanket-disabled. It stays on in Debug (`-Dsanitize_c`), so
  real undefined behaviour surfaces instead of being suppressed.
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

To additionally check a real asset on disk:

```sh
zig build test -Dskeleton_path=path/to/skeleton.ozz \
               -Danimation_path=path/to/clip.ozz
```

Both are held to the same assertions: unit-length quaternions, finite
transforms, parent-precedes-child joint ordering, root joints whose model
matrix matches their local translation, a clip that demonstrably moves, and a
NaN ratio that is refused.

Verified on macOS/aarch64, Zig 0.16, across Debug, ReleaseSafe, ReleaseFast and
ReleaseSmall.

## Scope

Exposed today:

- Skeleton and animation loading, from file or memory
- Sampling with a frame-coherency context
- SoA pose storage, and SoA ↔ AoS conversion
- Local-to-model

Not yet exposed, in rough order of likely need:

- Blending (`BlendingJob`), additive blending
- Two-bone and aim IK
- Tracks (`Track`, triggering)
- Skinning (`SkinningJob`)
- The offline path: glTF → `.ozz` cook

Nothing above is blocked — the sources are vendored and the C-boundary pattern
is established; they are simply not written yet. Deliberately out of scope: a
blend tree, a state machine, a clock, or an asset system. Those are a host's
job, and keeping them out is what makes this package reusable.

## Licence

MIT, see [LICENSE](LICENSE). Vendored ozz-animation is MIT, copyright Guillaume
Blanc and contributors.
