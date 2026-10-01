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

# is_root: return 0 when the kernel uid (/usr/bin/id -u) is 0, 1 otherwise; never reads a
# uid variable the caller can forge through the environment. Contract #60.
is_root() {
  [[ "$(/usr/bin/id -u)" == 0 ]]
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

# probe_read_bytes <path> <offset> <count>: read exactly <count> bytes starting at
# byte <offset> of <path>, in one read; set REPLY to them as lowercase hex in file
# order (2*count chars, no separators, NUL bytes kept); record <path> and <count>
# in the probe header. Dies "<component>: cannot read <path>" when <path> is not
# readable, <offset> or <count> is not a decimal number (leading zeros are decimal: 08 is 8)
# or <count> is 0, or fewer than <count> bytes come back. Offset and count are decimal
# (pass 408 for MSR 0x198). Contract #82.
probe_read_bytes() {
  local LC_ALL=C hex off cnt
  [[ -r "$1" && "$2" =~ ^[0-9]+$ && "$3" =~ ^[0-9]+$ ]] || die "${PROBE_COMPONENT:-lib}" "cannot read $1"
  off=$((10#$2)) cnt=$((10#$3))
  ((cnt >= 1)) || die "${PROBE_COMPONENT:-lib}" "cannot read $1"
  hex=$(dd if="$1" bs="$cnt" skip="$off" count=1 iflag=skip_bytes,fullblock status=none 2>/dev/null |
    od -An -v -tx1 | tr -d ' \n') || true
  ((${#hex} == 2 * cnt)) || die "${PROBE_COMPONENT:-lib}" "cannot read $1"
  _PROBE_SOURCES+=("$1")
  _PROBE_BYTES=$((_PROBE_BYTES + cnt))
  REPLY=$hex
}

# probe_source <label> <bytes>: record a source that is not a file.
probe_source() {
  _PROBE_SOURCES+=("$1")
  _PROBE_BYTES=$((_PROBE_BYTES + $2))
}

# probe_run <cmd> [args...]: run <cmd> once; set PROBE_CONTENT to its stdout (trailing
# newlines kept) and REPLY to the trimmed first line; record its absolute path and byte count.
# Dies "<cmd> not found" when absent and "<cmd> failed" on a non-zero exit. Contract #46.
# NUL bytes in the output are dropped by bash command substitution, so bytes= counts only
# the bytes kept; this is not an error.
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
