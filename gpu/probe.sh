#!/usr/bin/env bash
set -euo pipefail
# Print current gpu values: the probe_emit header, then gpu.<key>=<value>.
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

PROBE_COMPONENT=gpu

# Fields per `nvidia-smi --query-gpu` (smi); units are W and MHz, unit-free via nounits.
keys=(name driver vbios pl_w pl_default_w pl_min_w pl_max_w clock_max_mhz mem_clock_max_mhz)

probe_run nvidia-smi --query-gpu=name,driver_version,vbios_version,power.limit,power.default_limit,power.min_limit,power.max_limit,clocks.max.graphics,clocks.max.memory --format=csv,noheader,nounits
# trailing blank lines are not rows
out=${PROBE_CONTENT%"${PROBE_CONTENT##*[!$'\n']}"}
[[ "$out" != *$'\n'* ]] || die gpu "expected one GPU row from nvidia-smi, got several"
IFS=',' read -r -a fields <<<"$out"
set -- "${keys[@]}"
want=$#
set -- "${fields[@]}"
[[ "$#" -eq "$want" ]] || die gpu "expected $want fields from nvidia-smi, got $#"

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

args=()
for i in "${!keys[@]}"; do
  args+=("${keys[i]}=${values[i]}")
done
probe_emit "${args[@]}"
