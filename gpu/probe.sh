#!/usr/bin/env bash
set -euo pipefail
# Print current gpu values: line 1 source= bytes= items=, then gpu.<key>=<value>.
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

# Fields per `nvidia-smi --query-gpu` (smi); units are W and MHz, unit-free via nounits.
keys=(name driver vbios pl_w pl_default_w pl_min_w pl_max_w clock_max_mhz mem_clock_max_mhz)

smi=$(command -v nvidia-smi) || die gpu "nvidia-smi not found on PATH"
out=$("$smi" --query-gpu=name,driver_version,vbios_version,power.limit,power.default_limit,power.min_limit,power.max_limit,clocks.max.graphics,clocks.max.memory --format=csv,noheader,nounits) ||
  die gpu "nvidia-smi query failed"
[[ "$out" != *$'\n'* ]] || die gpu "expected one GPU row from nvidia-smi, got several"
IFS=',' read -r -a fields <<<"$out"
[[ "${#fields[@]}" -eq "${#keys[@]}" ]] || die gpu "expected ${#keys[@]} fields from nvidia-smi, got ${#fields[@]}"

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

printf 'source=%s bytes=%s items=%s\n' "$smi" "$(printf '%s\n' "$out" | LC_ALL=C wc -c | tr -d ' ')" "${#keys[@]}"
for i in "${!keys[@]}"; do
  printf 'gpu.%s=%s\n' "${keys[i]}" "${values[i]}"
done
