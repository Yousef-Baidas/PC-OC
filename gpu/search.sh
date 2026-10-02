#!/usr/bin/bash
set -euo pipefail
# sudo pc-oc search gpu (#135): find the highest core and memory clock offsets this card
# holds under load, unattended, and write them to $(pc_oc_state)/gpu/search/result. Nothing
# is applied: gpu/apply.sh sets the two numbers from that file (gpu/offsets.md, step 12).
# A step is: write pending, set both offsets through nvml.py (ADR 0003), run one
# gpu/load.sh as the calling user, judge its result block, append a line to log, remove
# pending. Baseline at offsets 0, then the core phase, the memory phase and one soak of
# both stored values, all from gpu/search.values. Every way out of a started search runs
# nvml.py zero. A step that gives no verdict (invalid block, Xid, a failed helper call, a
# load over its time cap, a signal, a crash) ends the search and leaves pending behind: the
# next start counts that step as failed and goes on from there.
# State directory, root-owned and locked for the whole run:
#   pending   "phase=<p> core=<mhz> mem=<mhz> boot_id=<id>" while a step runs
#   log       "<utc> phase=<p> core=<mhz> mem=<mhz> result=<r> reason=<word>" per step, and
#             behind it " clock=unchecked" (a core load that passed without the core clock
#             check) or " core_clock_delta=<mhz>" (a memory load at a core offset); the two
#             lines the search ends with ahead of its result are read from these (#150)
#   result    core_offset_mhz=, mem_offset_mhz=, finished=<utc>
#   baseline  core_mhz_max=, mem_mhz_max=, read_gbs=, core_power_cap=, mem_core_mhz_max= of
#             the two loads at offsets 0
#   progress  how far the phases and the soak are
#   block     stdout of the last load; timer: a fifo nobody writes to, read -t on it waits
export PATH=/usr/bin LC_ALL=C
umask 022
# Whoever reads stdout or stderr may have left (| head, a pager that was quit, tee after
# Ctrl+C). SIGPIPE is ignored, so a print into such a pipe fails and does not kill the
# search above its zero. The one rule for a print that fails: it sets unheard and decides
# nothing where it happens. The verdict of a step, its log line, the state files, the zero
# and the exit status of that way out are what they are with a reader. A search that has
# lost its reader then starts no further load and never says 0: stop_unheard ends it where
# no step is open. die (lib/common.sh) prints unguarded, before any step: there set -e
# ends the start with the exit 1 die gives.
trap '' PIPE
here="$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=../lib/common.sh
source "$here/../lib/common.sh"
# shellcheck source=../lib/write.sh
source "$here/../lib/write.sh"
# shellcheck source=pl.sh
source "$here/pl.sh"

again="Run sudo pc-oc search gpu again to go on; reboot first if the screen froze or an Xid was logged."

# nvml <args>: run the helper the one way it may be run: isolated mode, absolute interpreter
nvml() {
  /usr/bin/python3 -I "$here/nvml.py" "$@"
}

