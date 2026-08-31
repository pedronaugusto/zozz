#!/usr/bin/env bash
#
# zozz — the CI matrix, run locally.
#
# This mirrors .github/workflows/ci.yml so a failure can be reproduced and
# fixed on your own machine instead of in a pull request. Install it as a
# pre-push hook with ci/install-hooks.sh to catch problems before they are
# pushed at all.
#
# The one difference from the hosted run: CI executes the suite on Linux,
# macOS and Windows, whereas this executes it on whichever host you are on and
# cross-compiles the rest.
#
# Usage:
#   ci/run.sh                 # full matrix
#   ci/run.sh --quick         # native Debug only, for the inner loop
#
# Optional, enables the on-disk asset test:
#   ZOZZ_SKELETON=/path/to/skeleton.ozz ZOZZ_ANIMATION=/path/to/clip.ozz ci/run.sh
#
# Exits non-zero if any step fails, after running every step — a single
# failure should not hide the others.

set -uo pipefail
cd "$(dirname "$0")/.."

# Overridable so a caller can point at a specific toolchain or a wrapper (a
# build lock, a timing shim) without editing this file. ci/check-abi-drift.sh
# reads the same variable. Used unquoted below on purpose: a wrapper is more
# than one word.
ZIG="${ZIG:-zig}"

QUICK=0
[ "${1:-}" = "--quick" ] && QUICK=1

# --list names every step this script would run, one per line, and runs none of
# them. ci/measurements.sh counts those lines, so README's step count is the
# number of steps rather than the number of `run` lines: a step inside a loop
# is one line and several steps, and the two had already diverged.
LIST=0
[ "${1:-}" = "--list" ] && LIST=1

if [ -t 1 ]; then
  RED=$'\033[31m'; GREEN=$'\033[32m'; DIM=$'\033[2m'; BOLD=$'\033[1m'; OFF=$'\033[0m'
else
  RED=; GREEN=; DIM=; BOLD=; OFF=
fi

PASSED=0
FAILED=0
FAILED_NAMES=()

# run <name> <command...>
run() {
  local name="$1"; shift
  if [ $LIST -eq 1 ]; then printf '%s\n' "$name"; return 0; fi
  printf '  %-46s' "$name"
  local start output status
  start=$(date +%s)
  output=$("$@" 2>&1)
  status=$?
  local elapsed=$(( $(date +%s) - start ))

  if [ $status -eq 0 ]; then
    printf '%sok%s %s(%ds)%s\n' "$GREEN" "$OFF" "$DIM" "$elapsed" "$OFF"
    PASSED=$((PASSED + 1))
  else
    printf '%sFAILED%s %s(%ds)%s\n' "$RED" "$OFF" "$DIM" "$elapsed" "$OFF"
    FAILED=$((FAILED + 1))
    FAILED_NAMES+=("$name")
    printf '%s' "$output" | sed 's/^/      | /' | head -40
  fi
}

section() { [ $LIST -eq 1 ] || printf '\n%s%s%s\n' "$BOLD" "$1" "$OFF"; }

[ $LIST -eq 1 ] ||
  printf '%szozz local CI%s  %s%s%s\n' "$BOLD" "$OFF" "$DIM" "$($ZIG version)" "$OFF"

#-----------------------------------------------------------------------------
section 'Hygiene'
#-----------------------------------------------------------------------------

# Only our own Zig sources: libs/ozz is vendored verbatim and must not be
# reformatted, or the next re-vendor becomes an unreadable diff.
run 'zig fmt (src, examples, tests, build.zig)' \
  $ZIG fmt --check src examples tests/consumer build.zig

