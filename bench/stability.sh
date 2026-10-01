#!/usr/bin/env bash
set -euo pipefail
# stability.sh cpu [minutes] | scan <since>: y-cruncher, stress-ng, then a kernel journal scan; PASS or FAIL.
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
  echo "pc-oc: bench: usage: stability.sh cpu [minutes>=1] | scan <since>" >&2
  exit 2
}

inputs=()
results=()
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

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
  cpu)
    minutes="${2:-10}"
    [[ "$minutes" =~ ^[1-9][0-9]*$ ]] || usage
    need y-cruncher "yay -S y-cruncher"
    need stress-ng "pacman -S stress-ng"
    yc_args=(skip-warnings colors:0 pause:-2 stress "-TL:$((minutes * 60))")
    sng_args=(--cpu 0 --cpu-method all --vm 4 --vm-bytes 80% --verify -t "$((minutes * 60))s")
    inputs+=("input.ycruncher=$(y-cruncher version </dev/null | sed -n '1s/\x1b\[[0-9;]*m//gp')")
    inputs+=("input.stressng=$(stress-ng --version)" "input.minutes=$minutes")
    inputs+=("input.ycruncher_args=${yc_args[*]}" "input.stressng_args=${sng_args[*]}")
    since="$(date '+%Y-%m-%d %H:%M:%S')"
    # stdout is held until the end, so a crash would lose the window; name it now
    echo "pc-oc: bench: window starts $since; after a crash: stability.sh scan \"$since\"" >&2
    rc=0
    y-cruncher "${yc_args[@]}" </dev/null 2>&1 | tee "$tmp/ycruncher.log" >&2 || rc=$?
    if [ "$rc" -eq 0 ] && ! grep -q 'Stress test failed' "$tmp/ycruncher.log"; then
      results+=(result.stability.ycruncher=PASS)
    else
      results+=(result.stability.ycruncher=FAIL)
    fi
    if stress-ng "${sng_args[@]}" >&2; then
      results+=(result.stability.stressng=PASS)
    else
      results+=(result.stability.stressng=FAIL)
    fi
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
