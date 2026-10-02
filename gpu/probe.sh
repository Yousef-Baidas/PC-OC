#!/usr/bin/env bash
set -euo pipefail
# Print current gpu values: the probe_emit header, then gpu.<key>=<value>. Reads only.
here="$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=../lib/common.sh
source "$here/../lib/common.sh"
# shellcheck source=../lib/write.sh
source "$here/../lib/write.sh"

PROBE_COMPONENT=gpu

# search_result <path>: judge the search result at <path> and set result_state to
#   none     nothing is at <path>: the offsets come from gpu/values
#   good     result_core and result_mem hold its two offsets
#   refused  result_why says what is wrong, and nothing of the file may be used
# The directory and then the file are judged by owner, type and mode before the file is
# opened (stat without -L reads a symlink itself), and the content as a whole before a
# number leaves here: exactly the three lines gpu/search.sh writes, to the byte. The
# numbers are matched text and are only ever arguments of nvml.py, whose caps hold.
# The content is read with probe_read, so a probe that opened the file names it in its
# header; in apply that record is never printed.
# This function stands in gpu/apply.sh and gpu/probe.sh with the same text
# (tests/gpu/apply.bats compares them): no file that both could source is installed.
# shellcheck disable=SC2034 # apply reads the two numbers, probe does not
search_result() {
  local LC_ALL=C path="$1" dir="${1%/*}" up st uid mode
  local re_stat='^([0-9]+) ([0-9a-f]+)$'
  local re_lines=$'^core_offset_mhz=(0|[1-9][0-9]{0,3})\nmem_offset_mhz=(0|[1-9][0-9]{0,3})\nfinished=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\n$'
  # refused until proven otherwise: a return that sets nothing is a refusal
  result_state=refused result_why="" result_core="" result_mem=""

  if [[ ! -e "$path" && ! -L "$path" ]]; then
    # "not there" is only known when the first directory above that exists can be searched
    up="$dir"
    while [[ ! -e "$up" && ! -L "$up" && "$up" == */* ]]; do up="${up%/*}"; done
    if [[ -d "$up" && ! -x "$up" ]]; then
      result_why="cannot tell whether there is a search result at $path: no permission to look into $up"
      return 0
    fi
    result_state=none
    return 0
  fi

  result_why="search result $path refused: "
  if ! st="$(LC_ALL=C /usr/bin/stat -c '%u %f' -- "$dir" 2>/dev/null)" || [[ ! "$st" =~ $re_stat ]]; then
    result_why+="cannot read owner and mode of $dir"
    return 0
  fi
  uid="${BASH_REMATCH[1]}" mode="$((16#${BASH_REMATCH[2]}))"
  if (((mode & 0xF000) != 0x4000)); then
    result_why+="$dir is not a directory"
    return 0
  elif [[ "$uid" != 0 ]]; then
    result_why+="$dir belongs to uid $uid, not to uid 0"
    return 0
  elif (((mode & 022) != 0)); then
    result_why+="$dir is writable by group or others"
    return 0
  fi

  if ! st="$(LC_ALL=C /usr/bin/stat -c '%u %f' -- "$path" 2>/dev/null)" || [[ ! "$st" =~ $re_stat ]]; then
    result_why+="cannot read its owner and mode"
    return 0
  fi
  uid="${BASH_REMATCH[1]}" mode="$((16#${BASH_REMATCH[2]}))"
  if (((mode & 0xF000) != 0x8000)); then
    result_why+="it is not a regular file"
    return 0
  elif [[ "$uid" != 0 ]]; then
    result_why+="it belongs to uid $uid, not to uid 0"
    return 0
  elif (((mode & 022) != 0)); then
    result_why+="it is writable by group or others"
    return 0
  fi

  # probe_read would end the script on a file it cannot read
  if [[ ! -r "$path" ]]; then
    result_why+="no permission to read it"
    return 0
  fi
  probe_read "$path"
  # bash keeps the bytes up to the first NUL byte, and what follows one would go unjudged.
  # read returns 0 only when it met its delimiter, which here is that byte
  if { read -r -d '' _ <"$path"; } 2>/dev/null; then
    result_why+="it holds a NUL byte"
    return 0
  fi
  if [[ ! "$PROBE_CONTENT" =~ $re_lines ]]; then
    result_why+="it is not the three lines gpu/search.sh writes (core_offset_mhz=, mem_offset_mhz=, finished=)"
    return 0
  fi
  result_core="${BASH_REMATCH[1]}" result_mem="${BASH_REMATCH[2]}"
  result_state=good result_why=""
}

# Fields per `nvidia-smi --query-gpu` (smi); units are W and MHz, unit-free via nounits.
keys=(name driver vbios pl_w pl_default_w pl_min_w pl_max_w clock_max_mhz mem_clock_max_mhz)

probe_run nvidia-smi --query-gpu=name,driver_version,vbios_version,power.limit,power.default_limit,power.min_limit,power.max_limit,clocks.max.graphics,clocks.max.memory --format=csv,noheader,nounits
# trailing blank lines are not rows
out=${PROBE_CONTENT%"${PROBE_CONTENT##*[!$'\n']}"}
[[ "$out" != *$'\n'* ]] || die gpu "expected one GPU row from nvidia-smi, got several"
IFS=',' read -r -a fields <<<"$out"
set -- "${keys[@]}"
want=$#
set -- "${fields[@]}"
[[ "$#" -eq "$want" ]] || die gpu "expected $want fields from nvidia-smi, got $#"

values=()
for i in "${!keys[@]}"; do
  v="${fields[i]#"${fields[i]%%[![:space:]]*}"}"
  v="${v%"${v##*[![:space:]]}"}"
  # keys 3..8 are numbers; unsupported ones print [N/A] (smi)
  if [[ "$i" -ge 3 && ! "$v" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    die gpu "${keys[i]} is not a number: $v"
  fi
  values+=("$v")
done

args=()
for i in "${!keys[@]}"; do
  args+=("${keys[i]}=${values[i]}")
done

# Clock offsets in MHz per performance state (nvml-offset-t), from the helper (ADR 0003):
# one line per state and clock, "p<n>.<core|mem> offset=<mhz> min=<mhz> max=<mhz>" or
# "p<n>.<core|mem> unsupported". A failed get dies in probe_run; a line of any other shape,
# a repeated one or a missing one dies here, so no key is ever printed from a guess.
probe_run /usr/bin/python3 -I "$here/nvml.py" get
out=${PROBE_CONTENT%"${PROBE_CONTENT##*[!$'\n']}"}
mhz='(0|-?[1-9][0-9]*)'
declare -A offsets=()
while IFS= read -r line; do
  if [[ "$line" =~ ^p([012])\.(core|mem)\ offset=$mhz\ min=$mhz\ max=$mhz$ ]]; then
    k="${BASH_REMATCH[2]}_p${BASH_REMATCH[1]}" v="${BASH_REMATCH[3]}"
  elif [[ "$line" =~ ^p([012])\.(core|mem)\ unsupported$ ]]; then
    k="${BASH_REMATCH[2]}_p${BASH_REMATCH[1]}" v=unsupported
  else
    die gpu "cannot parse this line of nvml.py get: $line"
  fi
  [[ -z "${offsets[$k]:-}" ]] || die gpu "nvml.py get printed $k twice"
  offsets[$k]="$v"
done <<<"$out"
for k in core_p0 core_p1 core_p2 mem_p0 mem_p1 mem_p2; do
  [[ -n "${offsets[$k]:-}" ]] || die gpu "nvml.py get printed no line for $k"
  args+=("offset_$k=${offsets[$k]}")
done

# The boot unit's state is a file test and one exit status, no output is read, so it adds
# no source. missing is the unit file's absence where os/install.sh puts it, a dangling
# symlink being a file; the system manager is not asked for that, since its every failure
# would read as "missing". is-enabled is 0 only for an enabled unit.
unit=pc-oc-gpu.service
if [[ ! -e "/etc/systemd/system/$unit" && ! -L "/etc/systemd/system/$unit" ]]; then
  args+=("boot_unit=missing")
elif systemctl is-enabled --quiet "$unit"; then
  args+=("boot_unit=enabled")
else
  args+=("boot_unit=disabled")
fi

# Where an apply would take the two offsets from: search for a result it would use, values
# when no result path exists, invalid for one it would refuse, with the reason on stderr.
# The result is a source in the header when it was opened, which search_result sees to.
state="$(pc_oc_state)" || die gpu "pc_oc_state failed"
search_result "$state/gpu/search/result"
case "$result_state" in
  none) args+=("offsets_source=values") ;;
  good) args+=("offsets_source=search") ;;
  *)
    printf 'pc-oc: gpu: %s\n' "$result_why" >&2
    args+=("offsets_source=invalid")
    ;;
esac

probe_emit "${args[@]}"
