#!/usr/bin/bash
# pc-oc-test-mock
# Scripted stand-in for gpu/load.sh in the fake tree of tests/gpu/search.bats (contract
# #135). It loads nothing and takes no time: it prints the result block of #134, built from
# the offsets the fake helper holds (mocks/python3), so a search that sets an offset sees
# the clock move by it: core_mhz_max = 2535 + core offset, mem_mhz_max = 9000 + memory
# offset, read_gbs = 400.0. The first line of the plan that matches the call changes that.
# stderr always carries a line outside the block grammar; root must read stdout only.
# State directory (fixed: the search starts this script under env -i):
# /var/lib/pc-oc-test-mock
#   load.plan    lines "<kind>@<core>/<mem> <action>...", a pattern, so * stands for any
#                offset; a line with times=<n> applies to its first n matches only
#   load.check   "<exit code> <stdout|stderr>" for the check verb (default: exit 0)
#   load.calls   "<arguments> @<core>/<mem> <result>" per call, check included
#   load.detail  "pid=<pid> lock=<held|free|nodir> pending=<content, or ABSENT>" per call
#   load.env     the environment of every call
#   events       "load <arguments>" per call, shared with the other mocks, in call order
#   search.pid   written by guard.sh: the process a signal= action signals
#   signal.sent  the signals that were delivered
#   load.pids    "<pid> <pid of its child>" of every call with hang=, alive until it ends;
#                with deaf a third pid, the child of that child
#   load.stopped the signal that ended a hang= call early
#   load.heard   "<signal> <ms since the call began> <ms since the epoch>" per signal a
#                deaf call was sent and did not obey
#   snapshot     a copy of /var/lib/pc-oc as it was while a call with snapshot ran
# Actions: fail (result=fail reason=errors, exit 1) | xid (fail, reason=xid, exit 1) |
#   invalid (result=invalid reason=limited, exit 3) | <key>=<value> (replace that line) |
#   drop=<key> | dup=<line> (one more line) | junk (a line outside the grammar) |
#   empty (no stdout, exit 0) | rc=<exit code> | signal=<TERM|INT|HUP> | snapshot |
#   hang=<seconds> (go on for that long, with a child process as gpu_burn would be, unless
#   TERM, INT or HUP says stop: then end the child, take 0.2 s and exit 3 with an invalid
#   block, as the real gpu/load.sh ends its tool and leaves) |
#   deaf (with hang=: TERM, INT and HUP end nothing. The call notes the signal and goes
#   on; its child and the child of that child, as timeout and the tool are under the real
#   runner, ignore all three. Only KILL ends them, and each of the three needs its own)
set -u
began="${EPOCHREALTIME/[.,]/}"
s=/var/lib/pc-oc-test-mock
state=/var/lib/pc-oc/gpu/search
[[ -e "$s/scratch" ]] || {
  echo "mock load.sh: $s is not the test scratch" >&2
  exit 96
}
{
  echo "-- load $*"
  /usr/bin/env
} >>"$s/load.env"
export LC_ALL=C
printf 'load %s\n' "$*" >>"$s/events"

core=0 mem=0
[[ ! -e "$s/nvml.core" ]] || core="$(<"$s/nvml.core")"
[[ ! -e "$s/nvml.mem" ]] || mem="$(<"$s/nvml.mem")"
lock=nodir
if [[ -d "$state" ]]; then
  lock=held
  ! /usr/bin/flock -n "$state" /usr/bin/true 2>/dev/null || lock=free
fi
pending=ABSENT
[[ ! -e "$state/pending" ]] || pending="$(/usr/bin/tr '\n' ' ' <"$state/pending")"
printf 'pid=%s lock=%s pending=%s\n' "$$" "$lock" "$pending" >>"$s/load.detail"

# record <result>: one line of load.calls
record() {
  printf '%s @%s/%s %s\n' "$args" "$core" "$mem" "$1" >>"$s/load.calls"
}

args="$*"
if [[ "$args" == check ]]; then
  rc=0 stream=stdout
  [[ ! -e "$s/load.check" ]] || read -r rc stream <"$s/load.check"
  record "$rc"
  if [[ "$rc" != 0 ]]; then
    line="gpu_burn is not built for the pinned source: run gpu/burn-build.sh"
    if [[ "$stream" == stderr ]]; then echo "$line" >&2; else echo "$line"; fi
  fi
  exit "$rc"
fi

kind="${1-}"
case "$kind $#" in
  "core 3" | "mem 4") ;;
  *)
    record usage
    echo "usage: load.sh check | core <warmup-s> <load-s> | mem <warmup-s> <load-s> <device>" >&2
    exit 2
    ;;
esac

declare -A block=(
  [result]=pass [reason]=ok [pstate_min]=0
  [core_mhz_max]=$((2535 + core)) [mem_mhz_max]=$((9000 + mem))
  [limited]=0 [xid]=0 [read_gbs]=400.0
  [log]=/home/pc-oc-caller/.cache/pc-oc/gpu-load/mock
)
keys=(result reason pstate_min core_mhz_max mem_mhz_max limited xid)
[[ "$kind" != mem ]] || keys+=(read_gbs)
keys+=(log)
extra=()
rc=0 empty="" signal="" snapshot="" hang="" deaf="" child=""

