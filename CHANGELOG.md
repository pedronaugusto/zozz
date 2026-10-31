# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html); before
1.0 the minor is the breaking one. There is no compatibility layer: when a
shape is wrong it is replaced, not wrapped. Each entry says what the old shape
could not express, so a port has the reason and not only the diff.

## [Unreleased]

### Breaking

- Every call that can fail takes a `*zozz.Failure` as its last argument,
  jobs' `run` included, and a refusal pushes a `zozz.Frame` on it: the
  `zozz.Call` that refused and its result. An error alone said what went
  wrong but not which call, and a load, a bake or a frame makes several.
  Declare one with `var failure: zozz.Failure = .{};` and pass `&failure`.
- Every archive loader takes a `ZozzRefusal*` as its last parameter (C): each
  `*LoadMemory`, `*LoadFile` and `zozzIArchiveLoad<Type>`, NULL allowed. A
  loader clears it on entry, and a refusal for the archive's content fills it
  with the version or count that failed (`what`, a static string such as
  `Skeleton.num_joints`), what the archive held (`value`) and the bound it
  broke (`limit`): with `ZOZZ_RESULT_BAD_FORMAT` when a bound of ozz's is
  broken, and with `ZOZZ_RESULT_IO` when a count runs past the bytes the
  archive has left, `limit` then being what fits. In Zig a
  `zozz.Frame` carries it as `refusal` (`frame.refusal.named()`, `value`,
  `limit`). `BadFormat` alone could not say which count broke or by how much:
  a skeleton one joint over ozz's limit and bytes that are not an archive at
  all gave the same answer.
- `zozzAnimationBuild` and `RawAnimation.build` take the iframe interval,
  AnimationBuilder's `iframe_interval`: seconds between the cache snapshots
  the sampler seeks to when its ratio jumps, 0 for none. Negative,
  non-finite, or dividing the clip more ways than a `uint32_t` counts is
  `INVALID_ARGUMENT`. The old shape always built none, so every seek walked
  the keys from the start or from where the last sample left off.
