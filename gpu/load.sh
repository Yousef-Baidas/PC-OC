#!/usr/bin/env bash
set -euo pipefail
# load.sh check | core <warmup-s> <load-s> | mem <warmup-s> <load-s> <device-index>
# One self-checking GPU load for a fixed time, as your own user, never as root.
#   check  exit 0 when the gpu_burn build (gpu/burn-build.sh), /usr/bin/memtest_vulkan and
#          the NVIDIA Vulkan ICD file are there; else exit 3 and one line on stderr that
#          names the missing piece and the command that fixes it.
#   core   gpu_burn (gpu-burn) from its build directory, 80% of the free memory.
#   mem    memtest_vulkan (memtest-vulkan) on the NVIDIA ICD, device <device-index>.
# While the load runs the card is sampled once a second with nvidia-smi (smi); the kernel
# journal is read afterwards for NVRM: Xid lines newer than the cursor taken before the load
# (nv-xid). Raw output and samples go to a new directory under
# ${XDG_CACHE_HOME:-$HOME/.cache}/pc-oc/gpu-load/. Stdout carries the result block only:
#   result=pass|fail|invalid  reason=<word>  pstate_min=  core_mhz_max=  mem_mhz_max=
#   limited=0|1  power_cap=0|1  xid=<count>  read_gbs=<GB/s> (mem only)  log=<directory>
# A value that was not measured is empty. The pstate and clock keys, limited, power_cap and
# read_gbs use what was seen from the end of the warm-up on. power_cap=1 says the load ran
# at the power limit; it is no verdict. Exit 0 pass, 1 fail, 2 usage, 3 invalid.
# Fail-closed: whatever cannot be read or parsed is result=invalid. First match wins:
#   invalid  build memtest icd (the piece check names), log, journal, sample (nvidia-smi
#            failed or printed something else), nosample (none after the warm-up),
#            interrupted, internal
#   fail     xid; mem: device-lost
#   invalid  short (the load ended before warm-up + load seconds, whatever it printed and
#            whatever its status)
#   fail     core: faulty (FAULTY summary), errors (a non-zero error count);
#            mem: errors (Error found, or status bit 1)
#   invalid  core: timeout (killed by timeout), output, died (a burn process died), summary
#            (not exactly one summary line, GPU 0: OK), progress (no error count seen);
#            mem: exit (status not 65), output, noread (no read speed after the warm-up)
#   invalid  limited (a slowdown reason was active after the warm-up)
#   pass     ok
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
export LC_ALL=C

here="$(dirname "${BASH_SOURCE[0]}")"
MEMTEST=/usr/bin/memtest_vulkan
ICD=/usr/share/vulkan/icd.d/nvidia_icd.json
# gpu_burn (gpu-burn, gpu_burn-drv.cpp at the pinned commit): after the burn it sleeps for
# the whole SIGTERM threshold (-stts, default 30 s, lines 61 and 620) before the summary,
# so the threshold is cut to 5 s and timeout gets 60 s on top of the run for CUDA start-up
# plus that wait. The run length is the first argument after the options (lines 899-912).
BURN_MEM=80%
BURN_STTS_S=5
BURN_MARGIN_S=60
# seconds between timeout's signal and its SIGKILL
KILL_AFTER_S=10
# memtest_vulkan status byte (memtest-vulkan v0.5.0, src/close.rs): signature 0x40 under
# mask 0xe0, bit 0 init done, bit 1 runtime errors. 65 is a clean run ended by SIGINT.
MEMTEST_SIGNATURE=64
MEMTEST_SIGNATURE_MASK=224
MEMTEST_ERRORS_BIT=2
MEMTEST_CLEAN=65
# nvidia-smi --query-gpu fields (smi; each is in `nvidia-smi --help-query-gpu` of driver
# 615.71): the performance state, the graphics and memory clocks in MHz, the board power in
# W, the core temperature in C, then seven clock event reasons, each "Active" or "Not
# Active". All seven go into samples.csv; sample reads them by their place in this list:
#   power_cap=1  sw_power_cap: the power limit ("SW power cap limit can be changed with
#                nvidia-smi --power-limit="). No verdict.
#   limited=1    hw_slowdown, hw_thermal_slowdown, hw_power_brake_slowdown ("reducing the
#                core clocks by a factor of 2 or more") and sw_thermal_slowdown ("GPU
#                temperature is higher than Max Operating Temp"): a slowdown, and a load
#                under one proves nothing.
#   nothing      board_limit ("board-level voltage limit is being enforced") and
#                reliability ("to ensure part lifetime reliability projections"): the card
#                at its normal top clock.
# Source of the rule: that help text, and the loads at stock clocks on this card (#121
# comments 5953205480, 5953276937, 5953431584): clean, gpu_burn with sw_power_cap Active in
# every sample and memtest_vulkan with reliability Active in nearly every one. The other
# three, gpu_idle, applications_clocks_setting and sync_boost, are not read.
SMI_FIELDS=pstate,clocks.current.graphics,clocks.current.memory,power.draw,temperature.gpu
SMI_FIELDS+=,clocks_event_reasons.sw_power_cap,clocks_event_reasons.hw_slowdown
SMI_FIELDS+=,clocks_event_reasons.hw_thermal_slowdown
SMI_FIELDS+=,clocks_event_reasons.hw_power_brake_slowdown
SMI_FIELDS+=,clocks_event_reasons.sw_thermal_slowdown
SMI_FIELDS+=,clocks_event_reasons.board_limit,clocks_event_reasons.reliability
SAMPLE_RE='^P([0-9]{1,2}), ([0-9]+), ([0-9]+), [0-9]+(\.[0-9]+)?, [0-9]+((, (Active|Not Active)){7})$'
# a sample that hangs (a card off the bus) is a failed sample; our own choice of 5 s
SMI_TIMEOUT_S=5

