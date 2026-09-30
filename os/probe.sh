#!/usr/bin/env bash
set -euo pipefail
# Print current os values: line 1 source= bytes= items=, then os.<key>=<value>.
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

files=()
bytes=0

# read_file <path>: set REPLY to the trimmed first line; record path and size.
read_file() {
  [[ -r "$1" ]] || die os "cannot read $1"
  IFS= read -r REPLY <"$1" || true
  files+=("$1")
  bytes=$((bytes + $(wc -c <"$1")))
}

cpu_dir=$(sysfs_path /sys/devices/system/cpu)
read_file "$(sysfs_path /proc/sys/kernel/osrelease)"
kernel=$REPLY
read_file "$cpu_dir/intel_pstate/status"
pstate=$REPLY
read_file "$cpu_dir/cpu0/cpufreq/scaling_governor"
governor=$REPLY
read_file "$cpu_dir/cpu0/cpufreq/energy_performance_preference"
epp=$REPLY

uniform=yes
for d in "$cpu_dir"/cpu[0-9]*/cpufreq; do
  [[ "$d" == "$cpu_dir/cpu0/cpufreq" ]] && continue
  read_file "$d/scaling_governor"
  [[ "$REPLY" == "$governor" ]] || uniform=no
  read_file "$d/energy_performance_preference"
  [[ "$REPLY" == "$epp" ]] || uniform=no
done

scx_dir=$(sysfs_path /sys/kernel/sched_ext)
scx_state=unsupported
scx_ops=none
if [[ -d "$scx_dir" ]]; then
  read_file "$scx_dir/state"
  scx_state=$REPLY
  if [[ -r "$scx_dir/root/ops" ]]; then
    read_file "$scx_dir/root/ops"
    scx_ops=$REPLY
  fi
fi

read_file "$(sysfs_path /proc/sys/vm/swappiness)"
swappiness=$REPLY
read_file "$(sysfs_path /sys/kernel/mm/transparent_hugepage/enabled)"
thp=$REPLY
[[ "$thp" =~ \[([a-z]+)\] ]] || die os "no bracketed value in transparent_hugepage/enabled"
thp=${BASH_REMATCH[1]}

IFS=,
printf 'source=%s bytes=%s items=9\n' "${files[*]}" "$bytes"
unset IFS
printf 'os.kernel=%s\n' "$kernel"
printf 'os.pstate_status=%s\n' "$pstate"
printf 'os.governor=%s\n' "$governor"
printf 'os.epp=%s\n' "$epp"
printf 'os.governors_uniform=%s\n' "$uniform"
printf 'os.scx_state=%s\n' "$scx_state"
printf 'os.scx_ops=%s\n' "$scx_ops"
printf 'os.swappiness=%s\n' "$swappiness"
printf 'os.thp=%s\n' "$thp"
