#!/usr/bin/env bash
#
# zozz — mutation test for the ABI cross-check.
#
# `src/abi_check.zig` compares every extern declaration in `src/c.zig` against
# the real `ffi/zozz.h` by reflection. It is the one test in this repo that
# cannot test itself: a refactor that quietly makes it vacuous — a name filter
# that matches nothing, a sweep that silently skips a category — looks exactly
# like a passing build. The coverage floors in `abi_check.zig` catch the crude
# version of that. Only mutation catches the subtle one.
#
# So this applies one deliberate drift at a time, asserts the build is REFUSED
# with a `zozz ABI drift:` message, and reverts. Each mutation is a distinct
# kind of skew, chosen because it is the kind a human review would miss:
# notably the field swap, which leaves every offset in ZozzTransform unchanged
# and so defeats any positional or offsets-only comparison.
#
# Some mutations also break an unrelated call site — dropping a parameter from
# an extern invalidates the wrapper that calls it. That is fine and expected:
# what is asserted is that the drift message is among the errors, not that it
# is the only one.
#
# Not part of the default `ci/run.sh` — it rebuilds once per mutation. It runs
# under the full matrix, and should be run by hand whenever `abi_check.zig` is
# edited.
#
# Usage: ci/check-abi-drift.sh

set -uo pipefail
SELF=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")
cd "$(dirname "$0")/.."

pass=0

# What `expect` runs to see whether a mutation is refused. Almost every
# mutation below is answered by the ABI cross-check, which lives inside the
# test build; the coverage guard is a script, and rebuilding the world to ask
# it a question it answers in a fraction of a second would be silly.
ZIG=${ZIG:-zig}
BUILD="$ZIG build test"
fail=0
backups=()

restore() {
  local f
  for f in "${backups[@]:-}"; do
    [ -n "$f" ] && [ -f "$f.bak" ] && mv "$f.bak" "$f"
  done
  backups=()
}
# A killed run must not leave a mutated source behind.
trap 'restore; exit 130' INT TERM

# try <description> <file> <from> <to>
#
# Asserts the ABI cross-check refuses the mutation, by its own message.
try() {
  expect 'zozz ABI drift: .*' "$@"
}

# expect <signal> <description> <file> <from> <to>
#
# `signal` is a grep pattern the output must contain. Requiring a specific
# signal rather than merely a non-zero exit is the whole point: a mutation that
# fails for an unrelated reason — a typo in the replacement, a stale anchor
# landing somewhere odd — would otherwise be counted as a guard doing its job.
expect() {
  local signal="$1" what="$2" file="$3" from="$4" to="$5"

  cp "$file" "$file.bak"
  backups=("$file")

  # A stale anchor and a helper that could not run mean opposite things:
  # the first is a mutation to rewrite, the second says nothing about the
  # guard at all. Reporting the second as the first sends the reader to
  # edit a line that was never wrong. newline= on both ends keeps the
  # mutated file byte-faithful; one file mutated here is a shell script,
  # which rewritten line endings alone would break.
  local applied
  applied=$(python3 - "$file" "$from" "$to" <<'PY'
import pathlib, sys
path, before, after = sys.argv[1], sys.argv[2], sys.argv[3]
p = pathlib.Path(path)
# open() rather than Path.read_text/write_text: the newline keyword
# reached those only in Python 3.13, and hosted runners are older.
with open(p, newline="") as f:
    s = f.read()
if before not in s:
    print("ANCHOR_MISSING")
    sys.exit(0)
with open(p, "w", newline="") as f:
    f.write(s.replace(before, after, 1))
print("APPLIED")
PY
  )
  case "$applied" in
    APPLIED) ;;
    ANCHOR_MISSING)
      printf '  ANCHOR STALE  %s\n' "$what"
      fail=$((fail + 1))
      restore
      return
      ;;
    *)
      printf '  TOOL FAILED   %s\n' "$what"
      printf '                the mutation never applied; nothing learned\n'
      fail=$((fail + 1))
      restore
      return
      ;;
  esac

  local out status
  out=$(eval "$BUILD" 2>&1)
  status=$?
  restore

  if [ $status -eq 0 ]; then
    printf '  NOT CAUGHT    %s\n' "$what"
    fail=$((fail + 1))
    return
  fi

  local msg
  msg=$(printf '%s' "$out" | grep -m1 -o "$signal")
  if [ -z "$msg" ]; then
    # The build failed, but not for the reason this mutation was aimed at.
    # That is not the guard doing its job, and a green count here would be a
    # lie about which guard is load-bearing.
    printf '  WRONG FAILURE %s\n' "$what"
    printf '                expected to see: %s\n' "$signal"
    printf '%s\n' "$out" | tail -5 | sed 's/^/      | /'
    fail=$((fail + 1))
    return
  fi

  printf '  caught        %s\n' "$what"
  printf '                -> %s\n' "$msg"
  pass=$((pass + 1))
}

