#!/usr/bin/env bash
#
# zozz — every public ozz name in the areas this ABI claims has a verdict,
# and every verdict is checkable.
#
#   tools/coverage.sh --names   lists the names no entry point spells out.
#   tools/unbound_*.txt         gives each one AREA<TAB>NAME<TAB>VERDICT<TAB>EVIDENCE,
#                               keyed by area so a name that is bound in one
#                               place cannot vouch for it in another.
#   tools/classify.sh           computes which exclusions upstream justifies.
#
# INTERNAL is not something this file takes on trust: it is recomputed here and
# rejected unless classify.sh proves it. GAP fails the build.

set -uo pipefail
cd "$(dirname "$0")/.."

LIST=0
[ "${1:-}" = "--list" ] && LIST=1

if [ -t 1 ]; then RED=$'\033[31m'; GREEN=$'\033[32m'; DIM=$'\033[2m'; BOLD=$'\033[1m'; OFF=$'\033[0m'
else RED=; GREEN=; DIM=; BOLD=; OFF=; fi

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
fails=0
fail() { printf '%s%s%s\n' "$RED" "$1" "$OFF" >&2; fails=$((fails + 1)); }

# Every identifier ffi/*.h declares or mentions — types and enum constants as
# well as functions. A lowercase token carrying an underscore is a header
# filename, not a symbol.
grep -hoE '\b(zozz|Zozz|ZOZZ_)[A-Za-z0-9_]*' ffi/*.h |
  grep -vE '^zozz[a-z0-9]*_' | sort -u > "$work/syms"

tools/coverage.sh --names | sort -u > "$work/unbound"
tools/classify.sh | sort -t$'\t' -k1,1 > "$work/provable"

#-----------------------------------------------------------------------------
# Claimed areas. A directory missing from tools/coverage.sh is a place a
# capability can hide where nothing here would ever look, so a re-vendor that
# adds one fails until the list catches up.
#-----------------------------------------------------------------------------
find libs/ozz/include/ozz -mindepth 1 -type d |
  sed 's|libs/ozz/include/ozz/||' | sort -u > "$work/dirs"
# A directory is claimed when it is listed, or when an ancestor is listed with
# no depth limit.
tools/coverage.sh --areas > "$work/specs"
: > "$work/claimed"
while read -r d; do
  ok=0
  while read -r spec; do
    a=${spec%%:*}; depth=${spec#*:}; [ "$depth" = "$a" ] && depth=99
    [ "$a" = "." ] && continue
    if [ "$d" = "$a" ] || { [ "$depth" = 99 ] && case "$d" in "$a"/*) true;; *) false;; esac; }; then
      ok=1; break
    fi
  done < "$work/specs"
  [ "$ok" -eq 1 ] && printf '%s\n' "$d" >> "$work/claimed"
done < "$work/dirs"
sort -u -o "$work/claimed" "$work/claimed"
comm -23 "$work/dirs" "$work/claimed" > "$work/unclaimed"
if [ -s "$work/unclaimed" ]; then
  sed 's/^/  /' "$work/unclaimed" >&2
  fail "$(grep -c . "$work/unclaimed") ozz directory(ies) missing from tools/coverage.sh"
fi

#-----------------------------------------------------------------------------
# Shape.
#-----------------------------------------------------------------------------
for f in tools/unbound_*.txt; do
  awk -F'\t' -v F="$f" '
    /^#/ || !NF { next }
    NF != 4 { printf "%s:%d: not four tab-separated fields\n", F, FNR > "/dev/stderr"; next }
    $3 !~ /^(BOUND|EXTENSION|LANGUAGE|ZIG|INTERNAL|GAP)$/ {
      printf "%s:%d: unknown verdict %s\n", F, FNR, $3 > "/dev/stderr"; next }
    $3 != "GAP" && length($4) < 8 {
      printf "%s:%d: %s has no evidence\n", F, FNR, $2 > "/dev/stderr"; next }
    { print $1 "\t" $2 "\t" $3 "\t" $4 }
  ' "$f" 2>>"$work/shape" >> "$work/rows"
done
if [ -s "$work/shape" ]; then cat "$work/shape" >&2; fail "$(grep -c . "$work/shape") malformed line(s)"; fi

#-----------------------------------------------------------------------------
# Completeness.
#-----------------------------------------------------------------------------
cut -f1,2 "$work/rows" | sort -u > "$work/classified"
comm -23 "$work/unbound" "$work/classified" > "$work/missing"
if [ -s "$work/missing" ]; then
  sed 's/^/  /' "$work/missing" >&2
  fail "$(grep -c . "$work/missing") area/name pair(s) with no verdict"
fi
comm -13 "$work/unbound" "$work/classified" > "$work/stale"
if [ -s "$work/stale" ]; then
  sed 's/^/  /' "$work/stale" >&2
  fail "$(grep -c . "$work/stale") stale line(s) — an entry point now spells these out; delete them"
fi

#-----------------------------------------------------------------------------
# Evidence, one rule per verdict.
#-----------------------------------------------------------------------------
cat > "$work/facilities" <<'EOF'
@Vector
@shuffle
@reduce
@splat
@select
@bitCast
@ptrCast
@floatCast
@intCast
@as
@clz
@ctz
@popCount
@min
@max
@abs
@sqrt
@mulAdd
@byteSwap
@atomicRmw
@prefetch
std.math
std.mem
std.sort
std.ArrayList
std.HashMap
std.AutoHashMap
std.PriorityQueue
std.hash
std.Thread
std.heap
std.fmt
std.ascii
EOF

awk -F'\t' '
  FILENAME ~ /syms$/       { sym[$0] = 1; syms[++ns] = $0; next }
  FILENAME ~ /facilities$/ { fac[++nf] = $0; next }
  FILENAME ~ /provable$/   { prov[$1] = $3; next }
  { name = $2; verdict = $3; evidence = $4 }

  verdict == "BOUND" || verdict == "EXTENSION" {
    n = 0; s = evidence
    while (match(s, /(zozz|Zozz|ZOZZ_)[A-Za-z0-9_]*/)) {
      t = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH)
      if (t ~ /^zozz[a-z0-9]*_/) continue
      n++
      if (substr(s, 1, 1) == "*") {
        s = substr(s, 2); ok = 0
        for (i = 1; i <= ns && !ok; i++) if (index(syms[i], t) == 1) ok = 1
        if (!ok) printf "  %s: nothing in ffi/*.h starts with %s\n", name, t > "/dev/stderr"
        continue
      }
      if (!(t in sym)) printf "  %s: %s is not in ffi/*.h\n", name, t > "/dev/stderr"
    }
    if (n == 0) printf "  %s: %s names no zozz symbol\n", name, verdict > "/dev/stderr"
    next
  }

  # LANGUAGE names a Zig facility from a closed list; every @builtin or std.
  # token it uses has to be on that list, so it cannot become a dumping ground.
  verdict == "LANGUAGE" {
    hit = 0; s = evidence
    while (match(s, /(@[A-Za-z]+|std\.[A-Za-z.]+)/)) {
      t = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH)
      ok = 0
      for (i = 1; i <= nf; i++) if (index(t, fac[i]) == 1) { ok = 1; break }
      if (!ok) printf "  %s: %s is not a facility this file recognises\n", name, t > "/dev/stderr"
      else hit = 1
    }
    if (!hit && evidence !~ /Zig slices|defer/)
      printf "  %s: LANGUAGE names no facility\n", name > "/dev/stderr"
    next
  }

  # ZIG points at one or more declarations in src/, checked below. More than
  # one because an upstream name can be overloaded -- ozz declares three
  # TransformVector -- and one Zig decl per overload is the honest answer.
  # `mat4.mul` names the decl inside a container, which is what tells
  # `quaternion.mul` and `mat4.mul` apart.
  verdict == "ZIG" {
    n = 0
    split(evidence, refs, /[ \t]+/)
    for (i in refs) {
      if (refs[i] == "") continue
      if (refs[i] !~ /^src\/[A-Za-z0-9_]+\.zig:([A-Za-z_][A-Za-z0-9_]*\.)?([A-Za-z_][A-Za-z0-9_]*|@"[A-Za-z_][A-Za-z0-9_]*")$/) {
        printf "  %s: %s is not src/FILE.zig:decl or src/FILE.zig:container.decl\n",
          name, refs[i] > "/dev/stderr"
        n = -1000
        continue
      }
      n++
      print name "\t" refs[i] > "/dev/stdout"
    }
    if (n == 0) printf "  %s: ZIG names no declaration\n", name > "/dev/stderr"
    next
  }

  # INTERNAL is recomputed, never taken on trust.
  verdict == "INTERNAL" {
    if (!(name in prov))
      printf "  %s: INTERNAL, but tools/classify.sh cannot justify it\n", name > "/dev/stderr"
    else if (evidence != prov[name])
      printf "  %s: INTERNAL evidence does not match what classify.sh computes\n", name > "/dev/stderr"
    next
  }
