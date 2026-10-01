#!/usr/bin/bash
set -euo pipefail
# Apply the gpu power limit from gpu/values via nvidia-smi -pl, then read it back.
here="$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=../lib/common.sh
source "$here/../lib/common.sh"
# shellcheck source=../lib/write.sh
source "$here/../lib/write.sh"

# root runs with a fixed PATH, like pc_oc_state ignores PC_OC_STATE at EUID 0
[[ "$EUID" -ne 0 ]] || export PATH=/usr/bin

pl_w=""
[[ -r "$here/values" ]] || die gpu "cannot read $here/values"
while IFS= read -r line || [[ -n "$line" ]]; do
  if [[ "$line" =~ ^pl_w=([1-9][0-9]{0,3})([[:space:]]|$) ]]; then pl_w="${BASH_REMATCH[1]}"; fi
done <"$here/values"
[[ -n "$pl_w" ]] || die gpu "no pl_w in $here/values"

power="$(nvidia-smi -q -d POWER)" || die gpu "nvidia-smi -q -d POWER failed"
min_w="" max_w=""
while IFS= read -r line; do
  if [[ "$line" =~ ^[[:space:]]*Min\ Power\ Limit[[:space:]]*:[[:space:]]*([1-9][0-9]{0,3}|0)(\.[0-9]+)?\ W ]]; then min_w="${BASH_REMATCH[1]}"; fi
  if [[ "$line" =~ ^[[:space:]]*Max\ Power\ Limit[[:space:]]*:[[:space:]]*([1-9][0-9]{0,3}|0)(\.[0-9]+)?\ W ]]; then max_w="${BASH_REMATCH[1]}"; fi
done <<<"$power"
[[ -n "$min_w" && -n "$max_w" ]] || die gpu "cannot parse Min/Max Power Limit"
if ((10#$pl_w < 10#$min_w || 10#$pl_w > 10#$max_w)); then
  die gpu "pl_w $pl_w outside [$min_w, $max_w]"
fi

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
nvidia-smi -pl "$pl_w" >/dev/null || {
  [[ -z "$made" ]] || rm -f -- "$stock" || :
  die gpu "nvidia-smi -pl $pl_w failed"
}
got="$(nvidia-smi --query-gpu=power.limit --format=csv,noheader,nounits)" || {
  die gpu "read-back failed"
}
awk -v g="$got" -v w="$pl_w" 'BEGIN { d = g - w; exit !(g ~ /^[ ]*[0-9.]+[ ]*$/ && d <= 0.5 && d >= -0.5) }' || {
  die gpu "readback power.limit: want $pl_w got $got"
}
