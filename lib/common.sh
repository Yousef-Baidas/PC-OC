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

# probe_read <path>: set REPLY to the trimmed first line and PROBE_CONTENT to
# the whole content, from one read; record path and size.
probe_read() {
  die lib "not implemented"
}

# probe_source <label> <bytes>: record a source that is not a file.
probe_source() {
  die lib "not implemented"
}

# probe_emit <key=value>...: print the line-1 header, then <component>.<key>=<value>.
probe_emit() {
  die lib "not implemented"
}