' "$work/syms" "$work/facilities" "$work/provable" "$work/rows" \
  2>"$work/evidence" > "$work/zigrefs"
if [ -s "$work/evidence" ]; then
  cat "$work/evidence" >&2
  fail "$(grep -c . "$work/evidence") unusable piece(s) of evidence"
fi

while IFS=$'\t' read -r name ref; do
  file=${ref%%:*}; decl=${ref#*:}
  [ -f "$file" ] || { printf '  %s: %s does not exist\n' "$name" "$file" >&2; continue; }
  # container.decl: the declaration has to be inside that container, or
  # `mat4.mul` would be satisfied by `quaternion.mul` -- the ambiguity this
  # spelling exists to remove.
  case "$decl" in
  *.*)
    awk -v c="${decl%%.*}" -v m="${decl#*.}" '
      $0 ~ "^pub const " c " = struct \\{" { inside = 1; next }
      inside && /^\};/ { inside = 0 }
      inside && $0 ~ "^[[:space:]]+pub (fn|const|inline fn) " m "([(:]| =)" { found = 1 }
      END { exit !found }' "$file" ||
      printf '  %s: %s declares no %s inside %s\n' \
        "$name" "$file" "${decl#*.}" "${decl%%.*}" >&2
    ;;
  *)
    grep -qF "pub fn $decl(" "$file" ||
      grep -qE "^[[:space:]]*pub (fn|const|inline fn) $decl\b" "$file" ||
      printf '  %s: %s declares no %s\n' "$name" "$file" "$decl" >&2
    ;;
  esac
