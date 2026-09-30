#!/usr/bin/env bash
set -euo pipefail
# Print current ram values: line 1 source= bytes= items=, then ram.<key>=<value>.
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

meminfo="$(sysfs_path /proc/meminfo)"
[[ -r "$meminfo" ]] || die ram "cannot read $meminfo"
total_kb="$(awk '/^MemTotal:/ {print $2}' "$meminfo")"
[[ -n "$total_kb" ]] || die ram "no MemTotal in $meminfo"
sources="$meminfo"
bytes="$(wc -c <"$meminfo")"
out="ram.total_kb=$total_kb"

# Root only: dmidecode reads the SMBIOS table. Units: MT/s and V become bare numbers.
if [[ "$(id -u)" -eq 0 ]]; then
  dmi="$(command -v dmidecode)" || die ram "dmidecode not found"
  dump="$("$dmi" -t 17)" || die ram "dmidecode failed"
  sources="$sources,$dmi"
  bytes=$((bytes + ${#dump}))
  dimms="$(
    awk -F': ' '
      function flush() {
        if (size != "" && size !~ /No Module/) {
          printf "ram.dimm%d.speed_mts=%s\nram.dimm%d.configured_mts=%s\nram.dimm%d.part=%s\nram.dimm%d.configured_mv=%s\n",
            n, speed, n, cfg, n, part, n, mv
          n++
        }
        size = speed = cfg = part = mv = ""
      }
      /^Memory Device/ { flush() }
      $1 ~ /^\tSize$/ { size = $2 }
      $1 ~ /^\tSpeed$/ { speed = $2 + 0 }
      $1 ~ /^\tConfigured Memory Speed$/ { cfg = $2 + 0 }
      $1 ~ /^\tPart Number$/ { part = $2; sub(/[ \t]+$/, "", part) }
      $1 ~ /^\tConfigured Voltage$/ { mv = int($2 * 1000 + 0.5) }
      END { flush() }
    ' <<<"$dump"
  )"
  [[ -z "$dimms" ]] || out="$out"$'\n'"$dimms"
else
  out="$out"$'\nram.dmi=needs-root'
fi

printf 'source=%s bytes=%s items=%s\n%s\n' "$sources" "$bytes" "$(wc -l <<<"$out")" "$out"
