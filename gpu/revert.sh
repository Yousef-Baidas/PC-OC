#!/usr/bin/bash
set -euo pipefail
# Undo apply in three parts: zero the clock offsets through nvml.py (ADR 0003), disable the
# boot unit, restore the stock power limit recorded in the snapshot and drop the snapshot.
# Every part runs even when an earlier one failed; the failed parts are named at the end.
here="$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=../lib/common.sh
source "$here/../lib/common.sh"
# shellcheck source=../lib/write.sh
source "$here/../lib/write.sh"
# shellcheck source=pl.sh
source "$here/pl.sh"

! is_root || export PATH=/usr/bin

unit=pc-oc-gpu.service
stock="$(pc_oc_state)/gpu/stock"
failed=""

# pl_restore: write the snapshot's power limit, read it back, drop the snapshot. Run in a
# subshell, so a die in here is one failed part and not the end of revert.
pl_restore() {
  local line pl_w=""
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^gpu\.pl_w=([1-9][0-9]{0,3})(\.[0-9]+)?$ ]]; then pl_w="${BASH_REMATCH[1]}"; fi
  done <"$stock"
  [[ -n "$pl_w" ]] || die gpu "no gpu.pl_w in $stock"

  pl_check "$pl_w"
  pl_write "$pl_w" || exit 1
  pl_verify "$pl_w"
  rm -f -- "$stock" || die gpu "cannot remove $stock"
  rmdir -- "$(dirname "$stock")" 2>/dev/null || :
}

# needs no snapshot: zero is the stock offset of every performance state
/usr/bin/python3 -I "$here/nvml.py" zero >/dev/null || failed+="${failed:+, }clock offsets not zeroed"

# is-enabled is 0 only for an enabled unit; one that is not installed has nothing to
# disable. The unit is not stopped: it is a oneshot that has already exited
if systemctl is-enabled --quiet "$unit"; then
  systemctl disable "$unit" || failed+="${failed:+, }boot unit $unit not disabled"
fi

if [[ -f "$stock" ]]; then
  (pl_restore) || failed+="${failed:+, }power limit not restored, snapshot kept"
else
  printf 'pc-oc: gpu: nothing to revert\n' >&2
fi

[[ -z "$failed" ]] || die gpu "revert incomplete: $failed"
