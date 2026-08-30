#!/usr/bin/env bash
#
# zozz — every public function in src/math.zig either faces the compiled ozz in
# src/mathref_test.zig, or is listed in tools/undifferentiated_math.txt with the
# reason it cannot.
#
# src/math.zig is a hand port. Its other tests compare it against itself, which
# cannot detect a transcription that is wrong the same way twice; the
# differential test is the only one that can, so what it does NOT reach is worth
# a name and a reason rather than silence.
#
# What this script counts, and what it does not:
#   * It counts DECLARATIONS, not behaviour. "Covered" means the differential
#     table names the function, on the lanes ozz defines, over the inputs that
#     row's fill produces -- not that every input has been tried.
#   * It reads src/mathref_test.zig lexically, through the container aliases at
#     the top of that file. A row that names a function inside a comment would
#     count; nothing else in the file spells a math.zig name.
#   * It sees `pub fn` only. A `pub const` value -- mat4_identity, the
#     normalization tolerances -- is not a function and is not counted here.

set -uo pipefail
cd "$(dirname "$0")/.."

if [ -t 1 ]; then RED=$'\033[31m'; GREEN=$'\033[32m'; DIM=$'\033[2m'; BOLD=$'\033[1m'; OFF=$'\033[0m'
else RED=; GREEN=; DIM=; BOLD=; OFF=; fi

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
fails=0
fail() { printf '%s%s%s\n' "$RED" "$1" "$OFF" >&2; fails=$((fails + 1)); }

LIST=0
[ "${1:-}" = "--list" ] && LIST=1

#-----------------------------------------------------------------------------
# Every public function src/math.zig declares, as container.name or name.
#-----------------------------------------------------------------------------
awk '
  /^pub const [A-Za-z_][A-Za-z0-9_]* = struct \{/ { container = $3; next }
  /^\};/ { container = "" }
  container != "" && /^[ \t]+pub (inline )?fn / {
    n = $0; sub(/^[ \t]+pub (inline )?fn /, "", n); sub(/[(:].*/, "", n)
    gsub(/@"|"/, "", n); print container "." n; next
  }
  /^pub (inline )?fn / {
    n = $0; sub(/^pub (inline )?fn /, "", n); sub(/[(:].*/, "", n)
    gsub(/@"|"/, "", n); print n
  }
' src/math.zig | sort -u > "$work/declared"

#-----------------------------------------------------------------------------
# Every one the differential table reaches. The aliases are read from the test
# itself, so renaming one there cannot silently shrink this set.
#-----------------------------------------------------------------------------
sed -n 's/^const \([a-z0-9_]*\) = math\.\([a-z0-9_]*\);$/\1 \2/p' src/mathref_test.zig \
  > "$work/aliases"
{
  while read -r alias container; do
    grep -oE "\\b$alias\\.(@\"[A-Za-z_][A-Za-z0-9_]*\"|[A-Za-z_][A-Za-z0-9_]*)" src/mathref_test.zig |
      sed "s/^$alias\\./$container./"
  done < "$work/aliases"
  grep -oE 'math\.[a-z0-9_]+\.(@"[A-Za-z_][A-Za-z0-9_]*"|[A-Za-z_][A-Za-z0-9_]*)' src/mathref_test.zig |
    sed 's/^math\.//'
  grep -oE 'adapt\(math\.[A-Za-z_][A-Za-z0-9_]*\)' src/mathref_test.zig |
    sed 's/^adapt(math\.//; s/)$//'
} | sed 's/@"\([A-Za-z0-9_]*\)"/\1/' | sort -u > "$work/reached"

comm -12 "$work/declared" "$work/reached" > "$work/covered"
comm -23 "$work/declared" "$work/reached" > "$work/uncovered"

#-----------------------------------------------------------------------------
# The verdicts. NAME<TAB>REASON, and a reason has to say something.
#-----------------------------------------------------------------------------
awk -F'\t' '
  /^#/ || !NF { next }
  NF != 2 { printf "  %s: not NAME<TAB>reason\n", $0 > "/dev/stderr"; next }
  length($2) < 20 { printf "  %s: no reason given\n", $1 > "/dev/stderr"; next }
  { print $1 }
' tools/undifferentiated_math.txt 2>"$work/shape" | sort -u > "$work/listed"
if [ -s "$work/shape" ]; then
  cat "$work/shape" >&2
  fail "$(grep -c . "$work/shape") malformed line(s) in tools/undifferentiated_math.txt"
fi

comm -23 "$work/uncovered" "$work/listed" > "$work/gaps"
if [ -s "$work/gaps" ]; then
  sed 's/^/  /' "$work/gaps" >&2
  fail "$(grep -c . "$work/gaps") function(s) neither differentially tested nor explained"
fi

comm -12 "$work/covered" "$work/listed" > "$work/stale"
if [ -s "$work/stale" ]; then
  sed 's/^/  /' "$work/stale" >&2
  fail "$(grep -c . "$work/stale") stale line(s) — these ARE tested now; delete them"
fi

comm -13 "$work/declared" "$work/listed" > "$work/phantom"
if [ -s "$work/phantom" ]; then
  sed 's/^/  /' "$work/phantom" >&2
  fail "$(grep -c . "$work/phantom") line(s) naming no public function in src/math.zig"
fi

#-----------------------------------------------------------------------------
# Summary.
#-----------------------------------------------------------------------------
if [ "$LIST" -eq 1 ] && [ -s "$work/uncovered" ]; then
  printf '%snot differentially tested%s\n' "$BOLD" "$OFF"
  while read -r name; do
    printf '  %-28s %s\n' "$name" "$(awk -F'\t' -v n="$name" '$1 == n { print $2 }' tools/undifferentiated_math.txt)"
  done < "$work/uncovered"
  printf '\n'
fi

printf '%szozz differential maths coverage%s\n' "$BOLD" "$OFF"
printf '  %-34s %5d\n' 'public functions in src/math.zig' "$(grep -c . "$work/declared")"
printf '  %-34s %5d  %sfaced against compiled ozz%s\n' '  covered' "$(grep -c . "$work/covered")" "$DIM" "$OFF"
printf '  %-34s %5d  %swith a reason on record%s\n' '  explained' "$(grep -c . "$work/uncovered")" "$DIM" "$OFF"

if [ "$fails" -ne 0 ]; then
  printf '\n%sFAIL%s  %d problem(s)\n' "$RED" "$OFF" "$fails" >&2
  exit 1
fi
printf '\n%sOK%s  every public maths function is tested against ozz or explained\n' "$GREEN" "$OFF"
