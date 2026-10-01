#!/usr/bin/env bash
set -euo pipefail
# Print current ram values: the probe_emit header, then ram.<key>=<value>.
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

PROBE_COMPONENT=ram

meminfo="$(sysfs_path /proc/meminfo)"
probe_read "$meminfo"
total_kb="$(awk '/^MemTotal:/ {print $2}' <<<"$PROBE_CONTENT")"
[[ -n "$total_kb" ]] || die ram "no MemTotal in $meminfo"
pairs=(total_kb="$total_kb")

# Root only: dmidecode reads the SMBIOS table. Units: MT/s and V become bare numbers.
if [[ "$(id -u)" -eq 0 ]]; then
  dmi="$(command -v dmidecode)" || die ram "dmidecode not found"
  dump="$("$dmi" -t 17)" || die ram "dmidecode failed"
  probe_source "$dmi" "$(
    LC_ALL=C
    echo "${#dump}"
  )"
  dimms="$(
    awk -F': ' '
      function bad(f) {
        failed = 1
        print "ERR ram.dimm" n + 0 "." f
        exit 1
      }
      function num(v) { return v ~ /^[0-9]+(\.[0-9]+)?( |$)/ ? v + 0 : "" }
      function flush() {
        if (size != "" && size !~ /No Module/) {
          if (speed !~ /^[0-9]+$/) bad("speed_mts")
          else if (cfg !~ /^[0-9]+$/) bad("configured_mts")
          else if (part == "" || part == "Unknown" || part == "Not Specified") bad("part")
          else if (mv !~ /^[0-9]+$/) bad("configured_mv")
          printf "ram.dimm%d.speed_mts=%s\nram.dimm%d.configured_mts=%s\nram.dimm%d.part=%s\nram.dimm%d.configured_mv=%s\n",
            n, speed, n, cfg, n, part, n, mv
          n++
        }
        size = speed = cfg = part = mv = ""
      }
      /^Memory Device/ { flush() }
      $1 ~ /^\tSize$/ { size = $2 }
      $1 ~ /^\tSpeed$/ { speed = num($2) }
      $1 ~ /^\tConfigured Memory Speed$/ { cfg = num($2) }
      $1 ~ /^\tPart Number$/ { part = $2; sub(/[ \t]+$/, "", part) }
      $1 ~ /^\tConfigured Voltage$/ { mv = num($2) == "" ? "" : int(num($2) * 1000 + 0.5) }
      END { if (!failed) flush() }
    ' <<<"$dump"
  )" || die ram "populated slot has a missing or non-numeric value: ${dimms##*ERR }"
  [[ -n "$dimms" ]] || die ram "no populated DIMM in dmidecode -t 17"
  while IFS= read -r line; do pairs+=("${line#ram.}"); done <<<"$dimms"
else
  pairs+=(dmi=needs-root)
fi

probe_emit "${pairs[@]}"