# Every header ffi/zozz.h pulls in has to be installed with the library, or a C
# consumer gets an umbrella header that does not resolve. The consumer test
# catches this too, but only after a full build.
run 'installed headers cover every include' bash -c '
  comm -23 \
    <(grep -hoE "#include \"zozz_[a-z_]+\.h\"" ffi/*.h | sed "s/#include \"//; s/\"//" | sort -u) \
    <(grep -oE "ffi/zozz_[a-z_]+\.h" build.zig | sed "s|ffi/||" | sort -u) |
  grep . && { echo "not in build.zig'"'"'s installHeader list"; exit 1; }; exit 0'

# Every public ozz name in the areas this ABI claims has a verdict, and every
# verdict that says "reachable" names a symbol the headers really declare. It
# is here rather than behind a flag because it takes under a second and because
# a gap is the kind of thing that should stop a push, not wait for a nightly.
# Comment blocks stay short and stay out of the narrative register. The script
# existed before this line did, which is how a package ends up with a standard
# nothing enforces.
run 'comment standard' ci/check-comments.sh

run 'coverage (every name has a verdict)' ci/check-coverage.sh

# src/math.zig is a hand port, so what the differential test does NOT reach is
# the part worth naming. A new maths function with no row and no reason stops
# a push here rather than being noticed a release later.
run 'differential maths (tested or explained)' ci/check-mathref.sh

# Every number README.md and UPSTREAM.md publish, recomputed and compared. It
# builds once (the test count is what the build reports, not a grep), so it
# sits with the tests rather than with the one-second checks above.
run 'documented numbers' ci/check-docs.sh

# ZOZZ_ALIGN16 on a member instead of the type makes the ABI oracle fail on
# every non-MSVC target for a difference no object file has. See the script.
run 'ZOZZ_ALIGN16 is applied to types' ci/check-alignment.sh

# CI runs the scripts in ci/ by path. One committed without its executable bit
# fails there and nowhere else, because every local runner invokes bash first.
run 'every committed script is executable' ci/check-executable.sh

#-----------------------------------------------------------------------------
section 'Tests — native'
#-----------------------------------------------------------------------------

ASSET_ARGS=()
if [ -n "${ZOZZ_SKELETON:-}" ] && [ -n "${ZOZZ_ANIMATION:-}" ]; then
  ASSET_ARGS=(-Dskeleton_path="$ZOZZ_SKELETON" -Danimation_path="$ZOZZ_ANIMATION")
  printf '  %s(on-disk assets: %s)%s\n' "$DIM" "$(basename "$ZOZZ_SKELETON")" "$OFF"
elif [ $LIST -eq 0 ]; then
  printf '  %s(on-disk asset test will skip: set ZOZZ_SKELETON and ZOZZ_ANIMATION)%s\n' "$DIM" "$OFF"
fi

# The C sanitizer is opt-in — a library must not force its runtime into a
# consumer's link — so zozz's own Debug run asks for it explicitly. This is the
# run that would catch undefined behaviour in our own code.
run 'test Debug (UBSan on)' \
  $ZIG build test -Doptimize=Debug -Dsanitize_c=true ${ASSET_ARGS[@]+"${ASSET_ARGS[@]}"}

# The truncated-archive test only runs with the sanitizer off — see UPSTREAM.md
# for why (upstream ozz UB on zero-count arrays). This is the run that proves
# malformed input is rejected.
run 'test Debug (UBSan off, truncation)' \
  $ZIG build test -Doptimize=Debug -Dsanitize_c=false ${ASSET_ARGS[@]+"${ASSET_ARGS[@]}"}

if [ $QUICK -eq 0 ]; then
  for mode in ReleaseSafe ReleaseFast ReleaseSmall; do
    run "test $mode" $ZIG build test -Doptimize="$mode" -Dsanitize_c=false ${ASSET_ARGS[@]+"${ASSET_ARGS[@]}"}
  done

  # The C boundary on its own, with no Zig in the picture.
  run 'test-c (C ABI standalone)' $ZIG build test-c

  # -Doptions and -Dgltf are off by default, so nothing above compiles either
  # of them, let alone the tests that only exist behind them. Both are
  # comptime-known, so a branch the current combination does not take is never
  # analysed: turning both on leaves the one-on-one-off arms as uncompiled as
  # leaving both off did. All three, then; the fourth is every other run here.
  run 'test -Doptions=true -Dgltf=false' \
    $ZIG build test -Doptions=true -Dgltf=false -Dsanitize_c=false
  run 'test -Doptions=false -Dgltf=true' \
    $ZIG build test -Doptions=false -Dgltf=true -Dsanitize_c=false
  run 'test -Doptions=true -Dgltf=true' \
    $ZIG build test -Doptions=true -Dgltf=true -Dsanitize_c=false

  # Consuming zozz as a dependency is a different code path from building it —
  # artifact registration and installed-header spelling are invisible to the
  # in-repo suite. See tests/consumer/build.zig.
  run 'consumer (module + artifact)' \
    $ZIG build --build-file tests/consumer/build.zig run

  #---------------------------------------------------------------------------
  section 'ABI'
  #---------------------------------------------------------------------------

  # Mutation test for the ABI cross-check itself — see the script's own header
  # for why a check that guards everything else needs one. It rebuilds once per
  # mutation, which is why it is out of the --quick loop.
  run 'abi drift (mutation proof)' ci/check-abi-drift.sh
fi

#-----------------------------------------------------------------------------
if [ $QUICK -eq 0 ]; then
section 'Cross-compilation'
#-----------------------------------------------------------------------------

# Compile-only. These prove the sources and build graph are portable; the
# tests above are what prove behaviour, on this host. CI executes the suite on
# Linux, macOS and Windows as well.
for target in \
  x86_64-linux-gnu \
  aarch64-linux-gnu \
  x86_64-linux-musl \
  x86_64-windows-gnu \
  aarch64-windows-gnu \
  x86_64-macos \
  aarch64-macos
do
  run "build $target" $ZIG build -Dtarget="$target"
done

# x86_64-windows-msvc is absent here because it needs the Microsoft standard
# library, which a non-Windows host does not have. CI covers it natively on a
# Windows runner.

#-----------------------------------------------------------------------------
section 'Build configurations'
#-----------------------------------------------------------------------------

run 'shared library' $ZIG build -Dshared=true
run 'asserts off' $ZIG build -Denable_asserts=false
run 'ReleaseFast + asserts on' $ZIG build -Doptimize=ReleaseFast -Denable_asserts=true
fi

#-----------------------------------------------------------------------------
[ $LIST -eq 0 ] || exit 0
printf '\n'
if [ $FAILED -eq 0 ]; then
  printf '%s%d passed, 0 failed%s\n' "$GREEN" "$PASSED" "$OFF"
  exit 0
fi

printf '%s%d passed, %d FAILED%s\n' "$RED" "$PASSED" "$FAILED" "$OFF"
for name in "${FAILED_NAMES[@]}"; do
  printf '  %s- %s%s\n' "$RED" "$name" "$OFF"
done
exit 1