# calling_user: the rule of pc-oc (#117), repeated here: SUDO_UID and SUDO_GID are ASCII
# digits below 2^32 - 1, the uid is not 0 and its passwd home is absolute. Sets home.
home=""
calling_user() {
  local id entry
  for id in "${SUDO_UID-}" "${SUDO_GID-}"; do
    [[ "$id" =~ ^[0123456789]{1,10}$ ]] || return 1
    ((10#$id < 4294967295)) || return 1
  done
  ((10#$SUDO_UID != 0)) || return 1
  entry="$(/usr/bin/getent passwd "$SUDO_UID")" || return 1
  IFS=: read -r _ _ _ _ _ home _ <<<"$entry"
  [[ "$home" == /* ]]
}

is_root || die gpu "search: not root: run sudo pc-oc search gpu"
calling_user || die gpu "search: no calling user (SUDO_UID, SUDO_GID): run sudo pc-oc search gpu"

# gpu/search.values: the eighteen keys, once each, nothing else; v holds them
keys=(core_start_mhz core_step_mhz core_max_mhz core_margin_mhz core_warmup_s core_load_s
  core_soak_s mem_start_mhz mem_step_mhz mem_max_mhz mem_margin_mhz mem_warmup_s mem_load_s
  mem_soak_s mem_drop_pct mem_device_index soak_backoffs load_grace_s)
declare -A v=()
[[ -r "$here/search.values" ]] || die gpu "search: cannot read $here/search.values"
while IFS= read -r line || [[ -n "$line" ]]; do
  [[ "$line" =~ ^([a-z_]+)=(0|[1-9][0-9]{0,3})([[:space:]]|$) ]] ||
    die gpu "search: $here/search.values: not <key>=<0 to 9999, no sign, no leading zero>: $line"
  key="${BASH_REMATCH[1]}"
  [[ " ${keys[*]} " == *" $key "* ]] || die gpu "search: $here/search.values: unknown key $key"
  [[ -z "${v[$key]-}" ]] || die gpu "search: $here/search.values: $key is there twice"
  v[$key]="${BASH_REMATCH[2]}"
done <"$here/search.values"
for key in "${keys[@]}"; do
  [[ -n "${v[$key]-}" ]] || die gpu "search: $here/search.values: no $key"
done
# the helper's own caps (nvml-offset-t) and the seconds gpu/load.sh takes
((v[core_max_mhz] <= 300)) || die gpu "search: $here/search.values: core_max_mhz above 300"
((v[mem_max_mhz] <= 2000)) || die gpu "search: $here/search.values: mem_max_mhz above 2000"
for key in core mem; do
  ((v[${key}_start_mhz] <= v[${key}_max_mhz])) ||
    die gpu "search: $here/search.values: ${key}_start_mhz above ${key}_max_mhz"
  ((v[${key}_step_mhz] >= 15 && v[${key}_margin_mhz] >= 15)) ||
    die gpu "search: $here/search.values: ${key}_step_mhz or ${key}_margin_mhz below 15"
done
for key in "${keys[@]}"; do
  [[ "$key" != *_s ]] || ((v[$key] >= 1 && v[$key] <= 3600)) ||
    die gpu "search: $here/search.values: $key outside 1 to 3600"
done
((v[mem_device_index] <= 9)) || die gpu "search: $here/search.values: mem_device_index above 9"
((v[mem_drop_pct] < 100)) || die gpu "search: $here/search.values: mem_drop_pct is not below 100"

pl_w=""
[[ -r "$here/values" ]] || die gpu "search: cannot read $here/values"
while IFS= read -r line || [[ -n "$line" ]]; do
  if [[ "$line" =~ ^pl_w=([1-9][0-9]{0,3})([[:space:]]|$) ]]; then pl_w="${BASH_REMATCH[1]}"; fi
done <"$here/values"
[[ -n "$pl_w" ]] || die gpu "search: no pl_w in $here/values"

{ boot_id="$(</proc/sys/kernel/random/boot_id)"; } 2>/dev/null || boot_id=""
[[ "$boot_id" =~ ^[0-9a-f-]{36}$ ]] || die gpu "search: cannot read the boot id"

# every load, the check included: as the calling user, with nothing of root's environment
caller=(/usr/bin/setpriv --reuid="$SUDO_UID" --regid="$SUDO_GID" --init-groups
  /usr/bin/env -i HOME="$home" PATH=/usr/bin /usr/bin/bash "$here/load.sh")

state="$(pc_oc_state)/gpu/search"

armed="" hold="" signalled="" unheard="" load_pid="" timer_pid="" load_rc=0
step="" step_logged="" verdict="" reason="" field=""
base_core="" base_mem="" base_gbs="" base_cap="" base_mem_core=""
declare -A p=() b=()
progress_keys=(core_last core_stored mem_last mem_stored soak_core soak_mem core_backoffs
  mem_backoffs core_soaked mem_soaked)

# stop <message>: the way out of a start that holds the lock. INT, TERM and HUP are ignored
# from here on, so on_exit runs once and to its end.
stop() {
  trap '' INT TERM HUP
  printf 'pc-oc: gpu: search: %s\n' "$1" >&2 || unheard=1
  exit 1
}

# stop_unheard: a print has failed, so nobody reads this search any more. Called where no
# step is open: it ends there as on a signal, and the next start goes on from that point.
stop_unheard() {
  [[ -z "$unheard" ]] ||
    stop "a line could not be printed (stdout or stderr is closed): the search ends here. $again"
}

# shout: nvml.py zero failed, so an offset of this search may still be set
shout() {
  printf 'pc-oc: gpu: search: NVML.PY ZERO FAILED: THE CLOCK OFFSETS MAY STILL BE SET. Run sudo reboot to clear them.\n' >&2 || unheard=1
}

# put <name> <line>...: write a state file whole or not at all, and onto the disk: a
# frozen card is reset by hand, and the next start must find what this one knew
put() {
  local name="$1"
  shift
  if ! printf '%s\n' "$@" >"$state/$name.new" || ! sync -- "$state/$name.new" ||
    ! mv -f -- "$state/$name.new" "$state/$name" || ! sync -- "$state"; then
    stop "cannot write $state/$name"
  fi
}

# log_step <result> <reason> [field]: one line of the log for the step at hand, and the same
# on stdout; the field of #150, with its leading space, ends both. Nothing here may wait:
# on_exit and the start that finds a pending step call it with an offset set, ahead of zero.
# A signal is only noted until the line is written and known to be: on_exit would write
# the step a second time otherwise.
log_step() {
  local held="$hold"
  hold=1
  printf '%s result=%s reason=%s%s\n' "$step" "$1" "$2" "${3-}" || unheard=1
  printf '%s %s result=%s reason=%s%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$step" "$1" "$2" "${3-}" >>"$state/log"
  step_logged=1
  hold="$held"
  [[ -n "$hold" || -z "$signalled" ]] || stop "got a signal: the search ends here. $again"
}

# load_ended: the load has left; as a child not yet waited for it is a zombie then
load_ended() {
  local stat
  { stat="$(<"/proc/$load_pid/stat")"; } 2>/dev/null || return 0
  [[ "${stat##*) }" == Z* ]]
}

# session_left [KILL]: is a process of the load's session left. setsid made the load the
# leader of its own session, so the session id is the load's pid, and a tool that
# gpu/load.sh starts under timeout(1) is in that session though in a process group of its
# own. The members are found in /proc by that id alone: no name, no pattern. Without an
# argument a zombie counts; with KILL every member gets KILL and those not yet dead count.
session_left() {
  local f stat state sid left=1
  for f in /proc/[0-9]*/stat; do
    { stat="$(<"$f")"; } 2>/dev/null || continue
    read -r state _ _ sid _ <<<"${stat##*) }"
    [[ "$sid" == "$load_pid" ]] || continue
    if [[ -z "${1-}" ]]; then
      left=0
      continue
    fi
    f="${f#/proc/}"
    kill -KILL "${f%/stat}" 2>/dev/null || true
    [[ "$state" == Z ]] || left=0
  done
  return "$left"
}

# stop_load: end the load that is running: TERM, up to 5 s for it to leave, then KILL for
# every process of its session until none of them runs, and wait until nothing of that
# session is left, zombies included. The KILLs go out while the load is not yet waited
# for, so its pid, the session id, cannot have gone to another process; after the wait
# the session is only looked at.
stop_load() {
  local end
  kill -TERM "$load_pid" 2>/dev/null || true
  end=$((${EPOCHREALTIME/./} + 5000000))
  until load_ended || ((${EPOCHREALTIME/./} >= end)); do
    read -rt 0.1 _ <>"$state/timer" || true
  done
  end=$((${EPOCHREALTIME/./} + 5000000))
  while session_left KILL && ((${EPOCHREALTIME/./} < end)); do
    read -rt 0.05 _ <>"$state/timer" || true
  done
  wait "$load_pid" 2>/dev/null || true
  end=$((${EPOCHREALTIME/./} + 5000000))
  while session_left && ((${EPOCHREALTIME/./} < end)); do
    read -rt 0.05 _ <>"$state/timer" || true
  done
  load_pid=""
}

# on_exit: every way out. The load is ended and waited for first, then a step that got no
# log line gets one, then zero; a failed zero is exit 1 whatever the search had reached.
on_exit() {
  local status=$?
  trap '' INT TERM HUP
  set +e
  hold=1
  if [[ -n "$timer_pid" ]]; then
    kill -KILL "$timer_pid" 2>/dev/null
    wait "$timer_pid" 2>/dev/null
  fi
  [[ -z "$load_pid" ]] || stop_load
  if [[ -n "$step" && -z "$step_logged" ]]; then
    if [[ -n "$signalled" ]]; then log_step invalid signal; else log_step invalid error; fi
  fi
  if [[ -n "$armed" ]] && ! nvml zero >/dev/null; then
    shout
    status=1
  fi
  exit "$status"
}

# on_signal: INT, TERM or HUP. While run_load starts and waits it only notes the signal
# (the wait returns at once and run_load leaves); anywhere else it is the way out.
on_signal() {
  signalled=1
  [[ -n "$hold" ]] || stop "got a signal: the search ends here. $again"
}
trap on_exit EXIT
trap on_signal INT TERM HUP

# The lock is taken with the traps in place and a signal only noted, so no way out lies
# between holding the lock and knowing whether a step is pending. A pending file is a
# step whose offsets may still be set: with it, every way out from here runs nvml.py zero.
hold=1
mkdir -p "$state" || die gpu "search: cannot create $state"
exec 9<"$state"
flock -n 9 || die gpu "search: already running"
[[ ! -e "$state/pending" ]] || armed=1
hold=""
[[ -z "$signalled" ]] || stop "got a signal: the search ends here. $again"

# save_progress: write p to the progress file
save_progress() {
  local key
  local -a lines=()
  for key in "${progress_keys[@]}"; do
    [[ -z "${p[$key]-}" ]] || lines+=("$key=${p[$key]}")
  done
  put progress "${lines[@]}"
}

# end_phase <core|mem>: the phase is over: store its last passing offset less the margin,
# never below 0, and 0 when no step passed
end_phase() {
  local clock="$1" last="${p[${1}_last]-}" stored=0
  [[ -z "$last" ]] || ((last <= v[${clock}_margin_mhz])) || stored=$((last - v[${clock}_margin_mhz]))
  p[${clock}_stored]="$stored"
  save_progress
}

# back_off <core|mem>: a soak of that clock failed: one step lower, never below 0; after
# soak_backoffs of them the clock is 0
back_off() {
  local clock="$1" lower=0 at="${p[soak_$1]}" by="${v[${1}_step_mhz]}" count="${p[${1}_backoffs]}"
  if ((count < v[soak_backoffs] && at > by)); then lower=$((at - by)); fi
  ((count += 1))
  p[${clock}_backoffs]="$count"
  p[soak_$clock]="$lower"
  save_progress
}

# end_search <result> <reason> <what happened>: the step ends the whole search. It is
# logged and pending stays, so the next start counts it as failed.
end_search() {
  log_step "$1" "$2" "$field"
  stop "$3: the search ends here. $again"
}

# read_offsets: nvml.py get. Sets any_offset when an offset on any pstate and clock is not
# 0; fails when the helper does, or prints something other than its lines.
any_offset=""
read_offsets() {
  local out line seen=""
  out="$(nvml get)" || return 1
  while IFS= read -r line; do
    if [[ "$line" =~ ^p[0-9]+\.(core|mem)\ offset=(-?[0-9]+)\ min=-?[0-9]+\ max=-?[0-9]+$ ]]; then
      seen=1
      [[ "${BASH_REMATCH[2]}" == 0 ]] || any_offset=1
    elif [[ ! "$line" =~ ^p[0-9]+\.(core|mem)\ unsupported$ ]]; then
      return 1
    fi
  done <<<"$out"
  [[ -n "$seen" ]]
}

# read_block <kind>: the result block of #134 from $state/block into b. The block is a
# statement by the calling user's account: every line is in the grammar, every key of the
# kind is there once and no other, and the exit status says what result= says. Else it
# fails, with the reason set. No value is used as an offset, a path or a command, and the
# log= directory is never opened.
read_block() {
  local kind="$1" line key n=0
  local -a want=(result reason pstate_min core_mhz_max mem_mhz_max limited power_cap xid log)
  [[ "$kind" != mem ]] || want+=(read_gbs)
  b=()
  reason=block
  (($(stat -c %s -- "$state/block") <= 4096)) || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    ((n += 1))
    ((n <= 16)) || return 1
    [[ "$line" =~ ^([a-z_]+)=([A-Za-z0-9._/-]*)$ ]] || return 1
    key="${BASH_REMATCH[1]}"
    [[ " ${want[*]} " == *" $key "* && -z "${b[$key]+set}" ]] || return 1
    b[$key]="${BASH_REMATCH[2]}"
  done < <(head -c 4096 -- "$state/block")
  for key in "${want[@]}"; do
    [[ -n "${b[$key]+set}" ]] || return 1
  done
  [[ "${b[reason]}" =~ ^[a-z0-9_-]+$ ]] || return 1
  reason=status
  case "${b[result]} $load_rc" in
    "pass 0" | "fail 1" | "invalid 3") ;;
    *) return 1 ;;
  esac
}

# judge <phase> <kind> <core mhz> <mem mhz>: set verdict, reason and field for the load
# that just ended at these offsets. pass: the load says so, in pstate 0 to 2, at the clock
# the offset of its kind asks for, and for memory at a read speed no more than mem_drop_pct
# under the baseline. fail: the load says so, or the read speed dropped. invalid: no
# verdict. field is what the step's line ends with (log_step), empty for most.
judge() {
  local phase="$1" kind="$2" mhz="$3" got frac gbs=""
  [[ "$kind" == core ]] || mhz="$4"
  verdict=invalid field=""
  read_block "$kind" || return 0
  # A memory load at a core offset says how far the core clock is from the one under the
  # memory baseline. It is a measurement and no check: whatever the load's result, and no
  # verdict depends on it (#150).
  if [[ "$kind" == mem && "$3" != 0 && "${b[core_mhz_max]}" =~ ^[1-9][0-9]{0,4}$ ]]; then
    field=" core_clock_delta=$((b[core_mhz_max] - base_mem_core))"
  fi
  reason="${b[reason]}"
  [[ "${b[result]}" != invalid ]] || return 0
  if [[ "${b[result]}" == fail ]]; then
    verdict=fail
    return 0
  fi
  reason=block
  [[ "${b[xid]}" == 0 && "${b[limited]}" == 0 && "${b[power_cap]}" =~ ^[01]$ ]] || return 0
  got="${b[${kind}_mhz_max]}"
  [[ "$got" =~ ^[1-9][0-9]{0,4}$ ]] || return 0
  if [[ "$kind" == mem ]]; then
    # its core clock goes into the baseline file and into core_clock_delta
    [[ "${b[core_mhz_max]}" =~ ^[1-9][0-9]{0,4}$ ]] || return 0
    # GB/s in thousandths, so the comparison is in whole numbers
    [[ "${b[read_gbs]}" =~ ^([0-9]{1,5})(\.([0-9]{1,3}))?$ ]] || return 0
    frac="${BASH_REMATCH[3]}000"
    gbs=$((10#${BASH_REMATCH[1]} * 1000 + 10#${frac:0:3}))
    ((gbs > 0)) || return 0
  fi
  reason=pstate
  [[ "${b[pstate_min]}" =~ ^[012]$ ]] || return 0
  if [[ "$phase" != baseline ]]; then
    reason=clock
    if [[ "$kind" == mem ]]; then
      # 5 MHz either way is our own choice, no source gives it: room for a reading that is
      # rounded, and far under the 100 MHz or more that an offset in another unit is off
      # by at the first memory step (mem_start_mhz=200)
      ((got - base_mem - mhz <= 5 && base_mem + mhz - got <= 5)) || return 0
      if ((gbs * 100 < base_gbs * (100 - v[mem_drop_pct]))); then
        verdict=fail reason=throughput
        return 0
      fi
    elif [[ "$base_cap" == 0 && "${b[power_cap]}" == 0 ]]; then
      # src: research-111 (15 MHz is one core clock bin of this card); the pre-flight on
      # the card saw the clock move in 15 MHz units (#121 comment 5953276937)
      ((got >= base_core + mhz - 15)) || return 0
    else
      # At the power limit the limit sets the core clock, not the offset: two gpu_burn runs
      # at stock, sw_power_cap Active in every sample, read 2460 and 2475 MHz as their
      # maximum, with the clock between 2130 and 2475 (#121 comments 5953205480 and
      # 5953276937). Against baseline + offset that is noise, so a core load that was
      # capped, or whose baseline was, is not checked, and its line says so.
      field=" clock=unchecked"
    fi
  fi
  verdict=pass reason="${b[reason]}"
}

# run_load <kind> <load seconds>: one load, capped at warm-up + load + load_grace_s seconds
run_load() {
  local kind="$1" seconds="$2" warmup="${v[${1}_warmup_s]}"
  local -a args=("$kind" "$warmup" "$seconds")
  [[ "$kind" != mem ]] || args+=("${v[mem_device_index]}")
  run_capped "$((warmup + seconds + v[load_grace_s]))" "the $kind load of the step $step" "${args[@]}"
}

# run_capped <cap seconds> <what it is, for the message> <gpu/load.sh arguments>...: one
# gpu/load.sh as the calling user; its stdout goes to $state/block, its exit status to
# load_rc. It is a job of this shell itself, in its own session, so the pid waited for is
# the load and its session is all it started. One that is not back after the cap
# ends the search: on_exit ends it. The load gets SIGPIPE at its default action back: only
# a subshell of this shell can undo the ignore this shell set, a bash started anew cannot.
run_capped() {
  local cap="$1" what="$2" who=""
  shift 2
  rm -f -- "$state/block"
  hold=1
  (trap - PIPE && exec /usr/bin/setsid "${caller[@]}" "$@") >"$state/block" &
  load_pid=$!
  { read -rt "$cap" _ <>"$state/timer" || true; } >/dev/null 2>&1 9>&- &
  timer_pid=$!
  load_rc=0
  [[ -n "$signalled" ]] || wait -n -p who "$load_pid" "$timer_pid" 2>/dev/null || load_rc=$?
  case "${who-}" in
    "$load_pid") load_pid="" ;;
    "$timer_pid") timer_pid="" ;;
  esac
  hold=""
  [[ -z "$signalled" ]] || stop "got a signal: the search ends here. $again"
  if [[ -z "$timer_pid" ]]; then
    [[ -z "$step" ]] || log_step invalid timeout
    stop "timeout: $what is not back after $cap s and is ended: the search ends here. $again"
  fi
  kill -KILL "$timer_pid" 2>/dev/null || true
  wait "$timer_pid" 2>/dev/null || true
  timer_pid=""
}

# run_step <phase> <kind> <core mhz> <mem mhz> <load seconds>: one step. Returns with
# verdict pass or fail and the step logged; anything else ends the search here.
run_step() {
  local phase="$1" kind="$2" core="$3" mem="$4" seconds="$5"
  stop_unheard
  step="phase=$phase core=$core mem=$mem" step_logged="" field=""
  put pending "$step boot_id=$boot_id"
  # a set that fails or is killed may have written some performance states: zero follows
  nvml set core "$core" >/dev/null || end_search invalid set "nvml.py set core $core failed"
  nvml set mem "$mem" >/dev/null || end_search invalid set "nvml.py set mem $mem failed"
  run_load "$kind" "$seconds"
  judge "$phase" "$kind" "$core" "$mem"
  case "$verdict $reason" in
    "fail xid") end_search fail xid "an Xid was logged during the step $step" ;;
    "invalid clock")
      # the first memory step measures the unit of the NVML memory offset (#121): no
      # failed step, and a start that changes nothing stops here again
      if [[ "$phase" == mem && -z "${p[mem_last]-}" ]]; then
        log_step invalid clock
        rm -f -- "$state/pending"
        stop "the memory clock moved by $((b[mem_mhz_max] - base_mem)) MHz at the first memory step, where an offset of $mem MHz was set: the unit of the NVML memory offset is not the one gpu/search.values assumes"
      fi
      end_search invalid clock "the $kind clock is not at the offset of the step $step"
      ;;
    invalid*) end_search invalid "$reason" "the load of the step $step gave no verdict (reason=$reason)" ;;
  esac
  log_step "$verdict" "$reason" "$field"
}

# close_step: the step is judged, logged and counted
close_step() {
  rm -f -- "$state/pending"
  step=""
}

# baseline_load <kind>: one load at offsets 0, nothing set. It must pass in pstate 0 to 2:
# these are the facts the steps stand on (#121).
baseline_load() {
  local kind="$1" hint=""
  stop_unheard
  step="phase=baseline-$kind core=0 mem=0" step_logged=""
  run_load "$kind" "${v[${kind}_load_s]}"
  judge baseline "$kind" 0 0
  log_step "$verdict" "$reason"
  step=""
  [[ "$kind" != mem ]] ||
    hint=" (if memtest_vulkan ran on another device, mem_device_index=${v[mem_device_index]} in gpu/search.values is wrong)"
  case "$verdict $reason" in
    pass*) ;;
    "invalid pstate") stop "the $kind load at stock clocks only reached pstate ${b[pstate_min]}, and the offsets act on pstates 0 to 2: nothing was set$hint" ;;
    fail*) stop "the $kind load fails at stock clocks (reason=$reason): nothing was set$hint" ;;
    *) stop "the $kind load at stock clocks gave no verdict (reason=$reason): nothing was set$hint" ;;
  esac
}

