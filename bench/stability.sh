#!/usr/bin/env bash
set -euo pipefail
# stability.sh cpu|soak [minutes] | scan <since>: y-cruncher, stress-ng, then a kernel journal scan; PASS or FAIL.
# y-cruncher 0.8.7 CLI: /usr/share/doc/y-cruncher/USAGE, "Component Stress Tester"
# (stress -TL:<s> = total time limit; pause:-2 never waits for a key, even on errors).
# stress-ng(1): --cpu 0 = all CPUs, --cpu-method all, --vm-bytes as % of memory,
# --verify checks results; default 10 min is its `--cpu-method all --verify -t 10m` example.
# Journal errors: x86 MCE and APEI/GHES reports carry HW_ERR "[Hardware Error]: "
# (arch/x86/kernel/cpu/mce/core.c, drivers/acpi/apei/ghes.c); NVIDIA logs "NVRM: Xid (PCI:...)"
# per https://docs.nvidia.com/deploy/xid-errors/. A bare "mce:" prefix is not matched:
# the kernel also uses it for info lines (thermal monitoring, bank setup).
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ERROR_PATTERN='\[Hardware Error\]|Machine check|NVRM: Xid'

usage() {
  echo "pc-oc: bench: usage: stability.sh cpu|soak [minutes>=1] | scan <since>" >&2
  exit 2
}

inputs=()
results=()
tmp="$(mktemp -d)"
sampler=""

# stop_sampler: kill the sampler and its sleep, reap it; safe to call twice
stop_sampler() {
  [ -n "$sampler" ] || return 0
  pkill -P "$sampler" 2>/dev/null || true
  kill "$sampler" 2>/dev/null || true
  wait "$sampler" 2>/dev/null || true
  sampler=""
}
cleanup() {
  stop_sampler
  rm -rf "$tmp"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# sample_loop <out>: every STABILITY_SAMPLE_S seconds append "<ns> <vcore_mv|-> <energy_uj|-> <mhz|->"
# (probe keys cpu.vcore_mv, cpu.pkg_energy_uj from pc-oc probe cpu; clock from cpufreq, in kHz)
sample_loop() {
  local probe out vcore energy mhz now
  read -ra probe <<<"${PC_OC_PROBE:-sudo -n /usr/local/lib/pc-oc/pc-oc probe cpu}"
  while :; do
    out="$("${probe[@]}" 2>/dev/null </dev/null || true)"
    now="$(date +%s%N)"
    vcore="$(sed -n 's/^cpu\.vcore_mv=\([0-9][0-9]*\)$/\1/p' <<<"$out" | head -1)"
    energy="$(sed -n 's/^cpu\.pkg_energy_uj=\([0-9][0-9]*\)$/\1/p' <<<"$out" | head -1)"
    mhz="$(cat "${SYSFS_ROOT:-}"/sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq 2>/dev/null |
      awk '{ s += $1; n++ } END { if (n) printf "%d", s / n / 1000 }' || true)"
    echo "$now ${vcore:--} ${energy:--} ${mhz:--}" >>"$1"
    sleep "${STABILITY_SAMPLE_S:-5}"
  done
}

# summarize_samples <file>: print vcore_max_mv, pkg_w_avg, mhz_avg, samples (n/a when unknown).
# Energy delta over the sampler's own clock; a negative delta (counter wrap) drops that interval.
summarize_samples() {
  awk '
    $2 != "-" && (vmax == "" || $2 + 0 > vmax) { vmax = $2 + 0 }
    $4 != "-" { ms += $4; mn++ }
    $3 != "-" {
      if (have && $3 >= pe && $1 > pt) { de += $3 - pe; dt += ($1 - pt) / 1e9 }
      pe = $3; pt = $1; have = 1
    }
    END {
      printf "%s\n", (vmax == "" ? "n/a" : vmax)
      if (dt > 0) printf "%.1f\n", de / 1e6 / dt; else print "n/a"
      printf "%s\n", (mn ? sprintf("%d", ms / mn) : "n/a")
      print NR
    }' "$1"
}

