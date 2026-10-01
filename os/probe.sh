#!/usr/bin/env bash
set -euo pipefail
# Print current os values: the probe_emit header, then os.<key>=<value>.
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

PROBE_COMPONENT=os

cpu_dir=$(sysfs_path /sys/devices/system/cpu)
probe_read "$(sysfs_path /proc/sys/kernel/osrelease)"
kernel=$REPLY
probe_read "$cpu_dir/intel_pstate/status"
pstate=$REPLY
probe_read "$cpu_dir/cpu0/cpufreq/scaling_governor"
governor=$REPLY
probe_read "$cpu_dir/cpu0/cpufreq/energy_performance_preference"
epp=$REPLY

uniform=yes
for d in "$cpu_dir"/cpu[0-9]*/cpufreq; do
  [[ "$d" == "$cpu_dir/cpu0/cpufreq" ]] && continue
  probe_read "$d/scaling_governor"
  [[ "$REPLY" == "$governor" ]] || uniform=no
  probe_read "$d/energy_performance_preference"
  [[ "$REPLY" == "$epp" ]] || uniform=no
done

scx_dir=$(sysfs_path /sys/kernel/sched_ext)
scx_state=unsupported
scx_ops=none
if [[ -d "$scx_dir" ]]; then
  probe_read "$scx_dir/state"
  scx_state=$REPLY
  if [[ -r "$scx_dir/root/ops" ]]; then
    probe_read "$scx_dir/root/ops"
    scx_ops=$REPLY
  fi
fi

probe_read "$(sysfs_path /proc/sys/vm/swappiness)"
swappiness=$REPLY
probe_read "$(sysfs_path /sys/kernel/mm/transparent_hugepage/enabled)"
thp=$REPLY
[[ "$thp" =~ \[([a-z]+)\] ]] || die os "no bracketed value in transparent_hugepage/enabled"
thp=${BASH_REMATCH[1]}

probe_emit \
  kernel="$kernel" \
  pstate_status="$pstate" \
  governor="$governor" \
  epp="$epp" \
  governors_uniform="$uniform" \
  scx_state="$scx_state" \
  scx_ops="$scx_ops" \
  swappiness="$swappiness" \
  thp="$thp"
