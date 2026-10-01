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

# Probe header state: files read (or sources recorded) and their byte total.
_PROBE_SOURCES=()
_PROBE_BYTES=0

# probe_read <path>: set REPLY to the trimmed first line and PROBE_CONTENT to
# the whole content, from one read; record path and size.
probe_read() {
  local LC_ALL=C content
  [[ -r "$1" ]] || die "${PROBE_COMPONENT:-lib}" "cannot read $1"
  IFS= read -r -d '' content <"$1" || true
  _PROBE_SOURCES+=("$1")
  _PROBE_BYTES=$((_PROBE_BYTES + ${#content}))
  # shellcheck disable=SC2034 # read by the sourcing probe
  PROBE_CONTENT=$content
  REPLY=${content%%$'\n'*}
  REPLY=${REPLY%"${REPLY##*[![:space:]]}"}
}

# probe_source <label> <bytes>: record a source that is not a file.
probe_source() {
  _PROBE_SOURCES+=("$1")
  _PROBE_BYTES=$((_PROBE_BYTES + $2))
}

# probe_run <cmd> [args...]: run <cmd> once; set PROBE_CONTENT to its stdout (trailing
# newlines kept) and REPLY to the trimmed first line; record its absolute path and byte count.
# Dies "<cmd> not found" when absent and "<cmd> failed" on a non-zero exit. Contract #46.
probe_run() {
  local LC_ALL=C path out
  path=$(command -v "$1") || die "${PROBE_COMPONENT:-lib}" "$1 not found"
  [[ "$path" == /* ]] || die "${PROBE_COMPONENT:-lib}" "$1 not found"
  out=$("$path" "${@:2}" && printf x) || die "${PROBE_COMPONENT:-lib}" "$1 failed"
  out=${out%x}
  _PROBE_SOURCES+=("$path")
  _PROBE_BYTES=$((_PROBE_BYTES + ${#out}))
  # shellcheck disable=SC2034 # read by the sourcing probe
  PROBE_CONTENT=$out
  REPLY=${out%%$'\n'*}
  REPLY=${REPLY%"${REPLY##*[![:space:]]}"}
}

# probe_emit <key=value>...: print the line-1 header, then <component>.<key>=<value>.
probe_emit() {
  local IFS=,
  printf 'source=%s bytes=%s items=%s\n' "${_PROBE_SOURCES[*]}" "$_PROBE_BYTES" "$#"
  local kv
  for kv in "$@"; do
    printf '%s.%s\n' "$PROBE_COMPONENT" "$kv"
  done
}