# scan_journal <since>: kernel lines since <since> into results; their source goes first in inputs
scan_journal() {
  local first source_line bytes items
  need journalctl "pacman -S systemd"
  journalctl _TRANSPORT=kernel --since "$1" --no-pager -o short-iso >"$tmp/journal" ||
    die bench "journalctl failed"
  bytes="$(wc -c <"$tmp/journal")" || die bench "cannot read $tmp/journal"
  items="$(wc -l <"$tmp/journal")" || die bench "cannot read $tmp/journal"
  source_line="$(input_line "$(command -v journalctl)" "$bytes" "$items")" || exit 1
  inputs=("$source_line" "input.journalctl=$(journalctl --version | head -1)" "input.since=$1" "${inputs[@]}")
  first="$(grep -m1 -E "$ERROR_PATTERN" "$tmp/journal" || true)"
  if [ -n "$first" ]; then
    results+=(result.stability.journal=FAIL "result.stability.first_error=$first")
  else
    results+=(result.stability.journal=PASS)
  fi
}

case "${1:-}" in
  cpu | soak)
    mode="$1"
    minutes="${2:-$([ "$mode" = soak ] && echo 60 || echo 10)}"
    [[ "$minutes" =~ ^[1-9][0-9]*$ ]] || usage
    need y-cruncher "yay -S y-cruncher"
    need stress-ng "pacman -S stress-ng"
    yc_args=(skip-warnings colors:0 pause:-2 stress "-TL:$((minutes * 60))")
    sng_args=(--cpu 0 --cpu-method all --vm 4 --vm-bytes 80% --verify -t "$((minutes * 60))s")
    if [ "$mode" = soak ]; then
      # soak: memory-heavy only. stress-ng --vm-method all --verify checks every pattern;
      # y-cruncher stress components FFTv4, N63, VT3 are the large-memory ones (USAGE; the
      # BBP and small in-cache SFTv4/SNT/SVT components stay out)
      yc_args+=(FFTv4 N63 VT3)
      sng_args=(--vm "$(nproc)" --vm-bytes 85% --vm-method all --verify -t "$((minutes * 60))s")
    fi
    inputs+=("input.ycruncher=$(y-cruncher version </dev/null | sed -n '1s/\x1b\[[0-9;]*m//gp')")
    inputs+=("input.stressng=$(stress-ng --version)" "input.minutes=$minutes")
    [ "$mode" = soak ] && inputs+=("input.mode=soak")
    inputs+=("input.ycruncher_args=${yc_args[*]}" "input.stressng_args=${sng_args[*]}")
    since="$(date '+%Y-%m-%d %H:%M:%S')"
    # stdout is held until the end, so a crash would lose the window; name it now
    echo "pc-oc: bench: window starts $since; after a crash: stability.sh scan \"$since\"" >&2
    : >"$tmp/samples"
    sample_loop "$tmp/samples" >/dev/null 2>&1 &
    sampler=$!
    rc=0
    run_yc() {
      y-cruncher "${yc_args[@]}" </dev/null 2>&1 | tee "$tmp/ycruncher.log" >&2 || rc=$?
      if [ "$rc" -eq 0 ] && ! grep -q 'Stress test failed' "$tmp/ycruncher.log"; then
        results+=(result.stability.ycruncher=PASS)
      else
        results+=(result.stability.ycruncher=FAIL)
      fi
    }
    run_sng() {
      if stress-ng "${sng_args[@]}" >&2; then
        results+=(result.stability.stressng=PASS)
      else
        results+=(result.stability.stressng=FAIL)
      fi
    }
    if [ "$mode" = soak ]; then
      run_sng
      run_yc
    else
      run_yc
      run_sng
    fi
    stop_sampler
    mapfile -t tel < <(summarize_samples "$tmp/samples")
    inputs+=("input.telemetry.source=${PC_OC_PROBE:-sudo -n /usr/local/lib/pc-oc/pc-oc probe cpu} samples=${tel[3]}")
    results+=("result.stability.vcore_max_mv=${tel[0]}" "result.stability.pkg_w_avg=${tel[1]}" "result.stability.mhz_avg=${tel[2]}")
    [ "$mode" = soak ] && results+=("result.stability.soak_minutes=$minutes")
    scan_journal "$since"
    ;;
  scan)
    [ -n "${2:-}" ] || usage
    results+=(result.stability.ycruncher=SKIP result.stability.stressng=SKIP)
    scan_journal "$2"
    ;;
  *) usage ;;
esac

verdict=PASS
for r in "${results[@]}"; do
  [[ "$r" == result.stability.*=FAIL ]] && verdict=FAIL
done
printf '%s\n' "${inputs[@]}" "${results[@]}" "result.stability=$verdict"
[ "$verdict" = PASS ]
