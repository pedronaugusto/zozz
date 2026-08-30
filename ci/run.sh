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

QUICK=0
[ "${1:-}" = "--quick" ] && QUICK=1

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

section() { printf '\n%s%s%s\n' "$BOLD" "$1" "$OFF"; }

printf '%szozz local CI%s  %s%s%s\n' "$BOLD" "$OFF" "$DIM" "$(zig version)" "$OFF"

#-----------------------------------------------------------------------------
section 'Hygiene'
#-----------------------------------------------------------------------------

# Only our own Zig sources: libs/ozz is vendored verbatim and must not be
# reformatted, or the next re-vendor becomes an unreadable diff.
run 'zig fmt (src, tests, build.zig)' \
  zig fmt --check src tests/consumer build.zig

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

# ZOZZ_ALIGN16 on a member instead of the type makes the ABI oracle fail on
# every non-MSVC target for a difference no object file has. See the script.
run 'ZOZZ_ALIGN16 is applied to types' ci/check-alignment.sh

#-----------------------------------------------------------------------------
section 'Tests — native'
#-----------------------------------------------------------------------------

ASSET_ARGS=()
if [ -n "${ZOZZ_SKELETON:-}" ] && [ -n "${ZOZZ_ANIMATION:-}" ]; then
  ASSET_ARGS=(-Dskeleton_path="$ZOZZ_SKELETON" -Danimation_path="$ZOZZ_ANIMATION")
  printf '  %s(on-disk assets: %s)%s\n' "$DIM" "$(basename "$ZOZZ_SKELETON")" "$OFF"
else
  printf '  %s(on-disk asset test will skip: set ZOZZ_SKELETON and ZOZZ_ANIMATION)%s\n' "$DIM" "$OFF"
fi

# The C sanitizer is opt-in — a library must not force its runtime into a
# consumer's link — so zozz's own Debug run asks for it explicitly. This is the
# run that would catch undefined behaviour in our own code.
run 'test Debug (UBSan on)' \
  zig build test -Doptimize=Debug -Dsanitize_c=true ${ASSET_ARGS[@]+"${ASSET_ARGS[@]}"}

# The truncated-archive test only runs with the sanitizer off — see UPSTREAM.md
# for why (upstream ozz UB on zero-count arrays). This is the run that proves
# malformed input is rejected.
run 'test Debug (UBSan off, truncation)' \
  zig build test -Doptimize=Debug -Dsanitize_c=false ${ASSET_ARGS[@]+"${ASSET_ARGS[@]}"}

if [ $QUICK -eq 0 ]; then
  for mode in ReleaseSafe ReleaseFast ReleaseSmall; do
    run "test $mode" zig build test -Doptimize="$mode" -Dsanitize_c=false ${ASSET_ARGS[@]+"${ASSET_ARGS[@]}"}
  done

  # The C boundary on its own, with no Zig in the picture.
  run 'test-c (C ABI standalone)' zig build test-c

  # Consuming zozz as a dependency is a different code path from building it —
  # artifact registration and installed-header spelling are invisible to the
  # in-repo suite. See tests/consumer/build.zig.
  run 'consumer (module + artifact)' \
    zig build --build-file tests/consumer/build.zig run

  #---------------------------------------------------------------------------
  section 'ABI'
  #---------------------------------------------------------------------------

  # Mutation test for the ABI cross-check itself — see the script's own header
  # for why a check that guards everything else needs one. It rebuilds once per
  # mutation, which is why it is out of the --quick loop.
  run 'abi drift (17 mutations)' ci/check-abi-drift.sh
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
  run "build $target" zig build -Dtarget="$target"
done

# x86_64-windows-msvc is absent here because it needs the Microsoft standard
# library, which a non-Windows host does not have. CI covers it natively on a
# Windows runner.

#-----------------------------------------------------------------------------
section 'Build configurations'
#-----------------------------------------------------------------------------

run 'shared library' zig build -Dshared=true
run 'asserts off' zig build -Denable_asserts=false
run 'ReleaseFast + asserts on' zig build -Doptimize=ReleaseFast -Denable_asserts=true
fi

#-----------------------------------------------------------------------------
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