- Every loader of bytes takes `zozz.Bytes` (aegis's untrusted-input type):
  every `initFromMemory` and `decodeGV4`/`decodeGV4Stream`; wrap a
  slice with `.init(bytes)`. `IArchive.init` takes a `zozz.InputStream`.
- `getAllocator` returns `?c.Allocator` and `setLogLevel` returns `void`:
  neither can be refused from Zig, so their error unions were never an
  answer.
- Builds on Zig 0.17.0, which `build.zig.zon` now requires. The tests read
  `ffi/zozz.h` through the build's translate-c step, since 0.17 removed
  `@cImport`, and the wrapper walks 0.17's reflection lists.

### Changed

- The `zozz` module depends on aegis 0.2.4. The installed allocator is held
  in an `aegis.Guarded` cell rather than a bare mutable global, so every read
  and write of it goes through one acquire.
- Development runs under preflight's gate (`bay test`), with every check a Zig
  program under `ci/`; the shell scripts, `ci/run.sh` and its pre-push hook are
  gone. `zig build recon -- <Class>` replaces `tools/recon.sh`.
- `BINDING.md`, `UPSTREAM.md` and the four files under `docs/` are one
  `docs/design.md`. The README's archive-version table moved into its Scope
  section, and its Platforms section says what preflight's matrix runs: the
  suite on `x86_64-windows-msvc` is executed on a Windows machine before a
  release, not by CI.

### Fixed

- A crafted archive could drive ozz's own `Load` into an allocation sized by
  a count it never checked: a skeleton whose name block claims a negative
  size faulted inside `Skeleton::Load`, and a raw archive's vector or string
  count reached `resize` as it stood. An unsupported version loaded as an
  empty object. `libs/ozz` now carries `libs/patches/ozz-archive-counts.patch`,
  which checks every version and count against ozz's limits and the bytes
  left before anything is sized, bounds a raw skeleton's nesting, and refuses
  through the record above. `libs/ozz` was upstream byte for byte, and had no
  way to say so short of crashing; `check-vendor` now proves upstream plus
  exactly the listed patches.
- A load or build that ozz could not allocate for wrote through the null
  block: `Skeleton`, `Animation` and `Track` built their spans over it, the
  builders filled them, `ozz::New` constructed at address zero, and a
  suppressed log line did the same with its stream. Each now reports the
  failure, and the loader or builder returns `OutOfMemory`
  (`libs/patches/ozz-checked-allocation.patch`). Inside a standard
  container, which has no failure path, ozz aborts instead of constructing
  at null; every count an archive gives one is checked before it resizes.
- A caller's `u32` or `usize` past what the C boundary's `int` carries
  (`SamplingContext.init(1 << 31)`, a joint, track or vertex count) was
  `@intCast`, a panic in a safe build and undefined in ReleaseFast; it is
  `error.InvalidArgument` with a frame now, and a count the boundary reports
  goes through a narrowing that stops in every build. A handle used after its
  `deinit` stops in every build too: it was a null unwrap, undefined in
  ReleaseFast.
- The coverage check read a template's `<class T>` as a class header that
  opened no body, and carried it into the next header it read: nine public
  ozz names (`IntrusiveList`, `allocate`, `array_begin` and six more) counted
  as having no public declaration, so `INTERNAL` could be claimed for them.
  `array_begin` and `array_end` were, and are `LANGUAGE` now.
- The ABI check held the bound surface to floors of ten-odd, so most of it
  could vanish unnoticed. Its floors are the measured counts, held in
  `src/abi_test.zig`, and the two call shapes Zig has
  miscompiled (a float after more than six integer parameters, an aggregate
  returned by value) are counted and pinned at none.
- README's numbers block counted every header in `ffi/` as an installed public
  header, the two C++-internal ones that are never installed included. It now
  counts `zozz.h` and the headers it includes.
- The archive-version table left out the five element types the offline
  archives declare in source files (`RawAnimation::JointTrack` and its three
  key types, `RawSkeleton::Joint`); `zig build archive-versions` reads
  `libs/ozz/src` as well as `libs/ozz/include` now.
- The `ShiftL` site recorded for the sanitizer exemption was
  `simd_math_ref-inl.h:1491`; the shift is at `simd_math_ref-inl.h:1493`.

- `-Denable_asserts=true` keeps ozz's asserts in ReleaseFast and ReleaseSmall.
  Zig 0.17 defines NDEBUG for C by itself in those two modes, and the build
  only ever added NDEBUG, never removed it, so the C++ was built without its
  asserts while `zozz.options` and `zozzBuildFeatures` disagreed about it.
  NDEBUG now follows the option in every mode.
- The coverage check harvested only names followed by `(`, so it never saw
  the public data members of upstream's structs: the parameters a caller
  sets on a builder or a job, and raw data fields. That hid
  `AnimationBuilder::iframe_interval`, which no entry point reaches. It reads
  them now (outside `namespace internal`), and every member no entry point
  spells out carries a verdict in `ci/coverage/unbound_*.txt`.

## [0.5.0] - 2026-09-04

### Fixed

- **A host allocator could be installed while ozz's own blocks were still
  outstanding**, and their frees then landed on the host.
  `zozzAllocatorLiveBlocks()` counted only what an installed host had handed
  out, so it read zero in the one ordering that matters -- load a skeleton,
  then `setAllocator` -- and the guard it feeds allowed the install. ozz frees
  through whichever allocator is installed at destruction time, not through the
  one that produced the block, so destroying that skeleton handed malloc'd
  memory to the Zig bridge, which read the bytes ahead of it as its own header
  and freed a base pointer with a length and an alignment it invented. A
  counter that sees one of the two allocators cannot answer the question the
  guard asks, so zozz now occupies ozz's global allocator slot from the start
  of the process and forwards to ozz's own allocator until a host is installed.
  `zozzAllocatorLiveBlocks()` widened with it: it is every outstanding ozz
  block now, not only the host's, and the sequence above is refused with
  `ZOZZ_RESULT_ALLOCATOR_IN_USE` in both directions rather than one. A call
  that leaves the same allocator in place is still not a change: reinstalling
  the identical one, or resetting while none is installed, succeeds with blocks
  live.
- **`BlendingJob.run` dropped `rest_pose.len`.** `out.len` became the C
  `blocks` parameter for both buffers, and the span ozz validates is built from
  that same count, so `Validate()` could not see the discrepancy: a `rest_pose`
  shorter than `out` was read past its end for every joint whose accumulated
  weight fell below `threshold`. A short one is `error.InvalidArgument` now.
  Every other buffer in that call already carried its own count across the
  boundary; this was the one that did not.
- **The coverage report measured nothing on macOS.** `tools/coverage.sh` handed
  its newline-separated list of exposed types to `awk -v`, which the awk macOS
  ships refuses with `newline in string`; that error went to a discarded
  stderr, so every area came back holding zero public names and three gates
  took it for fact — `ci/check-coverage.sh` reported full coverage of an empty
  population, `ci/measurements.sh` had no `ozz_names_bound` to publish, and
  `ci/check-abi-drift.sh` skipped the five mutations that prove the coverage
  gate is not vacuous. The list travels in the environment now, awk's stderr is
  no longer discarded, and the percentage stopped relying on the arithmetic
  ternary short-circuiting: bash 3.2, the newest bash macOS ships, evaluates
  both arms and divided by the zero the guard was written to avoid.
- **UPSTREAM.md's archive-version table was ordered by locale.**
  `tools/archive_versions.sh` ended in a bare `sort`, which folds `::` away and
  puts `animation::QuaternionTrack` after `animation::offline::RawAnimation`
  under `en_US.UTF-8` and before it under `C`. The committed table was correct
  and read as stale on any host with a collating locale. The generator sorts in
  byte order.

## [0.4.0] - 2026-09-02

The `.ozz` archive format is unchanged, and the vendored ozz-animation is still
0.17.0. Everything below is this package's own surface.

### Removed

- `zozzTrackTriggeringIteratorDestroy`. A triggering session is caller-owned
  storage now (`ZozzTrackTriggeringIterator`, a struct the header sizes), the
  way ozz's own job and iterator are ordinary stack objects. Declare one, hand
  its address to `Run`, and destroy nothing. Storage that was never run, or that
  was copied after it was, is refused with `ZOZZ_RESULT_INVALID_ARGUMENT`
  instead of being undefined behaviour.
- `zozzSoaPoseApplyLocalCorrection`, replaced by
  `zozzSoaPoseApplyLocalCorrections` over an array of `ZozzJointCorrection`.
  One crossing per IK pass rather than one per joint, one transpose over each
  run of corrections that share an SoA block, and every joint index validated
  before anything is written. Zig keeps `ik.applyCorrection` as the
  single-joint spelling of the same call.

### Changed

- **The IK jobs take `ZozzSimdFloat4`**, as ozz's own job fields do, rather than
  `float[3]`/`float[4]` converted on the way in and out. Zig's `ik.Vec4` is the
  `@Vector(4, f32)` the rest of the maths uses.
- **A skeleton's hierarchy is read in bulk.** `zozzSkeletonJointParents`,
  `JointNames` and `JointRestPoses` return borrowed views of ozz's own
  contiguous arrays; reading a 200-joint hierarchy costs one call, not 200.
- **A track's keyframes are read in bulk.** `Ratios`, `Values` and `Steps` for
  all five track types return borrowed views instead of copying into a caller
  buffer, and the Zig accessors no longer allocate. `steps` is ozz's packed
  bitset, sized in BYTES; the new `zozzTrackInterpolations` decodes it into one
  entry per keyframe and is the only place the bit order is read.
- **`Animation.ratioAt` takes a `TimeMode`**, and has no default. A clip carries
  no loop flag — ozz stores none — so `.clamp` or `.loop` is the caller's
  statement rather than a silent choice. `.loop` wraps in both directions.
- **`OptionsParser.register` / `unregister` take the option**, not its raw
  `*c.Option` handle.
- **The offline types can be read back.** `RawSkeleton`, `RawAnimation` and the
  five raw tracks expose their keys, names, durations and validity, and every
  one of them can be written to and read from an archive — a cook stage can
  hand its output to the next stage instead of only building and discarding.

### Added

- **`zozzBuildFeatures`** — what the linked library was actually compiled with
  (`-Doptions`, `-Dgltf`, asserts). `ZOZZ_RESULT_UNSUPPORTED` alone could not
  say whether a feature was missing from this build or the call had failed.
- **`examples/`**, built and run by `zig build examples`, which `zig build test`
  depends on. README.md's Usage block is extracted from `examples/usage.zig`,
  so the snippet a reader copies is code CI executes.
- Matrix and transform arithmetic in `zozz.math`, and `Box`.
- A differential test of `src/math.zig` against the compiled ozz it is a port
  of, and `ci/check-mathref.sh` to refuse a new maths function with neither a
  comparison nor a stated reason.

### Fixed

- **`-Doptions` and `-Dgltf` had rotted**: no gate ever compiled either, so
  neither built. `src/options_test.zig` did not compile on Windows at all.
  Both are now built and RUN by `ci/run.sh` and by CI on Linux, macOS, Windows
  and the MSVC ABI, in each of the three combinations that are not the default
  — both flags are comptime-known, so turning both on at once leaves the
  one-on-one-off arms as uncompiled as leaving both off did, and one of them
  was in fact uncompilable. Six behavioural tests that existed but had never
  executed now do.
- The differential maths test compared `RCPESTX` and `RSQRTESTX` on all four
  lanes. ozz's SSE backend leaves the upper three to whatever the compiler put
  there — measured pass-through at `-O0`, `-O2` and `-O3`, zero at `-Os` — so
  the same ozz answered differently in ReleaseSmall. Lane 0 is compared;
  zozz's own pass-through is pinned in `src/math_test.zig`.
- The ABI drift mutation proof ran on one ABI. `src/abi_check.zig` compares
  `src/c.zig` against `@cImport` of the header *as preprocessed for a target*,
  so firing on the Itanium ABI proved nothing about MSVC's — where a C enum is
  `int` rather than `unsigned int`, which `ZozzResult` and
  `ZozzTrackInterpolation` cross in signatures and in struct fields.
  `ci/check-abi-drift.sh` now takes `-Dtarget=<triple>`, CI runs it on both,
  and all eighteen mutations are refused on each.
- `ZOZZ_ALIGN16` is applied to types rather than members, which made the ABI
  oracle disagree with every non-MSVC object file over a difference no object
  file had. `ci/check-alignment.sh` holds it.
- `LocalToModelJob` takes ozz's own `from`/`to` range, validated, instead of an
  invented sentinel.
- Destroying a handle empties it, so a second destroy is a no-op and a use
  after it is a checked panic rather than a read of freed memory.
- The vendor check compares bytes, not line endings.
- Every number in README.md and UPSTREAM.md is generated by `ci/measurements.sh`
  and compared by `ci/check-docs.sh`; a hand-written one fails the build.

## [0.3.0] - 2026-08-25

Tagged `v0.3.0`. See the git history.

## [0.2.0] - 2026-08-23

Tagged `v0.2.0`. See the git history.
