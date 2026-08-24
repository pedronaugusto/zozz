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
cd "$(dirname "$0")/.."

pass=0
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
try() {
  local what="$1" file="$2" from="$3" to="$4"

  cp "$file" "$file.bak"
  backups=("$file")

  if ! python3 - "$file" "$from" "$to" <<'PY'
import pathlib, sys
path, before, after = sys.argv[1], sys.argv[2], sys.argv[3]
p = pathlib.Path(path)
s = p.read_text()
if before not in s:
    sys.exit("anchor no longer present in %s:\n%s" % (path, before))
p.write_text(s.replace(before, after, 1))
PY
  then
    printf '  ANCHOR STALE  %s\n' "$what"
    fail=$((fail + 1))
    restore
    return
  fi

  local out status
  out=$(zig build test 2>&1)
  status=$?
  restore

  if [ $status -eq 0 ]; then
    printf '  NOT CAUGHT    %s\n' "$what"
    fail=$((fail + 1))
    return
  fi

  local msg
  msg=$(printf '%s' "$out" | grep -m1 -o 'zozz ABI drift: .*')
  if [ -z "$msg" ]; then
    # The build failed, but for some other reason — that is not the check
    # doing its job, and a green count here would be a lie.
    printf '  WRONG FAILURE %s\n' "$what"
    printf '%s\n' "$out" | tail -5 | sed 's/^/      | /'
    fail=$((fail + 1))
    return
  fi

  printf '  caught        %s\n' "$what"
  printf '                -> %s\n' "$msg"
  pass=$((pass + 1))
}

# A clean tree first: a mutation is only evidence if the unmutated build passes.
if ! zig build test >/dev/null 2>&1; then
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

try "a parameter dropped from a function" src/c.zig \
'pub extern fn zozzSkeletonRestPose(skeleton: ?*const Skeleton, out: [*]Transform, count: usize) Result;' \
'pub extern fn zozzSkeletonRestPose(skeleton: ?*const Skeleton, out: [*]Transform) Result;'

try "a parameter widened (f32 -> f64)" src/c.zig \
'pub extern fn zozzSample(animation: *const Animation, context: *SamplingContext, ratio: f32, out: *SoaPose) Result;' \
'pub extern fn zozzSample(animation: *const Animation, context: *SamplingContext, ratio: f64, out: *SoaPose) Result;'

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

printf '\ncaught: %d   missed: %d\n' "$pass" "$fail"
[ $fail -eq 0 ]
