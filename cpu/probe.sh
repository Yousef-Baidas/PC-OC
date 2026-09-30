#!/usr/bin/env bash
set -euo pipefail
# Print current cpu values: line 1 source= bytes= items=, then cpu.<key>=<value>.
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

sources=()
bytes=0

# read_file <path>: set REPLY to the file's content, record path and size.
read_file() {
  [[ -r "$1" ]] || die cpu "cannot read $1"
  REPLY="$(<"$1")"
  sources+=("$1")
  bytes=$((bytes + $(wc -c <"$1")))
}

cpuinfo="$(sysfs_path /proc/cpuinfo)"
read_file "$cpuinfo"
model="$(sed -n 's/^model name[[:space:]]*: //p' <<<"$REPLY" | head -n1)"
microcode="$(sed -n 's/^microcode[[:space:]]*: //p' <<<"$REPLY" | head -n1)"
[[ -n "$model" ]] || die cpu "no model name in $cpuinfo"
[[ -n "$microcode" ]] || die cpu "no microcode in $cpuinfo"

rapl="$(sysfs_path /sys/class/powercap/intel-rapl:0)"
[[ -d "$rapl" ]] || die cpu "missing $rapl"
pl1_uw="" pl1_tau_us="" pl2_uw=""
for name_file in "$rapl"/constraint_*_name; do
  [[ -e "$name_file" ]] || die cpu "no constraints under $rapl"
  read_file "$name_file"
  n="${name_file##*/constraint_}"
  n="${n%_name}"
  case "$REPLY" in
    long_term)
      read_file "$rapl/constraint_${n}_power_limit_uw"
      pl1_uw="$REPLY"
      read_file "$rapl/constraint_${n}_time_window_us"
      pl1_tau_us="$REPLY"
      ;;
    short_term)
      read_file "$rapl/constraint_${n}_power_limit_uw"
      pl2_uw="$REPLY"
      ;;
  esac
done
[[ -n "$pl1_uw" ]] || die cpu "no long_term constraint under $rapl"
[[ -n "$pl2_uw" ]] || die cpu "no short_term constraint under $rapl"

out="cpu.model=$model
cpu.microcode=$microcode
cpu.pl1_uw=$pl1_uw
cpu.pl1_tau_us=$pl1_tau_us
cpu.pl2_uw=$pl2_uw"
src="$(
  IFS=,
  echo "${sources[*]}"
)"
printf 'source=%s bytes=%s items=%s\n%s\n' "$src" "$bytes" "$(wc -l <<<"$out")" "$out"
