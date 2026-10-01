#!/usr/bin/bash
set -euo pipefail
# Restore the stock power limit recorded in the snapshot, read it back, drop the snapshot.
here="$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=../lib/common.sh
source "$here/../lib/common.sh"
# shellcheck source=../lib/write.sh
source "$here/../lib/write.sh"

[[ "$EUID" -ne 0 ]] || export PATH=/usr/bin

stock="$(pc_oc_state)/gpu/stock"
[[ -f "$stock" ]] || die gpu "no stock snapshot"
pl_w=""
while IFS= read -r line || [[ -n "$line" ]]; do
  if [[ "$line" =~ ^gpu\.pl_w=([0-9]+)(\.[0-9]+)?$ ]]; then pl_w="${BASH_REMATCH[1]}"; fi
done <"$stock"
[[ -n "$pl_w" ]] || die gpu "no gpu.pl_w in $stock"

nvidia-smi -pl "$pl_w" >/dev/null || die gpu "nvidia-smi -pl $pl_w failed"
got="$(nvidia-smi --query-gpu=power.limit --format=csv,noheader,nounits)" || die gpu "read-back failed"
awk -v g="$got" -v w="$pl_w" 'BEGIN { d = g - w; exit !(g ~ /^[ ]*[0-9.]+[ ]*$/ && d <= 0.5 && d >= -0.5) }' ||
  die gpu "readback power.limit: want $pl_w got $got"
rm -f -- "$stock" || die gpu "cannot remove $stock"