usage() {
  echo "pc-oc: gpu: load: usage: load.sh check | core <warmup-s> <load-s> | mem <warmup-s> <load-s> <device-index>" >&2
  echo "  seconds 1 to 3600, device index 0 to 9" >&2
  exit 2
}

# build_gap: set build_dir, and gap to what is missing of the gpu_burn build (empty: none)
build_gap() {
  local -a pin=()
  gap="gpu/burn.pin is unreadable or malformed: restore it, then run $here/burn-build.sh"
  mapfile -t pin 2>/dev/null <"$here/burn.pin" || return 0
  # four lines, as burn-build.sh reads them
  [[ -v pin[3] && ! -v pin[4] && "${pin[0]}" =~ ^version=[0-9a-f]{40}$ &&
    "${pin[2]}" =~ ^sha256=[0-9a-f]{64}$ ]] || return 0
  build_dir="$cache/pc-oc/gpu-burn/${pin[0]#version=}"
  gap="no gpu_burn build for gpu/burn.pin in $build_dir: run $here/burn-build.sh"
  [[ -f "$build_dir/built" && -x "$build_dir/gpu_burn" && -f "$build_dir/compare.fatbin" ]] ||
    return 0
  [[ "$(<"$build_dir/built")" == "${pin[2]#sha256=}" ]] || return 0
  gap=""
}

# memtest_gap: set gap to what is missing for memtest_vulkan (empty: nothing), and
# gap_reason to the reason word for it
memtest_gap() {
  gap="" gap_reason=""
  if [[ ! -x "$MEMTEST" ]]; then
    gap="$MEMTEST is not executable: sudo pacman -S memtest_vulkan" gap_reason=memtest
  elif [[ ! -f "$ICD" ]]; then
    gap="$ICD is missing: sudo pacman -S nvidia-utils" gap_reason=icd
  fi
}

# finish <result> <reason>: print the result block, keep a copy in the log directory, exit
finish() {
  local block code=3
  block="$(
    printf 'result=%s\nreason=%s\n' "$1" "$2"
    printf 'pstate_min=%s\ncore_mhz_max=%s\nmem_mhz_max=%s\n' "$pstate_min" "$core_mhz_max" "$mem_mhz_max"
    printf 'limited=%s\npower_cap=%s\nxid=%s\n' "$limited" "$power_cap" "$xid"
    [[ "$kind" != mem ]] || printf 'read_gbs=%s\n' "$read_gbs"
    printf 'log=%s\n' "$log_dir"
  )"
  [[ -z "$log_dir" ]] || printf '%s\n' "$block" >"$log_dir/result" || :
  printf '%s\n' "$block"
  emitted=1
  case "$1" in
    pass) code=0 ;;
    fail) code=1 ;;
  esac
  exit "$code"
}

# stop_load: end a load that is still running, and the reader of its output
stop_load() {
  if [[ -n "$load_pid" ]]; then
    # timeout passes the signal on to the tool and kills it KILL_AFTER_S later
    kill -TERM "$load_pid" 2>/dev/null || :
    wait "$load_pid" 2>/dev/null || :
    load_pid=""
  fi
  if [[ -n "$stamp_pid" ]]; then
    kill "$stamp_pid" 2>/dev/null || :
    wait "$stamp_pid" 2>/dev/null || :
    stamp_pid=""
  fi
}