# act <action>...: apply the actions of one plan line
act() {
  local a k kept
  for a in "$@"; do
    case "$a" in
      fail) block[result]=fail block[reason]=errors rc=1 ;;
      xid) block[result]=fail block[reason]=xid block[xid]=1 rc=1 ;;
      invalid) block[result]=invalid block[reason]=limited block[limited]=1 rc=3 ;;
      empty) empty=1 ;;
      junk) extra+=("GPU 0: OK") ;;
      snapshot) snapshot=1 ;;
      times=*) ;;
      signal=*) signal="${a#signal=}" ;;
      hang=*) hang="${a#hang=}" ;;
      deaf) deaf=1 ;;
      rc=*) rc="${a#rc=}" ;;
      dup=*) extra+=("${a#dup=}") ;;
      drop=*)
        kept=()
        for k in "${keys[@]}"; do
          [[ "$k" == "${a#drop=}" ]] || kept+=("$k")
        done
        keys=("${kept[@]}")
        ;;
      *=*) block[${a%%=*}]="${a#*=}" ;;
      *)
        echo "mock load.sh: unknown action in load.plan: $a" >&2
        exit 96
        ;;
    esac
  done
}

n=0
if [[ -e "$s/load.plan" ]]; then
  while read -r selector actions; do
    n=$((n + 1))
    # shellcheck disable=SC2053 # the selector is a pattern on purpose
    [[ "$kind@$core/$mem" == $selector ]] || continue
    seen=0
    [[ ! -e "$s/plan.seen.$n" ]] || seen="$(<"$s/plan.seen.$n")"
    seen=$((seen + 1))
    echo "$seen" >"$s/plan.seen.$n"
    read -ra acts <<<"$actions"
    times=""
    for a in "${acts[@]}"; do
      [[ "$a" != times=* ]] || times="${a#times=}"
    done
    [[ -z "$times" ]] || ((seen <= times)) || continue
    act "${acts[@]}"
    break
  done <"$s/load.plan"
fi
record "${block[result]}"
[[ -z "$deaf" || -n "$hang" ]] || {
  echo "mock load.sh: deaf needs hang= in load.plan" >&2
  exit 96
}

if [[ -n "$snapshot" ]]; then
  /usr/bin/rm -rf "$s/snapshot"
  /usr/bin/cp -a /var/lib/pc-oc "$s/snapshot"
fi
# sleep is a mock here; a read that times out on a fifo nobody writes to waits instead
/usr/bin/mkfifo "$s/wait.$$"

# stopped <signal>: the search told this load to stop
# shellcheck disable=SC2329 # run by the traps below
stopped() {
  trap '' TERM INT HUP
  kill "$child" 2>/dev/null
  wait "$child" 2>/dev/null
  read -rt 0.2 _ <>"$s/wait.$$" || true
  /usr/bin/rm -f "$s/wait.$$"
  echo "$1" >>"$s/load.stopped"
  printf 'result=invalid\nreason=interrupted\n'
  exit 3
}

# heard <signal>: a deaf call was told to stop and goes on
# shellcheck disable=SC2329 # run by the traps below
heard() {
  local now="${EPOCHREALTIME/[.,]/}"
  printf '%s %s %s\n' "$1" "$(((now - began) / 1000))" "$((now / 1000))" >>"$s/load.heard"
}

if [[ -n "$deaf" ]]; then
  (
    trap '' TERM INT HUP
    (read -rt "$hang" _ <>"$s/wait.$$") &
    echo "$!" >"$s/below.$$"
    wait
  ) &
  child=$!
  # all three pids are on record before the search can be told anything
  tries=0
  until [[ -s "$s/below.$$" ]]; do
    tries=$((tries + 1))
    ((tries < 500)) || {
      echo "mock load.sh: the child of the child did not start" >&2
      exit 96
    }
    read -rt 0.01 _ <>"$s/wait.$$" || true
  done
  echo "$$ $child $(<"$s/below.$$")" >>"$s/load.pids"
  /usr/bin/rm -f "$s/below.$$"
  trap 'heard TERM' TERM
  trap 'heard INT' INT
  trap 'heard HUP' HUP
elif [[ -n "$hang" ]]; then
  (read -rt "$hang" _ <>"$s/wait.$$") &
  child=$!
  echo "$$ $child" >>"$s/load.pids"
  trap 'stopped TERM' TERM
  trap 'stopped INT' INT
  trap 'stopped HUP' HUP
fi
if [[ -n "$signal" ]]; then
  kill -s "$signal" "$(<"$s/search.pid")" && echo "$signal" >>"$s/signal.sent"
  # without hang= the load goes on for a moment after the signal reached the search
  [[ -n "$hang" ]] || read -rt 0.3 _ <>"$s/wait.$$" || true
fi
if [[ -n "$deaf" ]]; then
  # a signal that is only noted ends the wait, not the child
  while kill -0 "$child" 2>/dev/null; do
    wait "$child" || true
  done
elif [[ -n "$hang" ]]; then
  wait "$child" || true
fi
/usr/bin/rm -f "$s/wait.$$"

echo "mock load.sh: burning (stderr is not part of the result block)" >&2
if [[ -z "$empty" ]]; then
  for k in "${keys[@]}"; do
    printf '%s=%s\n' "$k" "${block[$k]}"
  done
  ((${#extra[@]} == 0)) || printf '%s\n' "${extra[@]}"
fi
exit "$rc"