# phase <core|mem>: step that clock up from its start, the other at 0, until a step fails
# or the next one would be above its maximum
phase() {
  local clock="$1" next core=0 mem=0
  while [[ -z "${p[${clock}_stored]-}" ]]; do
    next="${v[${clock}_start_mhz]}"
    [[ -z "${p[${clock}_last]-}" ]] || next=$((p[${clock}_last] + v[${clock}_step_mhz]))
    if ((next > v[${clock}_max_mhz])); then
      end_phase "$clock"
      break
    fi
    if [[ "$clock" == core ]]; then core="$next"; else mem="$next"; fi
    run_step "$clock" "$clock" "$core" "$mem" "${v[${clock}_load_s]}"
    if [[ "$verdict" == pass ]]; then
      p[${clock}_last]="$next"
      save_progress
    else
      end_phase "$clock"
    fi
    close_step
  done
}

# soak <core|mem>: both stored values set, that clock's load for its soak seconds. A soak
# that fails lowers that clock and is repeated; a clock at 0 has nothing to soak.
soak() {
  local clock="$1"
  while [[ "${p[soak_$clock]}" != 0 && -z "${p[${clock}_soaked]-}" ]]; do
    run_step "soak-$clock" "$clock" "${p[soak_core]}" "${p[soak_mem]}" "${v[${clock}_soak_s]}"
    if [[ "$verdict" == pass ]]; then
      p[${clock}_soaked]=1
      save_progress
    else
      back_off "$clock"
    fi
    close_step
  done
}

