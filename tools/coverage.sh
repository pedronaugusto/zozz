#!/usr/bin/env bash
#
# zozz — what of ozz is bound, and what is not.
#
# "How much of the library do we cover" was being answered by estimate, which
# is worth nothing when the answer decides what to work on next. This answers
# it by enumeration: every public name ozz declares in the areas this ABI
# claims, matched against every entry point zozz exports, with the unmatched
# ones listed by name.
#
# The matching is by NAME, deliberately naively: an ozz method `set_position`
# is considered bound if some `zozz*SetPosition*` exists. That over-counts (an
# entry point may bind an unrelated method of the same name) and under-counts
# (a deliberate rename hides a real binding). Neither matters for what this is
# for, which is producing a work list rather than a score. Every line it
# prints is a name you can grep for.
#
# Not everything unbound should be bound. ozz has names that exist for its own
# internals — SIMD backends, template machinery, the offline command-line
# tools' option parser — most of which must never cross a C boundary at all.
# Read the list; do not work it blindly.
#
# Usage:
#   tools/coverage.sh                    # summary per area
#   tools/coverage.sh runtime            # and the unbound names in that area

set -uo pipefail
cd "$(dirname "$0")/.."

OZZ=libs/ozz/include/ozz
FILTER="${1:-}"

if [ -t 1 ]; then B=$'\033[1m'; D=$'\033[2m'; G=$'\033[32m'; Y=$'\033[33m'; O=$'\033[0m'
else B=; D=; G=; Y=; O=; fi

