#!/usr/bin/bash
set -euo pipefail
# Apply the power limit of gpu/values via nvidia-smi -pl, read back; then the two clock
# offsets through nvml.py (ADR 0003), which reads each write back itself; then make sure
# the boot unit is enabled. The unit is never started: at boot this script is its start.
# The offsets are those of the search result (gpu/search.sh) when a result path exists,
# and those of gpu/values only when none does: a result that cannot be trusted is refused
# before anything is written, never replaced by gpu/values.
here="$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=../lib/common.sh
source "$here/../lib/common.sh"
# shellcheck source=../lib/write.sh
source "$here/../lib/write.sh"
# shellcheck source=pl.sh
source "$here/pl.sh"

# root runs with a fixed PATH, like pc_oc_state ignores PC_OC_STATE as root
! is_root || export PATH=/usr/bin

# A reader that has left must not end this script between a step and its undo. With PIPE at
# its default the first print into a closed pipe, stdout or stderr (2>&1 | head -n 1), kills
# the shell where it stands: a first apply whose -pl fails then keeps its snapshot. Ignored,
# such a print fails with EPIPE instead. What that does under set -e: in die and in back_out
# the print is the last step before exit 1 and every undo is done by then, so the script
# ends at the same place with the same status; in pl_write, called on the left of ||, set -e
# is off, the failed print is passed over, and its return 1 and the undo follow. The one
# print to stdout comes before the first write and its failure is fatal there. No print
# stands between two steps of a complete apply, so none can make it a half one. The tools
# this script starts inherit the ignore: one that reports to a closed stderr gets an error
# from its write and is not killed in the middle of its work.
trap '' PIPE

unit=pc-oc-gpu.service

# nvml <args>: run the helper the one way it may be run: isolated mode, absolute interpreter
nvml() {
  /usr/bin/python3 -I "$here/nvml.py" "$@"
}

# back_out <why>: the one way out once an offset may be left behind: zero both, say whether
# that worked, exit 1 without touching the unit. TERM, HUP and INT are ignored from here
# on, so zero runs once and to its end.
back_out() {
  trap '' TERM HUP INT
  if nvml zero >/dev/null; then
    die gpu "$1; clock offsets zeroed, boot unit left as it was"
  fi
  die gpu "$1; nvml.py zero failed as well, clock offsets may still be set: run pc-oc revert gpu"
}

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

pl_w="" values_core="" values_mem=""
[[ -r "$here/values" ]] || die gpu "cannot read $here/values"
while IFS= read -r line || [[ -n "$line" ]]; do
  if [[ "$line" =~ ^pl_w=([1-9][0-9]{0,3})([[:space:]]|$) ]]; then pl_w="${BASH_REMATCH[1]}"; fi
  # the helper takes 0 or a positive whole number of MHz and holds the caps (nvml-offset-t)
  if [[ "$line" =~ ^core_offset_mhz=(0|[1-9][0-9]{0,3})([[:space:]]|$) ]]; then values_core="${BASH_REMATCH[1]}"; fi
  if [[ "$line" =~ ^mem_offset_mhz=(0|[1-9][0-9]{0,3})([[:space:]]|$) ]]; then values_mem="${BASH_REMATCH[1]}"; fi
done <"$here/values"
[[ -n "$pl_w" ]] || die gpu "no pl_w in $here/values"
[[ -n "$values_core" ]] || die gpu "no core_offset_mhz in $here/values (0, or 1 to 9999 with no sign and no leading zero)"
[[ -n "$values_mem" ]] || die gpu "no mem_offset_mhz in $here/values (0, or 1 to 9999 with no sign and no leading zero)"

# the two offsets get their value here and nowhere else: from the result when a result
# path exists, from gpu/values when none does, and from neither when the result is refused
state="$(pc_oc_state)" || die gpu "pc_oc_state failed"
search_result "$state/gpu/search/result"
case "$result_state" in
  none)
    core_offset_mhz="$values_core" mem_offset_mhz="$values_mem"
    from="gpu/values"
    ;;
  good)
    core_offset_mhz="$result_core" mem_offset_mhz="$result_mem"
    from="search result"
    ;;
  *) die gpu "$result_why; nothing was written, and gpu/values is not used in its place" ;;
esac

pl_check "$pl_w"

# without the unit a tuned card would be stock again after the next boot: refuse before
# anything is read from the card for the snapshot or written to it
systemctl cat "$unit" >/dev/null || die gpu "boot unit not installed: run sudo os/install.sh"

# the one line of stdout, before anything is created or written: an apply that cannot say
# where its offsets come from does not set them
printf 'gpu: offsets core=%s mem=%s from %s\n' "$core_offset_mhz" "$mem_offset_mhz" "$from" ||
  die gpu "cannot write to stdout, nothing was written"

stock="$state/gpu/stock"
made=""
if [[ ! -e "$stock" ]]; then
  snap="$(bash "$here/probe.sh")" || die gpu "probe failed"
  mkdir -p "$(dirname "$stock")" || die gpu "cannot create $(dirname "$stock")"
  { printf '%s\n' "$snap" >"$stock.tmp"; } || {
    rm -f -- "$stock.tmp" || :
    die gpu "cannot save $stock"
  }
  mv -f -- "$stock.tmp" "$stock" || die gpu "cannot save $stock"
  made=1
fi

# from before the first write: systemd ends a start that outlives TimeoutStartSec with
# TERM. bash runs the trap once the command it waits on has returned
trap 'back_out "got TERM"' TERM
trap 'back_out "got HUP"' HUP
trap 'back_out "got INT"' INT

# a failed -pl wrote nothing, so drop a snapshot this call made; after a read-back
# mismatch the limit may have changed, so the snapshot stays for revert
pl_write "$pl_w" || {
  [[ -z "$made" ]] || rm -f -- "$stock" || :
  exit 1
}
pl_verify "$pl_w"

# core, then mem; a set that fails or is killed may have written some performance states
nvml set core "$core_offset_mhz" >/dev/null || back_out "core_offset_mhz $core_offset_mhz not set"
nvml set mem "$mem_offset_mhz" >/dev/null || back_out "mem_offset_mhz $mem_offset_mhz not set"

# both sets exited 0: the apply is committed. TERM, HUP and INT are ignored to the end, so
# the back-out never runs once enable may have been called and its message stays true
trap '' TERM HUP INT

if ! systemctl is-enabled --quiet "$unit"; then
  systemctl enable "$unit" || die gpu "cannot enable $unit: the offsets are set but will not be set again at boot"
fi
