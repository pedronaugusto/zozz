#!/usr/bin/env bash
#
# zozz — prove libs/ozz is really unmodified upstream.
#
# UPSTREAM.md says the vendored tree is a pristine copy of a specific commit.
# On its own that is a claim in a markdown file: nothing stops an edit to
# libs/ from landing while the documentation still says otherwise. This script
# turns the claim into a check by fetching that exact commit and diffing.
#
# It is the reason a git submodule is not needed here. A submodule would have
# git record the upstream commit, which is genuinely useful — but Zig's package
# manager fetches a source archive and never resolves submodules, so consumers
# would receive an empty libs/ and a build that cannot work. This gets the
# guarantee without the breakage.
#
# Needs network, so it is a separate CI job rather than part of ci/run.sh.
#
# Usage: ci/verify-vendor.sh

set -euo pipefail
cd "$(dirname "$0")/.."

# Kept in step with UPSTREAM.md by the check below, so the two cannot drift.
UPSTREAM_URL="https://github.com/guillaumeblanc/ozz-animation.git"
UPSTREAM_TAG="0.17.0"
UPSTREAM_COMMIT="744eb9d99f606eda849acb0b1204f7a3dc20bca1"

# Directories and files copied verbatim from upstream.
VENDORED=(include src LICENSE.md AUTHORS.md CHANGES.md)

# Removed deliberately after copying; upstream has them, we do not.
# Documented in UPSTREAM.md under "What was excluded, and why".
EXCLUDE_ARGS=(-x CMakeLists.txt -x fbx)

if [ -t 1 ]; then
  RED=$'\033[31m'; GREEN=$'\033[32m'; DIM=$'\033[2m'; OFF=$'\033[0m'
else
  RED=; GREEN=; DIM=; OFF=
fi

fail() { printf '%s%s%s\n' "$RED" "$1" "$OFF" >&2; exit 1; }

# The pin must appear in UPSTREAM.md verbatim. If someone bumps one and not the
# other, that is exactly the drift this script exists to catch.
grep -q "$UPSTREAM_COMMIT" UPSTREAM.md ||
  fail "UPSTREAM.md does not mention $UPSTREAM_COMMIT — the pin has drifted."

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

printf '%sfetching %s at %s%s\n' "$DIM" "$UPSTREAM_URL" "$UPSTREAM_TAG" "$OFF"
# core.autocrlf is disabled for this clone, not left to the host's git. On a
# Windows machine the global default rewrites every LF to CRLF on checkout,
# and the diff below then reports all seven hundred vendored files as
# modified when not one byte of libs/ has changed -- a check that accuses the
# tree of the thing it exists to detect. What is compared has to be the blob,
# not the host's idea of a line ending.
git -c core.autocrlf=false -c core.eol=lf clone --quiet --depth 1 \
  --branch "$UPSTREAM_TAG" "$UPSTREAM_URL" \
  "$work/upstream" 2>/dev/null || fail "clone failed"

# A tag can be moved; the commit cannot. Check the SHA, not the label.
actual=$(git -C "$work/upstream" rev-parse HEAD)
[ "$actual" = "$UPSTREAM_COMMIT" ] ||
  fail "tag $UPSTREAM_TAG is $actual, expected $UPSTREAM_COMMIT"
printf '%scommit %s confirmed%s\n' "$DIM" "$UPSTREAM_COMMIT" "$OFF"

status=0
for path in "${VENDORED[@]}"; do
  if [ ! -e "libs/ozz/$path" ]; then
    printf '  %-24s %sMISSING locally%s\n' "$path" "$RED" "$OFF"
    status=1
    continue
  fi
  if diff -r "${EXCLUDE_ARGS[@]}" \
       "$work/upstream/$path" "libs/ozz/$path" > "$work/diff" 2>&1
  then
    printf '  %-24s %sidentical%s\n' "$path" "$GREEN" "$OFF"
  else
    printf '  %-24s %sDIFFERS%s\n' "$path" "$RED" "$OFF"
    sed 's/^/      /' "$work/diff" | head -30
    status=1
  fi
done

if [ $status -ne 0 ]; then
  printf '\n%slibs/ozz is not a pristine copy of %s.%s\n' \
    "$RED" "$UPSTREAM_COMMIT" "$OFF" >&2
  printf 'Either revert the local change, or — if the divergence is intended —\n' >&2
  printf 'record it in UPSTREAM.md and teach this script about it.\n' >&2
  exit 1
fi

printf '\n%slibs/ozz matches upstream %s exactly%s\n' \
  "$GREEN" "$UPSTREAM_COMMIT" "$OFF"