# Every name zozz exports, lowercased, one per line. A declaration's name and
# its opening paren can land on different lines when the return type wraps
# (`ZOZZ_API size_t\nzozzFoo(...)`), so this matches the name+paren directly
# rather than anchoring on ZOZZ_API and the return type between it and the
# name — a return type with a digit in it (int16_t, uint32_t, ...) would
# otherwise fall out of an [A-Za-z_ *]-only character class. Doc-comment
# mentions of a real entry point (`zozzFoo(...)` inside a `///` usage
# example) match too, harmlessly: they name a function that is also declared
# for real elsewhere in the same header.
bound=$(grep -ho 'zozz[A-Za-z0-9_]*(' ffi/*.h |
        grep -o 'zozz[A-Za-z0-9_]*' | tr 'A-Z' 'a-z' | sort -u)

# Public names ozz declares in one directory: methods, and — unlike a
# class-only API — free functions declared straight in a namespace, which is
# most of what base/maths is. gtest_*.h headers are ozz's own test-assertion
# helpers, shipped next to the maths headers but never part of the library.
ozz_methods() {
  find "$OZZ/$1" -maxdepth 1 -name '*.h' -not -name 'gtest_*' 2>/dev/null -print0 | xargs -0 awk '
    # A new file starts public: namespace scope has no access specifier, so
    # top-level declarations (most of base/maths) are public by default.
    # Reset per file rather than carrying state across the xargs batch.
    FNR == 1 { pub = 1; cls = "" }
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*(private|protected):/ { pub = 0; next }
    /^[[:space:]]*public:/              { pub = 1; next }
    /^[[:space:]]*(class|struct)[[:space:]]/ {
      # A `class` defaults its members to private until a `public:` label,
      # which this does not distinguish from `struct` (defaults public) —
      # both flip pub on immediately. Good enough for a work list; remember
      # the class name so its constructor/destructor line, which repeats it,
      # is not counted as a distinct method below.
      pub = 1
      if (match($0, /(class|struct)[[:space:]]+([A-Za-z_][A-Za-z0-9_]*[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*/)) {
        n = split(substr($0, RSTART, RLENGTH), parts, /[[:space:]]+/)
        cls = parts[n]
      }
    }
    !pub { next }
    /OZZ_ASSERT|^[[:space:]]*\/\// { next }
    match($0, /[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(/) {
      # Skip `obj.name(` / `obj->name(` / `ns::name(` — a call on something
      # else, not a declaration belonging to this area.
      pre = (RSTART > 1) ? substr($0, RSTART - 1, 1) : ""
      if (pre == "." || pre == ">" || pre == ":") next
      name = substr($0, RSTART, RLENGTH - 1)
      gsub(/[[:space:]()]/, "", name)
      if (name == cls) next
      # ozz names parameters and template arguments with a leading or
      # trailing underscore (`_fct`, `_Ty`) and private members with a
      # trailing one (`duration_`) — never a real public name.
      if (name ~ /^_|_$/) next
      if (name ~ /^(if|for|while|switch|return|sizeof|alignof|static_assert|assert|do|else|catch|new|delete|defined)$/) next
      # Operators and macros are not candidates to bind: an operator has no
      # name a C ABI can carry, and OZZ_ macros expand to asserts, versioning
      # and other plumbing rather than declaring a name.
      if (name ~ /^(operator|OZZ_)/) next
      # A name that is all caps is a macro invocation, not a method.
      if (name ~ /^[A-Z0-9_]+$/) next
      # ozz leans on three-letter names for exactly the ones that matter most
      # here — every job type is driven through `Run()`. A length-4 floor,
      # tuned for a PascalCase API, would silently drop it.
      if (length(name) < 3) next
      print name
    }
  ' 2>/dev/null | sort -u
}

printf '%szozz coverage of ozz%s  %s(by name; a work list, not a score)%s\n\n' \
  "$B" "$O" "$D" "$O"
printf '  %-34s %8s %8s %6s\n' "area" "bound" "public" "cover"

total_b=0; total_p=0
# base/containers, base/memory, base/encode and base/maths/internal are
# deliberately absent. They are ozz's internal value and container types —
# vector, string, the allocator, the SIMD backend picked per platform — and
# none of them crosses a C boundary: zozz declares its own flat PODs and jobs
# for the few concepts a caller needs. animation/offline/fbx,
# animation/offline/tools and options are deliberately absent too: they back
# the standalone fbx2ozz/gltf2ozz command-line converters, and zozz does not
# vendor a single translation unit from any of the three. Scoring any of
# these would put a permanent, meaningless dent in the total and hide the
# areas that matter.
for area in animation/runtime animation/offline geometry/runtime \
            base/maths base/io
do
  [ -d "$OZZ/$area" ] || continue
  methods=$(ozz_methods "$area")
  [ -z "$methods" ] && continue

  p=0; b=0; unbound=""
  while IFS= read -r m; do
    [ -z "$m" ] && continue
    p=$((p + 1))
    # ozz names in snake_case (joint_parents); zozz's entry points are
    # camelCase with no underscore at all (zozzSkeletonJointParent). Strip
    # the underscore before comparing, or it blocks every match by itself.
    needle=$(printf '%s' "$m" | tr 'A-Z' 'a-z' | tr -d '_')
    if printf '%s\n' "$bound" | grep -q "$needle"; then
      b=$((b + 1))
    else
      unbound="$unbound$m"$'\n'
    fi
  done <<< "$methods"

  pct=$(( p == 0 ? 0 : b * 100 / p ))
  colour=$Y; [ $pct -ge 70 ] && colour=$G
  printf '  %-34s %8d %8d %s%5d%%%s\n' "$area" "$b" "$p" "$colour" "$pct" "$O"
  total_b=$((total_b + b)); total_p=$((total_p + p))

  if [ -n "$FILTER" ] && printf '%s' "$area" | grep -qi "$FILTER"; then
    printf '%s' "$unbound" | grep -v '^$' | sed 's/^/      /' | head -60
    n=$(printf '%s' "$unbound" | grep -vc '^$')
    [ "$n" -gt 60 ] && printf '      %s... %d more%s\n' "$D" "$((n - 60))" "$O"
  fi
done

printf '\n  %-34s %8d %8d %5d%%\n' "TOTAL" "$total_b" "$total_p" \
  "$(( total_p == 0 ? 0 : total_b * 100 / total_p ))"
printf '\n  %sentry points exported: %s%s\n' "$D" \
  "$(printf '%s\n' "$bound" | grep -c .)" "$O"
printf '  %spass an area name to list what is unbound there%s\n' "$D" "$O"
