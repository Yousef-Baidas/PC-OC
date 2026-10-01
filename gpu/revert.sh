#!/usr/bin/bash
set -euo pipefail
# Restore the stock power limit recorded in the snapshot, read it back, drop the snapshot.
here="$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=../lib/common.sh
source "$here/../lib/common.sh"
# shellcheck source=../lib/write.sh
source "$here/../lib/write.sh"
# shellcheck source=pl.sh
source "$here/pl.sh"

! is_root || export PATH=/usr/bin

stock="$(pc_oc_state)/gpu/stock"
if [[ ! -f "$stock" ]]; then
  printf 'pc-oc: gpu: nothing to revert\n' >&2
  exit 0
fi
pl_w=""
while IFS= read -r line || [[ -n "$line" ]]; do
  if [[ "$line" =~ ^gpu\.pl_w=([1-9][0-9]{0,3})(\.[0-9]+)?$ ]]; then pl_w="${BASH_REMATCH[1]}"; fi
done <"$stock"
[[ -n "$pl_w" ]] || die gpu "no gpu.pl_w in $stock"

pl_check "$pl_w"
pl_write "$pl_w" || exit 1
pl_verify "$pl_w"
rm -f -- "$stock" || die gpu "cannot remove $stock"
rmdir -- "$(dirname "$stock")" 2>/dev/null || :
