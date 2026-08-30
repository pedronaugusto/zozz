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
#   tools/coverage.sh --names            # AREA<TAB>NAME for every unbound
#                                        # name, nothing else — the input to
#                                        # ci/check-coverage.sh

set -uo pipefail
cd "$(dirname "$0")/.."

OZZ=libs/ozz/include/ozz

# Every directory ozz has. `NAME:DEPTH` limits the walk where a directory has
# subdirectories claimed as areas of their own. ci/check-coverage.sh fails if a
# directory under libs/ozz/include/ozz is not covered by this list.
AREAS=".:1 base:1 base/containers base/encode base/io base/maths base/memory animation:1 animation/runtime animation/offline geometry:1 geometry/runtime options"

[ "${1:-}" = "--areas" ] && { printf '%s\n' $AREAS; exit 0; }
FILTER="${1:-}"
NAMES=0
[ "$FILTER" = "--names" ] && { NAMES=1; FILTER=; }

if [ -t 1 ] && [ "$NAMES" -eq 0 ]
then B=$'\033[1m'; D=$'\033[2m'; G=$'\033[32m'; Y=$'\033[33m'; O=$'\033[0m'
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
# Kept in their original casing: the matcher below splits both sides at their
# camelCase boundaries, so lowercasing here would erase the word boundaries it
# depends on.
bound=$(grep -ho 'zozz[A-Za-z0-9_]*(' ffi/*.h |
        grep -o 'zozz[A-Za-z0-9_]*' | sort -u)

# The ozz types this package hands a caller: a C struct or handle named
# Zozz<T>, or a Zig type re-exported from src/math.zig. It decides which C++
# operators below are reported -- an operator on a type nobody can obtain is
# not a capability this binding is missing, and the type itself is the
# question in that case, not its arithmetic.
exposed=$(
  { grep -hoE 'Zozz[A-Za-z0-9_]+' ffi/*.h | sed 's/^Zozz//'
    grep -oE '^pub const [A-Z][A-Za-z0-9_]*' src/math.zig | awk '{ print $3 }'
  } | sort -u)

# Public names ozz declares in one directory: methods, and — unlike a
# class-only API — free functions declared straight in a namespace, which is
# most of what base/maths is. gtest_*.h headers are ozz's own test-assertion
# helpers, shipped next to the maths headers but never part of the library.
ozz_methods() {
  dir=$OZZ; [ "$1" != "." ] && dir="$OZZ/$1"
  find "$dir" -maxdepth "${2:-99}" -name '*.h' -not -name 'gtest_*' 2>/dev/null -print0 |
  xargs -0 awk -v exposed="$exposed" '
    BEGIN { split(exposed, e, "\n"); for (i in e) is_exposed[e[i]] = 1 }
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
    # A /* */ block full of prose can hold a word followed by a paren that
    # reads exactly like a declaration. But a real declaration can also carry
    # a comment on its own line, so a line cannot simply be skipped for
    # containing one. Strip the comment spans and keep what is left.
    {
      line = $0
      if (in_comment) {
        p = index(line, "*/")
        if (p == 0) next
        line = substr(line, p + 2); in_comment = 0
      }
      while ((a = index(line, "/*")) > 0) {
        rest = substr(line, a + 2)
        b = index(rest, "*/")
        if (b == 0) { line = substr(line, 1, a - 1); in_comment = 1; break }
        line = substr(line, 1, a - 1) substr(rest, b + 2)
      }
      $0 = line
    }
    /OZZ_ASSERT|^[[:space:]]*\/\// { next }
    # Operators, qualified by the type they act on. A C ABI cannot export one,
    # but the arithmetic they carry is most of base/maths, and skipping them
    # left this blind to the whole surface: Float4x4 * Float4x4 was missing
    # for three releases with nothing to say so. Float4x4::operator* and
    # SimdFloat4::operator* are separate capabilities and get separate lines.
    # An indented declaration is a member and takes its class; one at column
    # zero is a free function and takes the type of its first parameter.
    /operator[^A-Za-z0-9_ ]/ {
      if (!match($0, /operator(\(\)|\[\]|[^A-Za-z0-9_ ()[]+)[[:space:]]*\(/)) next
      sym = substr($0, RSTART, RLENGTH)
      sub(/[[:space:]]*\($/, "", sym)
      # Assignment is C++ value semantics for a type this ABI hands out by
      # pointer only. There is nothing for a binding to deliver.
      if (sym == "operator=") next
      if ($0 ~ /^[[:space:]]/) type = cls
      else {
        rest = substr($0, RSTART + RLENGTH)
        sub(/^[[:space:]]*/, "", rest)
        sub(/^(const|volatile)[[:space:]]+/, "", rest)
        type = ""
        if (match(rest, /^[A-Za-z_][A-Za-z0-9_:]*/)) {
          type = substr(rest, RSTART, RLENGTH)
          sub(/^.*::/, "", type)
          sub(/^_/, "", type)
        }
      }
      if (type == "" || !(type in is_exposed)) next
      print type "::" sym
      next
    }
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

# Match a batch of upstream names against `bound` in one awk pass.
#
# Both names are split into words at their camelCase boundaries and at
# underscores, and the upstream name matches when its words appear as an
# ordered subsequence of the entry point's words. Whole words, not substrings,
# and in order. ozz names in snake_case (`joint_parents`) or CamelCase
# (`SampleAnimation`) and zozz's entry points are camelCase with no underscore,
# so the words are what carry across.
#
# Each half of that rule was learned from a real failure:
#
#   * Order. An earlier rule dropped every word shorter than four characters
#     and ignored order, which let a name reduce to one common keyword and call
#     itself covered.
#   * Whole words. Comparing lowercase substrings makes short names collide
#     with the insides of long ones: ozz's `Tan` "matched"
#     `zozzIArchiveTestAnimation`, because t-a-n appears inside it, and a real
#     name silently left the work list as covered. A false bound is the
#     dangerous direction — an unbound name is a question someone has to
#     answer, a falsely bound one is a question nobody is ever asked.
#
# The cost is that a deliberate rename reads as unbound —
# `GetJointRestPoseLocalSpace` against `zozzSkeletonJointRestPoseLocal`. That
# is the right trade, because `tools/unbound_*.txt` has to answer for every
# name this prints and `ci/check-coverage.sh` checks that the entry point each
# answer names really exists.
#
# One awk pass rather than the obvious nested shell loops, which spawned a
# subprocess per comparison and took eight seconds for a run CI makes on every
# push.
match_names() {
  awk '
    function split_words(m, out,   i, c, p) {
      s = ""
      for (i = 1; i <= length(m); i++) {
        c = substr(m, i, 1)
        p = (i > 1) ? substr(m, i - 1, 1) : ""
        if (c == "_") { s = s " "; continue }
        if (c ~ /[A-Z]/ && p ~ /[a-z0-9]/) s = s " "
        s = s c
      }
      return split(tolower(s), out, / +/)
    }
    NR == FNR { if (NF) { nb++; bn[nb] = split_words($0, bw); for (i = 1; i <= bn[nb]; i++) b[nb, i] = bw[i] } ; next }
    !NF { next }
    {
      nw = split_words($0, w)
      hit = 0
      for (j = 1; j <= nb && !hit; j++) {
        k = 1
        for (i = 1; i <= bn[j] && k <= nw; i++) if (b[j, i] == w[k]) k++
        if (k > nw) hit = 1
      }
      if (!hit) print
    }
  ' "$1" -
}

boundfile=$(mktemp); trap 'rm -f "$boundfile"' EXIT
printf '%s\n' "$bound" > "$boundfile"

if [ "$NAMES" -eq 0 ]; then
  printf '%szozz coverage of ozz%s  %s(by name; a work list, not a score)%s\n\n' \
    "$B" "$O" "$D" "$O"
  printf '  %-34s %8s %8s %6s\n' "area" "bound" "public" "cover"
fi

total_b=0; total_p=0
# Every directory ozz has. Nothing is excluded: an area left out of this list
# is a place a capability can hide where no check in this repo would ever look.
# The five-area list this replaced was doing exactly that to base/memory, which
# is where ozz's allocator seam lives, and to base/log.
#
# `NAME:DEPTH` limits the walk, for the parents whose children are claimed as
# areas of their own and would otherwise be counted twice.
for spec in $AREAS
do
  area=${spec%%:*}
  depth=${spec#*:}; [ "$depth" = "$area" ] && depth=99
  dir=$OZZ; [ "$area" != "." ] && dir="$OZZ/$area"
  [ -d "$dir" ] || continue
  methods=$(ozz_methods "$area" "$depth")
  [ -z "$methods" ] && continue

  unbound=$(printf '%s\n' "$methods" | match_names "$boundfile")
  p=$(printf '%s\n' "$methods" | grep -c .)
  u=$(printf '%s\n' "$unbound" | grep -c .)
  b=$((p - u))

  label=$area; [ "$label" = "." ] && label="ozz (root headers)"
  if [ "$NAMES" -eq 1 ]; then
    printf '%s\n' "$unbound" | grep . | sed "s|^|$label	|"
  else
    pct=$(( p == 0 ? 0 : b * 100 / p ))
    colour=$Y; [ $pct -ge 70 ] && colour=$G
    printf '  %-34s %8d %8d %s%5d%%%s\n' "$label" "$b" "$p" "$colour" "$pct" "$O"
    if [ -n "$FILTER" ] && printf '%s' "$label" | grep -qi "$FILTER"; then
      printf '%s\n' "$unbound" | grep . | sed 's/^/      /' | head -60
      [ "$u" -gt 60 ] && printf '      %s... %d more%s\n' "$D" "$((u - 60))" "$O"
    fi
  fi
  total_b=$((total_b + b)); total_p=$((total_p + p))
done

[ "$NAMES" -eq 1 ] && exit 0

printf '\n  %-34s %8d %8d %5d%%\n' "TOTAL" "$total_b" "$total_p" \
  "$(( total_p == 0 ? 0 : total_b * 100 / total_p ))"
printf '\n  %sentry points exported: %s%s\n' "$D" \
  "$(printf '%s\n' "$bound" | grep -c .)" "$O"
printf '  %sname matching is naive; %s says what each unbound name really is%s\n' \
  "$D" "ci/check-coverage.sh" "$O"
printf '  %spass an area name to list what is unbound there%s\n' "$D" "$O"
