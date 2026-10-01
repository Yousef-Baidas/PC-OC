#!/usr/bin/env bash
set -euo pipefail
# Print current cpu values: the probe_emit header, then cpu.<key>=<value>.
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

PROBE_COMPONENT=cpu

cpuinfo="$(sysfs_path /proc/cpuinfo)"
probe_read "$cpuinfo"
model="$(sed -n 's/^model name[[:space:]]*: //p' <<<"$PROBE_CONTENT" | head -n1)"
microcode="$(sed -n 's/^microcode[[:space:]]*: //p' <<<"$PROBE_CONTENT" | head -n1)"
[[ -n "$model" ]] || die cpu "no model name in $cpuinfo"
[[ -n "$microcode" ]] || die cpu "no microcode in $cpuinfo"

rapl="$(sysfs_path /sys/class/powercap/intel-rapl:0)"
[[ -d "$rapl" ]] || die cpu "missing $rapl"
pl1_uw="" pl1_tau_us="" pl2_uw=""
for name_file in "$rapl"/constraint_*_name; do
  [[ -e "$name_file" ]] || die cpu "no constraints under $rapl"
  probe_read "$name_file"
  n="${name_file##*/constraint_}"
  n="${n%_name}"
  case "$REPLY" in
    long_term)
      probe_read "$rapl/constraint_${n}_power_limit_uw"
      pl1_uw="$REPLY"
      probe_read "$rapl/constraint_${n}_time_window_us"
      pl1_tau_us="$REPLY"
      ;;
    short_term)
      probe_read "$rapl/constraint_${n}_power_limit_uw"
      pl2_uw="$REPLY"
      ;;
  esac
done
[[ -n "$pl1_uw" ]] || die cpu "no long_term constraint under $rapl"
[[ -n "$pl2_uw" ]] || die cpu "no short_term constraint under $rapl"

probe_emit \
  model="$model" \
  microcode="$microcode" \
  pl1_uw="$pl1_uw" \
  pl1_tau_us="$pl1_tau_us" \
  pl2_uw="$pl2_uw"
