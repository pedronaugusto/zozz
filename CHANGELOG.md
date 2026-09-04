# Changelog

Every release so far has been a breaking change, and there is no compatibility
layer: when a shape is wrong it is replaced, not wrapped. Each entry below says
what the old shape could not express, so a port has the reason and not only the
diff.

Versions follow [semantic versioning](https://semver.org). Before 1.0 the minor
is the breaking one.

## 0.5.0

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

## 0.4.0

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

## 0.3.0

Tagged `v0.3.0`. See the git history.

## 0.2.0

Tagged `v0.2.0`. See the git history.
