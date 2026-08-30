#!/usr/bin/env bash
#
# ZOZZ_ALIGN16 must be applied to a struct DEFINITION, never to a member.
#
# A member-aligned type reads back as align 8 through Zig's translate-c on
# every non-MSVC target, because translate-c ignores `#pragma pack(pop)` and
# mingw's corecrt.h leaves a pack(8) open. src/abi_check.zig then fails on a
# difference no object file has. See ffi/zozz_core.h's alignment banner.
#
# The ABI oracle catches this too, but only on the targets CI executes and
# only for a type src/c.zig mirrors. This catches it everywhere, in a second.

set -uo pipefail
cd "$(dirname "$0")/.."

if [ -t 1 ]; then RED=$'\033[31m'; GREEN=$'\033[32m'; OFF=$'\033[0m'
else RED=; GREEN=; OFF=; fi

bad=$(awk '
  /^[[:space:]]*(\/\/|\*|\/\*)/ { next }
  /#[[:space:]]*define[[:space:]]+ZOZZ_ALIGN16/ { next }
  /ZOZZ_ALIGN16/ && $0 !~ /struct[[:space:]]+ZOZZ_ALIGN16/ {
    printf "%s:%d: %s\n", FILENAME, FNR, $0
  }
' ffi/*.h ffi/*.cpp)

if [ -n "$bad" ]; then
  printf '%s\n' "$bad" | sed 's/^/  /' >&2
  printf '%sZOZZ_ALIGN16 must follow `struct`, not precede a member%s\n' "$RED" "$OFF" >&2
  exit 1
fi

printf '%sOK%s  ZOZZ_ALIGN16 is applied to types, not members\n' "$GREEN" "$OFF"
