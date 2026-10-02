#!/usr/bin/bash
set -euo pipefail
# Apply gpu/values: the power limit via nvidia-smi -pl, read back; then the two clock
# offsets through nvml.py (ADR 0003), which reads each write back itself; then make sure
# the boot unit is enabled. The unit is never started: at boot this script is its start.
here="$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=../lib/common.sh
source "$here/../lib/common.sh"
# shellcheck source=../lib/write.sh
source "$here/../lib/write.sh"
# shellcheck source=pl.sh
source "$here/pl.sh"

# root runs with a fixed PATH, like pc_oc_state ignores PC_OC_STATE as root
! is_root || export PATH=/usr/bin

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

pl_w="" core_offset_mhz="" mem_offset_mhz=""
[[ -r "$here/values" ]] || die gpu "cannot read $here/values"
while IFS= read -r line || [[ -n "$line" ]]; do
  if [[ "$line" =~ ^pl_w=([1-9][0-9]{0,3})([[:space:]]|$) ]]; then pl_w="${BASH_REMATCH[1]}"; fi
  # the helper takes 0 or a positive whole number of MHz and holds the caps (nvml-offset-t)
  if [[ "$line" =~ ^core_offset_mhz=(0|[1-9][0-9]{0,3})([[:space:]]|$) ]]; then core_offset_mhz="${BASH_REMATCH[1]}"; fi
  if [[ "$line" =~ ^mem_offset_mhz=(0|[1-9][0-9]{0,3})([[:space:]]|$) ]]; then mem_offset_mhz="${BASH_REMATCH[1]}"; fi
done <"$here/values"
[[ -n "$pl_w" ]] || die gpu "no pl_w in $here/values"
[[ -n "$core_offset_mhz" ]] || die gpu "no core_offset_mhz in $here/values (0, or 1 to 9999 with no sign and no leading zero)"
[[ -n "$mem_offset_mhz" ]] || die gpu "no mem_offset_mhz in $here/values (0, or 1 to 9999 with no sign and no leading zero)"

pl_check "$pl_w"

# without the unit a tuned card would be stock again after the next boot: refuse before
# anything is read from the card for the snapshot or written to it
systemctl cat "$unit" >/dev/null || die gpu "boot unit not installed: run sudo os/install.sh"

stock="$(pc_oc_state)/gpu/stock"
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

if ! systemctl is-enabled --quiet "$unit"; then
  systemctl enable "$unit" || die gpu "cannot enable $unit: the offsets are set but will not be set again at boot"
fi
