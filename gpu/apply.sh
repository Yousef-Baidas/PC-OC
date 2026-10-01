#!/usr/bin/bash
set -euo pipefail
# Apply the gpu power limit from gpu/values via nvidia-smi -pl, then read it back.
here="$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=../lib/common.sh
source "$here/../lib/common.sh"
# shellcheck source=../lib/write.sh
source "$here/../lib/write.sh"
# shellcheck source=pl.sh
source "$here/pl.sh"

# root runs with a fixed PATH, like pc_oc_state ignores PC_OC_STATE as root
! is_root || export PATH=/usr/bin

pl_w=""
[[ -r "$here/values" ]] || die gpu "cannot read $here/values"
while IFS= read -r line || [[ -n "$line" ]]; do
  if [[ "$line" =~ ^pl_w=([1-9][0-9]{0,3})([[:space:]]|$) ]]; then pl_w="${BASH_REMATCH[1]}"; fi
done <"$here/values"
[[ -n "$pl_w" ]] || die gpu "no pl_w in $here/values"

pl_check "$pl_w"

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

# a failed -pl wrote nothing, so drop a snapshot this call made; after a read-back
# mismatch the limit may have changed, so the snapshot stays for revert
pl_write "$pl_w" || {
  [[ -z "$made" ]] || rm -f -- "$stock" || :
  exit 1
}
pl_verify "$pl_w"