# report: the result file on stdout, and what to do with it. Ahead of it, what the log says
# the result does not stand on (#150): a core load that passed without the core clock check,
# in this start or an earlier one, and what the last memory soak at a core offset measured.
# Nothing of the log is used as a number here: its lines are matched and printed.
report() {
  local line unchecked="" moved=""
  if [[ -r "$state/log" ]]; then
    while IFS= read -r line; do
      if [[ "$line" =~ ^[^\ ]+\ phase=(core|soak-core)\ .*\ clock=unchecked$ ]]; then
        unchecked=1
      elif [[ "$line" =~ ^[^\ ]+\ phase=soak-mem\ core=([1-9][0-9]{0,3})\ .*\ core_clock_delta=(-?[0-9]{1,5})$ ]]; then
        moved="core offset ${BASH_REMATCH[1]} MHz moved the core clock by ${BASH_REMATCH[2]} MHz under the memory load"
      fi
    done <"$state/log"
  fi
  [[ -z "$unchecked" ]] ||
    printf 'pc-oc: gpu: search: the core load ran at the power limit, so the core clock was not checked against the offset\n' || unheard=1
  [[ -z "$moved" ]] || printf 'pc-oc: gpu: search: %s\n' "$moved" || unheard=1
  cat -- "$state/result" || unheard=1
  printf 'pc-oc: gpu: search: finished. These offsets are not applied yet: gpu/offsets.md says how. The log is %s\n' "$state/log" || unheard=1
}