# on_exit: no load outlives this script, and no exit goes without a result block
# shellcheck disable=SC2329 # runs from the EXIT trap; every path ends in finish, which exits
on_exit() {
  local code=$?
  stop_load
  [[ -n "$emitted" ]] || finish invalid internal
  exit "$code"
}

# stamp_lines: copy stdin line by line, as it arrives, to fd 3 and, behind the milliseconds
# since start_us, to stdout
stamp_lines() {
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    printf '%s\n' "$line" >&3
    printf '%s %s\n' "$(((${EPOCHREALTIME/[.,]/} - start_us) / 1000))" "$line"
  done
}

# sample <elapsed-ms>: one nvidia-smi query, logged; from the end of the warm-up on it
# feeds the result keys. Returns 1 when nvidia-smi fails or prints anything else.
sample() {
  local out code=0 pstate cap slow
  out="$(timeout -k 2 "$SMI_TIMEOUT_S" nvidia-smi "--query-gpu=$SMI_FIELDS" \
    --format=csv,noheader,nounits 2>&1)" || code=$?
  printf '%s, %s\n' "$1" "${out//$'\n'/ | }" >>"$log_dir/samples.csv"
  ((code == 0)) || return 1
  [[ "$out" =~ $SAMPLE_RE ]] || return 1
  (($1 >= warmup * 1000)) || return 0
  pstate=$((10#${BASH_REMATCH[1]}))
  [[ -n "$pstate_min" ]] || pstate_min="$pstate" core_mhz_max=0 mem_mhz_max=0 limited=0 power_cap=0
  ((pstate >= pstate_min)) || pstate_min="$pstate"
  ((10#${BASH_REMATCH[2]} <= core_mhz_max)) || core_mhz_max=$((10#${BASH_REMATCH[2]}))
  ((10#${BASH_REMATCH[3]} <= mem_mhz_max)) || mem_mhz_max=$((10#${BASH_REMATCH[3]}))
  # the seven reason columns, in the order of SMI_FIELDS: the power cap, the four
  # slowdowns as one string, then board_limit and reliability, which are not looked at
  slow="${BASH_REMATCH[5]#, }"
  cap="${slow%%, *}"
  slow="${slow#*, }"
  slow=", ${slow%, *, *}"
  [[ "$cap" != Active ]] || power_cap=1
  [[ "$slow" != *", Active"* ]] || limited=1
}

# core_verdict: finish on what gpu_burn printed; returns when it is clean. Progress lines
# are separated by \r: "…  errors: <n> [(WARNING!)|(DIED!)] [- <n> …]  temps: …"; the summary
# is "Tested <n> GPUs:" then one "\tGPU <i>: OK|FAULTY" per card (gpu_burn-drv.cpp
# 552-592, 660-664). The exit code of gpu_burn is not used: main() returns 0 either way.
core_verdict() {
  local gpus ok faulty progress errors bad died
  read -r gpus ok faulty progress errors bad died < <(tr '\r' '\n' <"$log_dir/tool.out" | awk '
    /^Tested [0-9]+ GPUs:$/ { tested = 1; next }
    tested && /^\tGPU [0-9]+: / {
      gpus++
      if ($0 == "\tGPU 0: OK") ok++
      if ($0 ~ /: FAULTY$/) faulty++
      next
    }
    /errors: / {
      progress++
      s = $0
      sub(/^.*errors: /, "", s)
      sub(/temps: .*$/, "", s)
      # the count next to (DIED!) is an int that was never read (lines 505-517)
      if (s ~ /\(DIED!\)/) { died++; next }
      gsub(/\(WARNING!\)/, "", s)
      n = split(s, f, /[ -]+/)
      counts = 0
      for (i = 1; i <= n; i++) {
        if (f[i] == "") continue
        if (f[i] !~ /^[0-9]+$/) { bad++; continue }
        counts++
        if (f[i] + 0 != 0) errors++
      }
      if (!counts) bad++
    }
    END { printf "%d %d %d %d %d %d %d\n", gpus, ok, faulty, progress, errors, bad, died }')
  ((faulty == 0)) || finish fail faulty
  ((errors == 0)) || finish fail errors
  # 124: timeout ended the tool; 137: it took SIGKILL
  ((status != 124 && status != 137)) || finish invalid timeout
  [[ -n "$output_complete" ]] || finish invalid output
  ((bad == 0)) || finish invalid output
  ((died == 0)) || finish invalid died
  ((gpus == 1 && ok == 1)) || finish invalid summary
  ((progress > 0)) || finish invalid progress
}

# read_speed: set read_gbs to the median read speed memtest_vulkan printed after the
# warm-up, when it printed one. Read speed lines (src/main.rs:1085 at v0.5.0):
# "… written:<n>GB<n>GB/sec        checked:<n>GB<n>GB/sec", each <n> padded with spaces.
read_speed() {
  local speeds
  speeds="$(awk -v from="$((warmup * 1000))" '
    $1 + 0 >= from && match($0, /checked: *[0-9.]+GB *[0-9]+(\.[0-9]+)?GB\/sec/) {
      s = substr($0, RSTART, RLENGTH)
      sub(/GB\/sec$/, "", s)
      sub(/^.*GB */, "", s)
      print s
    }' "$log_dir/tool.stamped" | sort -g)"
  [[ -z "$speeds" ]] || read_gbs="$(awk '
    { v[NR] = $1 }
    END { printf "%.2f\n", NR % 2 ? v[(1 + NR) / 2] : (v[NR / 2] + v[1 + NR / 2]) / 2 }' <<<"$speeds")"
}

# mem_verdict: finish on what memtest_vulkan printed and its status byte; returns when it
# is clean
mem_verdict() {
  if grep -q -F "Error found" "$log_dir/tool.out" "$log_dir/tool.err"; then
    finish fail errors
  fi
  # bit 1 means errors only in a byte that carries the tool's signature
  if (((status & MEMTEST_SIGNATURE_MASK) == MEMTEST_SIGNATURE && (status & MEMTEST_ERRORS_BIT))); then
    finish fail errors
  fi
  ((status == MEMTEST_CLEAN)) || finish invalid exit
  [[ -n "$output_complete" ]] || finish invalid output
  [[ -n "$read_gbs" ]] || finish invalid noread
}

is_root && die gpu "load: run it as your own user, not root"

kind="${1:-}"
case "$kind" in
  check) (($# == 1)) || usage ;;
  core) (($# == 3)) || usage ;;
  mem) [[ $# -eq 4 && "$4" =~ ^[0-9]$ ]] || usage ;;
  *) usage ;;
esac
if [[ "$kind" != check ]]; then
  [[ "$2" =~ ^[1-9][0-9]{0,3}$ && "$3" =~ ^[1-9][0-9]{0,3}$ ]] || usage
  (($2 <= 3600 && $3 <= 3600)) || usage
fi

cache="${XDG_CACHE_HOME:-${HOME:+$HOME/.cache}}"
build_dir="" gap="" gap_reason=""

if [[ "$kind" == check ]]; then
  [[ "$cache" == /* ]] || gap="no cache directory: set HOME"
  [[ -n "$gap" ]] || build_gap
  [[ -n "$gap" ]] || memtest_gap
  [[ -z "$gap" ]] || {
    printf 'pc-oc: gpu: load: %s\n' "$gap" >&2
    exit 3
  }
  exit 0
fi

warmup="$2"
total=$(($2 + $3))
pstate_min="" core_mhz_max="" mem_mhz_max="" limited="" power_cap="" xid="" read_gbs="" log_dir=""
emitted="" load_pid="" stamp_pid="" interrupted="" output_complete="" ended_ms=""
trap on_exit EXIT
trap 'interrupted=1' INT TERM HUP

[[ "$cache" == /* ]] || {
  echo "pc-oc: gpu: load: no cache directory: set HOME" >&2
  finish invalid log
}
if [[ "$kind" == core ]]; then
  build_gap
  gap_reason=build
else
  memtest_gap
fi
[[ -z "$gap" ]] || {
  printf 'pc-oc: gpu: load: %s\n' "$gap" >&2
  finish invalid "$gap_reason"
}

# the log path is a value of the result block, so it has to fit the block's grammar
new_dir="$cache/pc-oc/gpu-load/$(date -u +%Y%m%dT%H%M%SZ)-$kind-$$"
if [[ "$new_dir" =~ ^[A-Za-z0-9._/-]+$ ]] && mkdir -p "${new_dir%/*}" && mkdir "$new_dir"; then
  log_dir="$new_dir"
else
  echo "pc-oc: gpu: load: cannot use $new_dir as the log directory" >&2
  finish invalid log
fi

if [[ "$kind" == core ]]; then
  run_dir="$build_dir"
  cmd=(timeout -k "$KILL_AFTER_S" "$((total + BURN_MARGIN_S))"
    ./gpu_burn -m "$BURN_MEM" -stts "$BURN_STTS_S" "$total")
else
  # memtest_vulkan writes memtest_vulkan.log into its working directory
  run_dir="$log_dir"
  cmd=(timeout --preserve-status -s INT -k "$KILL_AFTER_S" "$total" "$MEMTEST" "$4")
fi
printf '%s\n' "${cmd[*]}" >"$log_dir/command"
printf '# elapsed ms, %s\n' "$SMI_FIELDS" >"$log_dir/samples.csv"

cursor="$(journalctl -k -n 0 --show-cursor 2>"$log_dir/journal.err" |
  sed -n 's/^-- cursor: //p')" || cursor=""
[[ -n "$cursor" && ! -s "$log_dir/journal.err" ]] || finish invalid journal

# The tool writes into a FIFO that this shell holds open as well, so neither side blocks
# in open and the reader sees the end only when the shell lets go after the tool has exited.
mkfifo "$log_dir/pipe"
exec {keep}<>"$log_dir/pipe"
start_us="${EPOCHREALTIME/[.,]/}"
stamp_lines <"$log_dir/pipe" >"$log_dir/tool.stamped" 3>"$log_dir/tool.out" {keep}>&- &
stamp_pid=$!
(
  [[ "$kind" != mem ]] || export VK_DRIVER_FILES="$ICD"
  cd "$run_dir" && exec "${cmd[@]}"
) </dev/null >"$log_dir/pipe" 2>"$log_dir/tool.err" {keep}>&- &
load_pid=$!

# one sample at each whole second of the run, 0 to warm-up + load - 1, while the tool
# lives; what the card does after that (gpu_burn waiting out its shutdown) is not sampled
sample_bad="" second=0
while ((second < total)) && [[ -z "$interrupted" ]]; do
  now="${EPOCHREALTIME/[.,]/}"
  wait_us=$((start_us + second * 1000000 - now))
  if ((wait_us > 0)); then
    sleep "$(printf '%d.%06d' $((wait_us / 1000000)) $((wait_us % 1000000)))" || :
    continue
  fi
  kill -0 "$load_pid" 2>/dev/null || break
  # a late wake-up is not a sample of the run
  ((now - start_us < total * 1000000)) || break
  sample "$(((now - start_us) / 1000))" || {
    sample_bad=1
    break
  }
  second=$((1 + (${EPOCHREALTIME/[.,]/} - start_us) / 1000000))
done

status=0
if [[ -n "$sample_bad" || -n "$interrupted" ]]; then
  # nothing watches the card any more: the load ends here
  stop_load
else
  wait "$load_pid" || status=$?
  # when the load was seen to have ended, on the clock of the sample loop
  ended_ms=$(((${EPOCHREALTIME/[.,]/} - start_us) / 1000))
  if [[ -n "$interrupted" ]]; then
    stop_load
  else
    load_pid=""
    exec {keep}>&-
    # the reader ends with the tool's output; a stray process holding the pipe gets 5 s
    for _ in {1..50}; do
      kill -0 "$stamp_pid" 2>/dev/null || {
        output_complete=1
        break
      }
      sleep 0.1 || :
    done
    stop_load
  fi
fi
rm -f "$log_dir/pipe" || :
printf '%s\n' "$status" >"$log_dir/status"
printf '%s\n' "$ended_ms" >"$log_dir/ended"

journal_bad="" code=0
journalctl -k --after-cursor "$cursor" -g 'NVRM: Xid' \
  >"$log_dir/journal.txt" 2>"$log_dir/journal.err" || code=$?
if [[ -s "$log_dir/journal.err" ]]; then
  journal_bad=1
elif ((code == 0)); then
  xid="$(grep -c -F 'NVRM: Xid' "$log_dir/journal.txt")" || xid="" journal_bad=1
elif ((code == 1)) && [[ "$(<"$log_dir/journal.txt")" == "-- No entries --" ]]; then
  # journalctl -g exits 1 with this line when nothing matched
  xid=0
else
  journal_bad=1
fi

[[ -z "$interrupted" ]] || finish invalid interrupted
[[ -z "$journal_bad" ]] || finish invalid journal
[[ -z "$sample_bad" ]] || finish invalid sample
[[ -n "$pstate_min" ]] || finish invalid nosample
((xid == 0)) || finish fail xid
if [[ "$kind" == mem ]]; then
  read_speed
  # a lost device ends the load early by its nature and is evidence against the clocks
  if grep -q -F ERROR_DEVICE_LOST "$log_dir/tool.out" "$log_dir/tool.err"; then
    finish fail device-lost
  fi
fi
# no slack: a load that did not run its whole time proves nothing, whatever it printed
((ended_ms >= total * 1000)) || finish invalid short
if [[ "$kind" == core ]]; then core_verdict; else mem_verdict; fi
((limited == 0)) || finish invalid limited
finish pass ok
