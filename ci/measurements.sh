#!/usr/bin/env bash
#
# zozz — recompute every number the documentation claims.
#
# Every count README.md publishes comes from here and from nowhere else: the
# README carries a generated block that ci/check-docs.sh rebuilds from this
# script and refuses to let drift. A hand-written count is not allowed to
# exist, so there is nothing left that can quietly go stale.
#
# Usage:
#   ci/measurements.sh            # human-readable
#   ci/measurements.sh --kv       # KEY<TAB>VALUE<TAB>DESCRIPTION
#   ci/measurements.sh --markdown # the table README.md's generated block holds
#
# ZIG overrides the compiler used by the one measurement that has to build.
# Nothing here uses `bc`: it is absent from Git Bash, and an absent bc produced
# an EMPTY count rather than an error.

set -euo pipefail
cd "$(dirname "$0")/.."

MODE=${1:-}
ZIG=${ZIG:-zig}

#-----------------------------------------------------------------------------
# The measurements. Each is `emit KEY VALUE DESCRIPTION`, and the description
# is what the README prints, so a measurement is described once.
#-----------------------------------------------------------------------------

keys=()
values=()
descriptions=()
emit() {
  keys+=("$1")
  values+=("$2")
  descriptions+=("$3")
}

sum() { awk '{ total += $1 } END { print total + 0 }'; }

# build.zig fails to compile if build.zig.zon and ffi/zozz_core.h disagree on
# the version, so either file answers for both.
emit version "$(sed -n 's/^ *\.version = "\([^"]*\)".*/\1/p' build.zig.zon)" \
  'version, the same in `build.zig.zon` and `ffi/zozz_core.h`'

# One ZOZZ_API per entry point; the macro appears nowhere else.
entry_points=$(grep -rhc '^ZOZZ_API' ffi/*.h | sum)
emit c_entry_points "$entry_points" 'C entry points (`ZOZZ_API` in `ffi/*.h`)'

# The Zig mirror of the same set. src/abi_check.zig fails the build if the two
# sets disagree, so a difference here is a bug in this script.
externs=$(grep -c '^pub extern fn zozz' src/c.zig)
emit zig_externs "$externs" 'Zig externs (`pub extern fn` in `src/c.zig`)'

emit public_headers "$(ls ffi/*.h | wc -l | tr -d ' ')" 'installed public headers'

# tools/coverage.sh matches ozz's public names against zozz's entry points by
# name, per vendored area. The total is a work list, not a score: much of what
# it counts as public is ozz-internal machinery no C ABI should carry.
coverage_line=$(tools/coverage.sh | sed -n 's/^  TOTAL  *\([0-9][0-9]*\)  *\([0-9][0-9]*\).*/\1 \2/p')
emit ozz_names_bound "${coverage_line%% *}" 'ozz public names with a binding'
emit ozz_names_total "${coverage_line##* }" 'ozz public names in the bound areas'

# What the build reports, not what a grep for `test` finds: a test behind a
# build option would be counted by the grep and never run.
test_line=$(${ZIG} build test --summary all 2>&1 |
  sed -n 's/.*run test zozz-tests \([0-9][0-9]*\) pass, \([0-9][0-9]*\) skip .*/\1 \2/p' | head -1)
emit zig_tests_run "${test_line%% *}" 'Zig tests `zig build test` executes'
emit zig_tests_skipped "${test_line##* }" \
  'tests it skips, each needing a build option or an on-disk asset'
emit c_smoke_assertions "$(grep -c 'CHECK\|assert' tests/c_smoke.c)" \
  'assertions in the standalone C smoke test'

# What one configuration compiles.
emit ozz_translation_units "$(grep -cE '^ *"libs/ozz/[^"]*\.cc",' build.zig)" \
  'vendored ozz translation units `build.zig` compiles'
emit zozz_translation_units "$(ls ffi/*.cpp | wc -l | tr -d ' ')" \
  'zozz C++ translation units (`ffi/*.cpp`)'
emit zig_source_lines "$(cat src/*.zig | wc -l | tr -d ' ')" 'Zig source lines (`src/`)'
emit cxx_source_lines "$(cat ffi/*.cpp ffi/*.h | wc -l | tr -d ' ')" 'C++ source lines (`ffi/`)'

# One `try` or `expect` per mutation. check-abi-drift.sh counts the same
# declarations and refuses to report success unless it ran that many, so this
# count cannot overstate the proof.
emit abi_drift_mutations "$(grep -cE '^(try|expect) ' ci/check-abi-drift.sh)" \
  'deliberate drifts `ci/check-abi-drift.sh` must refuse'
emit ci_checks "$(grep -cE "^ *run ['\"]" ci/run.sh)" 'steps `ci/run.sh` runs'
emit ci_cross_targets \
  "$(sed -n '/^for target in/,/^do$/p' ci/run.sh | grep -cE '^ +[a-z0-9_]+-')" \
  'further targets `ci/run.sh` cross-compiles'

#-----------------------------------------------------------------------------
# Output
#-----------------------------------------------------------------------------

# A measurement that silently produces nothing is worse than a wrong one: it
# renders as an empty cell and reads as "not applicable". An empty value here
# is what a changed `zig build` summary format looks like from the outside.
for i in "${!keys[@]}"; do
  if [ -z "${values[$i]}" ]; then
    printf 'measurement %s produced no value; its source has changed shape\n' \
      "${keys[$i]}" >&2
    exit 1
  fi
done

if [ "$MODE" = "--kv" ]; then
  for i in "${!keys[@]}"; do
    printf '%s\t%s\t%s\n' "${keys[$i]}" "${values[$i]}" "${descriptions[$i]}"
  done
  exit 0
fi

if [ "$MODE" = "--markdown" ]; then
  printf '| | |
|---:|---|
'
  for i in "${!keys[@]}"; do
    printf '| **%s** | %s |
' "${values[$i]}" "${descriptions[$i]}"
  done
  exit 0
fi

for i in "${!keys[@]}"; do
  printf '%-24s %8s  %s\n' "${keys[$i]}" "${values[$i]}" "${descriptions[$i]}"
done

if [ "$entry_points" != "$externs" ]; then
  printf '\nc_entry_points and zig_externs must match: src/abi_check.zig pairs\n'
  printf 'them at build time, so a difference is a bug in this script.\n'
  exit 1
fi