[[ -p "$state/timer" ]] || mkfifo -- "$state/timer" || stop "cannot create $state/timer"
if [[ -e "$state/progress" ]]; then
  while IFS= read -r line; do
    [[ "$line" =~ ^([a-z_]+)=(0|[1-9][0-9]{0,3})$ && " ${progress_keys[*]} " == *" ${BASH_REMATCH[1]} "* ]] ||
      stop "$state/progress does not parse: remove $state to start the search over"
    p[${BASH_REMATCH[1]}]="${BASH_REMATCH[2]}"
  done <"$state/progress"
fi

# a pending file is a step that never got its verdict: the search died in it, or ended on it
if [[ -e "$state/pending" ]]; then
  crashed="$(<"$state/pending")"
  read_offsets || any_offset=unknown
  if [[ "$crashed" =~ ^phase=(core|mem|soak-core|soak-mem)\ core=(0|[1-9][0-9]{0,3})\ mem=(0|[1-9][0-9]{0,3})\ boot_id=([0-9a-f-]{36})$ ]]; then
    crashed_phase="${BASH_REMATCH[1]}" crashed_boot="${BASH_REMATCH[4]}"
    step="${crashed% boot_id=*}"
    # a start that ended on this step logged it already, and set the offsets to 0 itself
    died=""
    if [[ "$(tail -n 1 -- "$state/log" 2>/dev/null)" != *" $step result="* ]]; then
      died=1
      log_step fail crash
    fi
    step=""
  fi
  nvml zero >/dev/null || {
    shout
    armed=""
    exit 1
  }
  # this was the zero of the pending step: until the first set no way out has one to add
  armed=""
  [[ "$any_offset" != unknown ]] || stop "nvml.py get failed, or printed something else than its lines"
  [[ -n "${crashed_phase-}" ]] || stop "$state/pending does not parse: remove $state to start the search over"
  case "$crashed_phase" in
    core | mem) [[ -n "${p[${crashed_phase}_stored]-}" ]] || end_phase "$crashed_phase" ;;
    *)
      clock="${crashed_phase#soak-}"
      [[ -z "${p[soak_core]-}" || -n "${p[${clock}_soaked]-}" ]] || back_off "$clock"
      ;;
  esac
  rm -f -- "$state/pending"
  [[ "$crashed_boot" == "$boot_id" || -z "$any_offset" ]] ||
    stop "the offsets of the step that crashed were still set after a reboot, so a reboot does not clear them on this card. They are 0 now. Report this before you run sudo pc-oc search gpu again"
  # the fourth fact of #121, measured only here: the search died with offsets set
  [[ "$crashed_boot" == "$boot_id" || -z "$died" ]] ||
    printf 'pc-oc: gpu: search: measured: the reboot cleared the offsets of the step that crashed\n' || unheard=1
