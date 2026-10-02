#!/usr/bin/bash
set -euo pipefail
# Undo apply in four parts: stop the boot unit, zero the clock offsets through nvml.py
# (ADR 0003), disable the unit, restore the stock power limit recorded in the snapshot and
# drop the snapshot. Every part runs even when an earlier one failed; the failed parts are
# named at the end. The unit is never started.
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

# cat alone decides whether the unit is installed; one that is not has nothing to stop or
# disable. Its stderr is left: it says why the unit counts as not installed
installed=""
if systemctl cat "$unit" >/dev/null; then installed=1; fi

# first, before the zero: the unit restarts on failure, and a restart systemd still has
# pending, or a start that is still running, would set the offsets again. stop cancels the
# one and ends the other; it starts nothing
if [[ -n "$installed" ]]; then
  systemctl stop "$unit" || failed+="${failed:+, }boot unit $unit not stopped"
fi

# needs no snapshot: zero is the stock offset of every performance state
/usr/bin/python3 -I "$here/nvml.py" zero >/dev/null || failed+="${failed:+, }clock offsets not zeroed"

# always, without asking is-enabled: an error of that question would read as "not enabled",
# and disable of a unit that is not enabled changes nothing and exits 0
if [[ -n "$installed" ]]; then
  systemctl disable "$unit" || failed+="${failed:+, }boot unit $unit not disabled"
fi

if [[ -f "$stock" ]]; then
  (pl_restore) || failed+="${failed:+, }power limit not restored, snapshot kept"
else
  printf 'pc-oc: gpu: nothing to revert\n' >&2
fi

[[ -z "$failed" ]] || die gpu "revert incomplete: $failed"