# A clean tree first: a mutation is only evidence if the unmutated build passes.
if ! $ZIG build test >/dev/null 2>&1; then
  echo "the unmutated build already fails; fix that before reading this script's output"
  exit 1
fi

echo "drift the ABI cross-check must refuse:"

# Two same-sized fields exchanged. `translation` and `scale` are both
# float[3], so the offset SEQUENCE (0, 12, 28) is unchanged and every
# positional check and every offsets-only digest passes this — while every
# joint's position is read as its scale.
try "same-sized fields swapped" src/c.zig \
'pub const Transform = extern struct {
    translation: [3]f32,
    rotation: [4]f32,
    scale: [3]f32,
};' \
'pub const Transform = extern struct {
    scale: [3]f32,
    rotation: [4]f32,
    translation: [3]f32,
};'

# A pointer and the count that follows it, exchanged. Both are eight bytes, so
# the offset SEQUENCE is unchanged again -- and ZozzBlendingLayer is handed to
# ozz as its own BlendingJob::Layer with no copy, so ozz would read a count
# where a pointer belongs. This is the mutation that guards the whole
# reinterpret-instead-of-convert design.
try "a pointer and its count exchanged in a layer" src/c.zig \
'    transform: ?[*]const SoaTransform,
    num_transform: usize,' \
'    num_transform: usize,
    transform: ?[*]const SoaTransform,'

try "a parameter dropped from a function" src/c.zig \
'pub extern fn zozzSkeletonRestPose(skeleton: ?*const Skeleton, out: [*]Transform, count: usize) Result;' \
'pub extern fn zozzSkeletonRestPose(skeleton: ?*const Skeleton, out: [*]Transform) Result;'

try "a parameter widened (f32 -> f64)" src/c.zig \
'pub extern fn zozzSample(animation: *const Animation, context: *SamplingContext, ratio: f32, out: [*]SoaTransform, blocks: usize) Result;' \
'pub extern fn zozzSample(animation: *const Animation, context: *SamplingContext, ratio: f64, out: [*]SoaTransform, blocks: usize) Result;'

try "an enumerator renumbered" src/c.zig \
'    bad_format = 3,' \
'    bad_format = 30,'

try "an enum tag narrowed (c_int -> i8)" src/c.zig \
'pub const Result = enum(c_int) {' \
'pub const Result = enum(i8) {'

try "a constant drifted" src/c.zig \
'pub const no_parent: i16 = -1;' \
'pub const no_parent: i16 = -2;'

# The reverse direction: the header declares something c.zig does not.
try "an extern deleted from c.zig" src/c.zig \
'pub extern fn zozzOzzVersion() u32;' \
''

# The other reverse direction: c.zig is missing a field the header has.
try "a struct field added in the header only" ffi/zozz_core.h \
'typedef struct ZozzAbiLayout {' \
'typedef struct ZozzAbiLayout {
  uint32_t intruder;'

# Signedness, which size and alignment cannot see: same width, same offset,
# same everything a layout digest looks at, and a value above 2^31 read back as
# negative. Mutated on the HEADER side so the Zig suite still type-checks —
# flipping c.zig instead breaks an unrelated test first, which is not evidence
# about this check.
try "a field's signedness flipped in the header" ffi/zozz_core.h \
'  uint32_t transform_size;' \
'  int32_t transform_size;'

# The other half of scalar identity, and the one size and alignment are most
# blind to: a 32-bit integer and a 32-bit float are the same width, the same
# alignment and the same offset, and every bit pattern that crosses means
# something else entirely.
try "a field retyped int -> float in the header" ffi/zozz_core.h \
'  uint32_t float4x4_align;' \
'  float float4x4_align;'