done < "$work/zigrefs" 2>&1 >/dev/null | tee "$work/zigmiss" >&2
[ -s "$work/zigmiss" ] && fail "$(grep -c . "$work/zigmiss") ZIG line(s) pointing at nothing"

#-----------------------------------------------------------------------------
# The Zig surface. An entry point declared in C and never wrapped is
# unreachable for a Zig host, and nothing above can see it. src/c/ and c.zig
# are the extern layer; tests do not count as use.
#-----------------------------------------------------------------------------
grep -ho 'zozz[A-Za-z0-9_]*(' ffi/*.h | grep -o 'zozz[A-Za-z0-9_]*' | sort -u > "$work/entrypoints"
find src -name '*.zig' ! -path 'src/c/*' ! -name 'c.zig' \
     ! -name '*_test.zig' ! -name '*_sweep*.zig' -print0 |
  xargs -0 grep -ho 'zozz[A-Za-z0-9_]*' | sort -u > "$work/wrapped"
awk -F'\t' '/^#/ || !NF { next }
  NF != 2 { printf "  %s: not NAME<TAB>reason\n", $1 > "/dev/stderr"; next }
  length($2) < 10 { printf "  %s: no reason given\n", $1 > "/dev/stderr"; next }
  { print $1 }' tools/zig_surface_exceptions.txt 2>"$work/exc_shape" | sort -u > "$work/excused"
if [ -s "$work/exc_shape" ]; then cat "$work/exc_shape" >&2; fail "$(grep -c . "$work/exc_shape") malformed exception line(s)"; fi

comm -23 "$work/entrypoints" "$work/wrapped" > "$work/unwrapped"
comm -23 "$work/unwrapped" "$work/excused" > "$work/stranded"
if [ -s "$work/stranded" ]; then
  sed 's/^/  /' "$work/stranded" >&2
  fail "$(grep -c . "$work/stranded") entry point(s) with no Zig caller"
fi
comm -13 "$work/unwrapped" "$work/excused" > "$work/excess"
if [ -s "$work/excess" ]; then
  sed 's/^/  /' "$work/excess" >&2
  fail "$(grep -c . "$work/excess") excused entry point(s) that Zig does call, or that no longer exist"
fi

#-----------------------------------------------------------------------------
# Summary.
#-----------------------------------------------------------------------------
awk -F'\t' '$3 == "GAP"' "$work/rows" > "$work/open"
if [ "$LIST" -eq 1 ] && [ -s "$work/open" ]; then
  printf '%sgaps%s\n' "$BOLD" "$OFF"
  awk -F'\t' '{ printf "%s\t%s\n", $1, $2 }' "$work/open" | sort | column -t -s$'\t' >&2
  printf '\n'
fi

entry_points=$(grep -c . "$work/entrypoints")
read -r spelled public <<<"$(tools/coverage.sh | awk '/^  TOTAL/{print $2, $3}')"
printf '%szozz coverage%s\n' "$BOLD" "$OFF"
printf '  %-30s %5d\n' 'entry points exported' "$entry_points"
printf '  %-30s %5d\n' 'public ozz names, claimed areas' "$public"
printf '  %-30s %5d  %sspelled out by an entry point%s\n' '  matched' "$spelled" "$DIM" "$OFF"
awk -F'\t' '{ c[$3]++ } END { for (v in c) printf "    %-28s %5d\n", tolower(v), c[v] }' "$work/rows" | sort

if [ -s "$work/open" ]; then
  fail "$(grep -c . "$work/open") gap(s) — run with --list to see them"
fi
if [ "$fails" -ne 0 ]; then
  printf '\n%sFAIL%s  %d problem(s)\n' "$RED" "$OFF" "$fails" >&2
  exit 1
fi
printf '\n%sOK%s  every public name in the claimed areas is accounted for\n' "$GREEN" "$OFF"
