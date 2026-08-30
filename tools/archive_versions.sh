#!/usr/bin/env bash
#
# zozz — the archive version of every serialisable ozz type, read out of the
# vendored headers.
#
# ozz versions its archives per type and refuses a version it does not know,
# so these numbers decide which `.ozz` files this package can load. They are
# properties of the pinned upstream: a re-vendor can change any of them, which
# is why UPSTREAM.md holds the table as a generated block rather than by hand.
#
# Only a declaration at column 0 counts: archive_traits.h documents the macro
# with an example use, and a documented example is not a serialisable type.
#
# Emits markdown on stdout; ci/check-docs.sh keeps the document equal to it.

set -euo pipefail
cd "$(dirname "$0")/.."

printf '| Type | Archive version | Declared in |\n|---|---:|---|\n'

grep -r --include='*.h' -oE '^OZZ_IO_TYPE_VERSION\([0-9]+, [^)]+\)' libs/ozz/include |
  sed -E 's|^libs/ozz/include/ozz/||; s|:OZZ_IO_TYPE_VERSION\(([0-9]+), ([^)]+)\)|\t\1\t\2|' |
  awk -F'\t' '{ printf "| `%s` | %s | `%s` |\n", $3, $2, $1 }' |
  sort