# A negative enumerator is not drift between the two sides — it is drift
# between two toolchains. C leaves an enum's underlying type to the
# implementation, and the choice only stops mattering while every enumerator is
# non-negative. This is the precondition that lets the signedness comparison
# above skip enums, so it has to be enforced, not assumed.
try "a negative enumerator introduced" src/c.zig \
'pub const Result = enum(c_int) {
    ok = 0,' \
'pub const Result = enum(c_int) {
    ok = -1,'

# A Zig helper wearing an exported symbol's name. Both sweeps would let this
# through on their own: the forward sweep skips non-extern functions, and the
# reverse sweep asks only whether the name exists. The extern it displaced
# would be gone with neither direction noticing.
try "an extern replaced by a Zig helper of the same name" src/c.zig \
'pub extern fn zozzAnimationDuration(animation: ?*const Animation) f32;' \
'pub fn zozzAnimationDuration(animation: ?*const Animation) f32 {
    _ = animation;
    return 0;
}'

#-----------------------------------------------------------------------------
# The coverage guard.
#
# `ci/check-coverage.sh` is the answer to "does zozz cover ozz", and it is
# load-bearing in the same way the ABI cross-check is: if it goes vacuous it
# reports full coverage and nobody notices. Before it existed the question was
# answered by reading a name list and guessing, and the name matcher it rests
# on was loose enough that a single shared keyword counted as a match.
#
# The anchors come from tools/unbound_animation_offline.txt, the smallest and
# most settled classification file.
#-----------------------------------------------------------------------------
BUILD='ci/check-coverage.sh'

if ! ci/check-coverage.sh >/dev/null 2>&1; then
  echo
  echo "  SKIPPED       the five coverage mutations"
  echo "                ci/check-coverage.sh already fails, so they would all"
  echo "                report a catch without catching anything. Close the"
  echo "                open names first."
  fail=$((fail + 1))
else

expect 'is not in ffi/\*\.h' \
  "evidence naming an entry point that does not exist" tools/unbound_animation_offline.txt \
  "$(printf 'animation/offline\tSampleAnimation\tBOUND\tzozzRawAnimationSample')" \
  "$(printf 'animation/offline\tSampleAnimation\tBOUND\tzozzRawAnimationSampleAll')"

expect 'not four tab-separated fields' \
  "a line's tabs turned into spaces" tools/unbound_animation_offline.txt \
  "$(printf 'animation/offline\tSampleAnimation\tBOUND\tzozzRawAnimationSample')" \
  'animation/offline  SampleAnimation  BOUND  zozzRawAnimationSample'

expect 'no verdict' \
  "a classified name deleted" tools/unbound_animation_offline.txt \
  "$(printf 'animation/offline\tSampleAnimation\tBOUND\tzozzRawAnimationSample')" \
  "$(printf '#animation/offline\tSampleAnimation\tBOUND\tzozzRawAnimationSample')"

expect 'gap(s)' \
  "a settled name reopened as a gap" tools/unbound_animation_offline.txt \
  "$(printf 'animation/offline\tSampleAnimation\tBOUND\tzozzRawAnimationSample')" \
  "$(printf 'animation/offline\tSampleAnimation\tGAP\t')"

# The enumerator itself. Loosening the name match is the subtle one: it makes
# more names look bound, which shrinks the list the classification has to
# explain and would quietly turn real questions into answered ones. What
# notices is that the lines explaining them become stale.
expect 'stale line' \
  "the name matcher loosened to ignore word order" tools/coverage.sh \
'        k = 1
        for (i = 1; i <= bn[j] && k <= nw; i++) if (b[j, i] == w[k]) k++
        if (k > nw) hit = 1' \
'        k = 0
        for (i = 1; i <= bn[j]; i++) for (m = 1; m <= nw; m++) if (b[j, i] == w[m]) k++
        if (k >= nw) hit = 1'

fi

BUILD="$ZIG build test"

printf '\ncaught: %d   missed: %d\n' "$pass" "$fail"

# ci/measurements.sh publishes how many mutations this file holds by counting
# its `try` and `expect` lines. A declaration inside a branch that did not run
# would make that number overstate the proof; this is what makes it mean "ran".
declared=$(grep -cE '^(try|expect) ' "$SELF")
if [ $fail -eq 0 ] && [ $((pass + fail)) -ne "$declared" ]; then
  printf 'ran %d of %d declared mutations; the published count would overstate it\n' \
    "$((pass + fail))" "$declared"
  exit 1
fi

[ $fail -eq 0 ]