else
  read_offsets || stop "nvml.py get failed, or printed something else than its lines"
  [[ -z "$any_offset" ]] || stop "offsets are set by something else: run sudo pc-oc revert gpu"
fi

stop_unheard
(pl_verify "$pl_w") 2>/dev/null || stop "apply the power limit first: sudo pc-oc apply gpu"
run_capped "${v[load_grace_s]}" "gpu/load.sh check" check
# what it says is for the human, whichever stream it chose
head -c 4096 -- "$state/block" >&2 || unheard=1
((load_rc == 0)) || stop "gpu/load.sh check failed: do what its line above says, then run sudo pc-oc search gpu again"

# from here on every way out runs nvml.py zero
armed=1
if [[ -e "$state/result" ]]; then
  report
  printf 'pc-oc: gpu: search: nothing was run: remove %s to search again\n' "$state" || unheard=1
  stop_unheard
  exit 0
fi

if [[ ! -e "$state/baseline" ]]; then
  baseline_load core
  base_core="${b[core_mhz_max]}" base_cap="${b[power_cap]}"
  baseline_load mem
  put baseline "core_mhz_max=$base_core" "mem_mhz_max=${b[mem_mhz_max]}" "read_gbs=${b[read_gbs]}" \
    "core_power_cap=$base_cap" "mem_core_mhz_max=${b[core_mhz_max]}"
