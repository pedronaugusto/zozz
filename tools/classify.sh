#!/usr/bin/env bash
#
# zozz — the verdict for every unbound ozz name that can be computed.
#
# The rule: an exclusion is legitimate only when upstream marks the name
# internal, when it has no public declaration, or when the only headers that
# declare it are backed by sources build.zig does not compile — the FBX and
# glTF importers and the command-line option parser, which need third-party
# libraries this package does not vendor. Everything else is a binding, a Zig
# facility, or a gap. No judgement enters here.
#
#   tools/classify.sh          NAME<TAB>INTERNAL<TAB>evidence — provable only
#   tools/classify.sh --open   the names it cannot justify, one per line

set -uo pipefail
cd "$(dirname "$0")/.."

OZZ=libs/ozz/include/ozz
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT

tools/coverage.sh --names | cut -f2 | sort -u > "$t/unbound"

find "$OZZ" -name '*.h' -print0 | xargs -0 awk -f tools/ozz_internal.awk 2>/dev/null |
  sort -u | awk -F'\t' '!seen[$1]++' > "$t/marked"

find "$OZZ" -name '*.h' -print0 | xargs -0 awk -f tools/ozz_access.awk 2>/dev/null |
  awk -F'\t' '$2 == "public" { print $1 }' | sort -u > "$t/public"

# Which headers this build can actually reach. A header is unreachable when its
# own .cc is not in build.zig's source list, when its directory has sources and
# none of them are compiled (ozz/options, the import tools), or when no source
# directory was vendored for it at all (the FBX importer, which needs a
# proprietary SDK).
grep -oE '"libs/ozz/src/[A-Za-z0-9_/.]+\.cc"' build.zig | tr -d '"' | sort -u > "$t/compiled"
find "$OZZ" -name '*.h' | while read -r h; do
  rel=${h#"$OZZ"/}
  dir="libs/ozz/src/$(dirname "$rel")"
  cc="libs/ozz/src/${rel%.h}.cc"
  reason=
  if [ -f "$cc" ] && ! grep -qx "$cc" "$t/compiled"; then
    reason=$cc
  elif [ ! -d "$dir" ]; then
    reason="no source directory vendored for $(dirname "$rel")"
  else
    n=$(find "$dir" -maxdepth 1 -name '*.cc' | wc -l | tr -d ' ')
    if [ "$n" -gt 0 ] && ! find "$dir" -maxdepth 1 -name '*.cc' | sort -u |
         comm -12 - "$t/compiled" | grep -q .; then
      reason="nothing in $dir"
    fi
  fi
  [ -n "$reason" ] && printf '%s\t%s\n' "$h" "$reason"
done > "$t/uncompiled"

# NAME<TAB>HEADER for every declaration, so a name can be tested for having no
# declaration outside the unreachable headers.
find "$OZZ" -name '*.h' | while read -r h; do
  awk -f tools/ozz_access.awk "$h" 2>/dev/null | awk -F'\t' -v H="$h" '{ print $1 "\t" H }'
done | sort -u > "$t/decls"

awk -F'\t' '
  FILENAME ~ /uncompiled$/ { unc[$1] = $2; next }
  { if (!($2 in unc)) ok[$1] = 1; else if (!($1 in src)) src[$1] = unc[$2] }
  END { for (n in src) if (!(n in ok)) print n "\t" src[n] }
' "$t/uncompiled" "$t/decls" | sort -u > "$t/unreachable"

# A path component named `internal` is ozz saying so, the same way its
# `namespace internal` does.
awk -F'\t' '$2 ~ /\/internal\// { print $1 "\t" $2 }' "$t/decls" | sort -u > "$t/indir"
awk -F'\t' '{ if ($2 !~ /\/internal\//) ok[$1] = 1; else d[$1] = $2 }
             END { for (n in d) if (!(n in ok)) print n "\t" d[n] }' "$t/decls" |
  sort -u > "$t/internaldir"

awk -F'\t' -v mode="${1:-}" '
  FILENAME ~ /marked$/      { if (!($1 in ev)) ev[$1] = "upstream " $2 " (" $3 ")"; next }
  FILENAME ~ /unreachable$/ { unr[$1] = $2; next }
  FILENAME ~ /internaldir$/ { indir[$1] = $2; next }
  FILENAME ~ /public$/      { pub[$0] = 1; next }
  {
    if ($0 in ev)          v = ev[$0]
    else if (!($0 in pub)) v = "no public declaration"
    else if ($0 in indir)  v = "declared only under " indir[$0] ", an internal directory"
    else if ($0 in unr)    v = "declared only by " unr[$0] ", which this build does not compile"
    else                   { if (mode == "--open") print $0; next }
    if (mode != "--open") print $0 "\tINTERNAL\t" v
  }
' "$t/marked" "$t/unreachable" "$t/internaldir" "$t/public" "$t/unbound"
