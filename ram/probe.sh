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
  probe_run dmidecode -t 17
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
    ' <<<"$PROBE_CONTENT"
  )" || die ram "populated slot has a missing or non-numeric value: ${dimms##*ERR }"
  [[ -n "$dimms" ]] || die ram "no populated DIMM in dmidecode -t 17"
  while IFS= read -r line; do pairs+=("${line#ram.}"); done <<<"$dimms"

  # SPD hub eeproms, sorted by device name. DDR5 SPD bytes 552-553 (0x228-0x229) hold the DRAM
  # manufacturer JEP106 ID, continuation byte first (JESD400-5C as relayed by the Bus Pirate DDR5
  # page and the i2c-tools decode-dimms DDR5 patch; the module maker is at 512-513).
  # src: kernel-spd5118,jep106
  shopt -s nullglob
  eeproms=("$(sysfs_path /sys/bus/i2c/drivers/spd5118)"/*/eeprom)
  shopt -u nullglob
  [[ -e "${eeproms[0]:-}" ]] || pairs+=(spd=no-spd5118)
  for k in "${!eeproms[@]}"; do
    eeprom="${eeproms[k]}"
    probe_read "$eeprom"
    id="$(od -An -tx1 -j552 -N2 "$eeprom" 2>/dev/null | tr -d ' \n')" || die ram "cannot read $eeprom"
    [[ "$id" =~ ^[0-9a-f]{4}$ ]] || die ram "cannot read $eeprom: DRAM maker is at bytes 552-553"
    case "${id^^}" in
      80AD) mfr=hynix ;;
      802C) mfr=micron ;;
      80CE) mfr=samsung ;;
      *) mfr="unknown:0x${id^^}" ;;
    esac
    dev="$(basename "$(dirname "$eeprom")")"
    pairs+=("spd$k.addr=$dev" "spd$k.dram_mfr=$mfr")
  done
else
  pairs+=(dmi=needs-root)
fi

probe_emit "${pairs[@]}"