fi
old_baseline=1
while IFS= read -r line; do
  if [[ "$line" =~ ^core_mhz_max=([1-9][0-9]{0,4})$ ]]; then base_core="${BASH_REMATCH[1]}"; fi
  if [[ "$line" =~ ^mem_mhz_max=([1-9][0-9]{0,4})$ ]]; then base_mem="${BASH_REMATCH[1]}"; fi
  if [[ "$line" =~ ^read_gbs=([0-9]{1,5})(\.([0-9]{1,3}))?$ ]]; then
    frac="${BASH_REMATCH[3]}000"
    base_gbs=$((10#${BASH_REMATCH[1]} * 1000 + 10#${frac:0:3}))
  fi
  [[ "$line" != core_power_cap=* ]] || old_baseline=""
  if [[ "$line" =~ ^core_power_cap=([01])$ ]]; then base_cap="${BASH_REMATCH[1]}"; fi
  if [[ "$line" =~ ^mem_core_mhz_max=([1-9][0-9]{0,4})$ ]]; then base_mem_core="${BASH_REMATCH[1]}"; fi
done <"$state/baseline"
# the search before #150 wrote three lines, and its core steps were all checked against a
# baseline that may have been capped: nothing of it is taken over
[[ -z "$old_baseline" ]] ||
  stop "$state/baseline has no core_power_cap line, so a gpu/search.sh before #150 wrote it: nothing was set. Start the search over: sudo rm -r $state"
[[ -n "$base_core" && -n "$base_mem" && -n "$base_gbs" && -n "$base_cap" && -n "$base_mem_core" ]] ||
  stop "$state/baseline does not parse: remove $state to start the search over"

phase core
phase mem

if [[ -z "${p[soak_core]-}" ]]; then
  p[soak_core]="${p[core_stored]}" p[soak_mem]="${p[mem_stored]}" p[core_backoffs]=0 p[mem_backoffs]=0
  save_progress
fi
soak core
soak mem

put result "core_offset_mhz=${p[soak_core]}" "mem_offset_mhz=${p[soak_mem]}" \
  "finished=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
sync -- "$state/log" || stop "cannot sync $state/log"
report
stop_unheard
