# Build hygiene

Rules `build.zig` follows, written down so a change keeps to them.

- **Source lists are explicit, never globs.** `ozz_runtime_sources`,
  `ozz_offline_sources` and the FFI source list name every file, so a
  re-vendor cannot silently change what compiles. A new file is added
  deliberately.
- **No `-fno-access-control`.** The FFI layer uses only ozz's public API, so it
  has no reason to defeat C++ access checking and no coupling to ozz
  internals.
- **UBSan is not blanket-disabled, and not on by default.** `-Dsanitize_c=true`
  turns it on and zozz's own CI runs Debug that way. It stays off by default
  because Zig's C sanitizer emits calls into a runtime linked only into a
  compilation that is itself sanitized: a consumer who forgets to forward
  `optimize` would get an `undefined symbol: __ubsan_handle_*` link failure
  naming nothing they can act on. A library does not get to decide that its
  consumers are running a sanitizer.
- **Two sanitizer check classes are switched off for vendored code only.**
  `-fno-sanitize=nonnull-attribute` on the vendored translation units, for
  ozz's zero-size `memcpy` on save; `-fno-sanitize=signed-integer-overflow` and
  `-fno-sanitize=shift-base` on the vendored units and on `tests/mathref.cpp`,
  for the reference SIMD backend's estimate and shift routines. zozz's own
  `ffi/` and `tests/fixture.cpp` keep the full sanitizer. UPSTREAM.md has both
  sites with file and line.
- **Build options are declared once and mirrored into a Zig `options`
  module**, so the wrapper cannot disagree with how the C++ was compiled. The
  test "the build options and the compiled library agree" holds the mirror to
  what the linked library reports.
- **One translation unit per concern**, on both sides of the boundary.
- **The version has one source.** `build.zig` fails to compile if
  `build.zig.zon` and `ffi/zozz_core.h` disagree, and a test holds
  `zozzVersion()` to the same number.
