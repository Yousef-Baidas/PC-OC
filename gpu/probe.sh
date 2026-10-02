#!/usr/bin/env bash
set -euo pipefail
# Print current gpu values: the probe_emit header, then gpu.<key>=<value>.
here="$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=../lib/common.sh
source "$here/../lib/common.sh"

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

# Clock offsets in MHz per performance state (nvml-offset-t), from the helper (ADR 0003):
# one line per state and clock, "p<n>.<core|mem> offset=<mhz> min=<mhz> max=<mhz>" or
# "p<n>.<core|mem> unsupported". A failed get dies in probe_run; a line of any other shape,
# a repeated one or a missing one dies here, so no key is ever printed from a guess.
probe_run /usr/bin/python3 -I "$here/nvml.py" get
out=${PROBE_CONTENT%"${PROBE_CONTENT##*[!$'\n']}"}
mhz='(0|-?[1-9][0-9]*)'
declare -A offsets=()
while IFS= read -r line; do
  if [[ "$line" =~ ^p([012])\.(core|mem)\ offset=$mhz\ min=$mhz\ max=$mhz$ ]]; then
    k="${BASH_REMATCH[2]}_p${BASH_REMATCH[1]}" v="${BASH_REMATCH[3]}"
  elif [[ "$line" =~ ^p([012])\.(core|mem)\ unsupported$ ]]; then
    k="${BASH_REMATCH[2]}_p${BASH_REMATCH[1]}" v=unsupported
  else
    die gpu "cannot parse this line of nvml.py get: $line"
  fi
  [[ -z "${offsets[$k]:-}" ]] || die gpu "nvml.py get printed $k twice"
  offsets[$k]="$v"
done <<<"$out"
for k in core_p0 core_p1 core_p2 mem_p0 mem_p1 mem_p2; do
  [[ -n "${offsets[$k]:-}" ]] || die gpu "nvml.py get printed no line for $k"
  args+=("offset_$k=${offsets[$k]}")
done

# The boot unit's state is two exit statuses, no output is read, so it adds no source:
# cat fails for a unit that is not installed, is-enabled is 0 only for an enabled one.
unit=pc-oc-gpu.service
if ! systemctl cat "$unit" >/dev/null 2>&1; then
  args+=("boot_unit=missing")
elif systemctl is-enabled --quiet "$unit"; then
  args+=("boot_unit=enabled")
else
  args+=("boot_unit=disabled")
fi

probe_emit "${args[@]}"
