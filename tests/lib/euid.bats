#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

# Contract #60. Static grep; it runs nothing. $EUID is imported from the caller's environment
# and arithmetic-evaluated, so root checks go through is_root (kernel uid) instead.

@test "no file under lib/ or os/ contains EUID" {
  root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  run grep -rn -e EUID "$root/lib" "$root/os"
  [ "$status" -eq 1 ] || printf '%s\n' "$output" >&2
  [ "$status" -eq 1 ]
  [ "$output" = "" ]
}
