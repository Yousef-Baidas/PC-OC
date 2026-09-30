#!/usr/bin/env bash
set -euo pipefail
# Shared helpers. Source this file; do not execute it.

# sysfs_path <path>: print <path> under the fake root bats sets, or unchanged.
sysfs_path() {
  printf '%s%s\n' "${SYSFS_ROOT:-}" "$1"
}

# die <component> <msg>: print "pc-oc: <component>: <msg>" to stderr, exit 1.
die() {
  printf 'pc-oc: %s: %s\n' "$1" "$2" >&2
  exit 1
}
