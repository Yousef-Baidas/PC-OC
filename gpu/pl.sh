#!/usr/bin/bash
# Shared power-limit steps for gpu/apply.sh and gpu/revert.sh (sourced, not a verb).
# Needs die from lib/common.sh. Limits come from nvidia-smi -q -d POWER (smi), in whole watts.

# pl_check <watts>: die unless <watts> is within the card's Min/Max Power Limit.
pl_check() {
  local want="$1" power line min_w="" max_w=""
  power="$(nvidia-smi -q -d POWER)" || die gpu "nvidia-smi -q -d POWER failed"
  while IFS= read -r line; do
    if [[ "$line" =~ ^[[:space:]]*Min\ Power\ Limit[[:space:]]*:[[:space:]]*([1-9][0-9]{0,3}|0)(\.[0-9]+)?\ W ]]; then min_w="${BASH_REMATCH[1]}"; fi
    if [[ "$line" =~ ^[[:space:]]*Max\ Power\ Limit[[:space:]]*:[[:space:]]*([1-9][0-9]{0,3}|0)(\.[0-9]+)?\ W ]]; then max_w="${BASH_REMATCH[1]}"; fi
  done <<<"$power"
  [[ -n "$min_w" && -n "$max_w" ]] || die gpu "cannot parse Min/Max Power Limit"
  if ((10#$want < 10#$min_w || 10#$want > 10#$max_w)); then
    die gpu "pl_w $want outside [$min_w, $max_w]"
  fi
}

# pl_write <watts>: run nvidia-smi -pl; on failure print the error and return 1, so the
# caller can undo what it made before dying.
pl_write() {
  nvidia-smi -pl "$1" >/dev/null || {
    printf 'pc-oc: gpu: nvidia-smi -pl %s failed\n' "$1" >&2
    return 1
  }
}

# pl_verify <watts>: die unless power.limit reads back within 0.5 W of <watts>.
pl_verify() {
  local got
  got="$(nvidia-smi --query-gpu=power.limit --format=csv,noheader,nounits)" || die gpu "read-back failed"
  awk -v g="$got" -v w="$1" 'BEGIN { d = g - w; exit !(g ~ /^[ ]*[0-9.]+[ ]*$/ && d <= 0.5 && d >= -0.5) }' ||
    die gpu "readback power.limit: want $1 got $got"
}
