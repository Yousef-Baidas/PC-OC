#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

# Contract for gpu/search.sh, gpu/search.values and gpu/offsets.md (#135: the 15 cases of
# the ticket's Check list, its start-up order and Amendment 1). No case loads the GPU,
# writes an offset or initialises NVML. The script runs as uid 0 of a user namespace in a
# fake tree, behind fixtures/search/guard.sh, which binds a stand-in over every path the
# script reaches by absolute name or through PATH=/usr/bin:
#   /usr/bin/python3  the fake helper: it keeps the two offsets in files and records calls;
#   gpu/load.sh       of the fake tree: a scripted mock that prints a #134 result block
#                     from those offsets and a plan, and takes no time;
#   /usr/bin/setpriv, getent, nvidia-smi, systemctl, sleep, sudo: recording mocks;
#   /etc/passwd, /var/lib and the kernel's boot_id: fixtures and scratch.
# The step lengths come from fixtures/search/search.values: the ticket's offsets with
# seconds of 2 to 7, so the arguments of a load tell a step (core 2 3, mem 4 6 1) from a
# soak (5 and 7 seconds) and a whole search takes about a second. load_grace_s is 3600
# there, so the cap of Amendment 4 fires only where a case sets its own seconds: cases 19
# and 20 run a mock load that does take time (hang=, deaf) and wait for it in real time.
# The cases named "#150 case N" are the contract for #150 (N is the number in that
# ticket's Check list): case 16 behind the other text case on gpu/offsets.md, cases 8 to
# 15 at the end. They run with the power_cap line of #150 in every block of the mock load
# (power_cap_blocks), and so does every other case since the switch of the helper,
# BLOCK_POWER_CAP, is 1.

load fixtures/search/helper

setup() {
  common_setup
}

teardown() {
  # a mock load that a failing case 17, 19 or 20 left running must not outlive the test.
  # KILL, as the load of cases 19 and 20 obeys nothing else; only a pid that still is the
  # mock load of this test's tree gets it, as a pid may have gone to another process.
  local pid
  [[ -e "$MOCK/load.pids" ]] || return 0
  for pid in $(<"$MOCK/load.pids"); do
    if { tr '\0' ' ' <"/proc/$pid/cmdline"; } 2>/dev/null | grep -qF " $REPO/gpu/load.sh "; then
      kill -KILL "$pid" 2>/dev/null || true
    fi
  done
}

# crashed_at <kind@core/mem>: leave the state directory the way a search that died in
# that step left it. The mock load copies the directory while the step runs, pending
# included; the run then ends well and the copy is put in its place.
crashed_at() {
  plan "$1 snapshot"
  search
  status_is 0
  [ -e "$MOCK/snapshot/gpu/search/pending" ]
  rm -rf "$VARLIB/pc-oc"
  mv "$MOCK/snapshot" "$VARLIB/pc-oc"
  rm "$MOCK/load.plan" "$MOCK"/plan.seen.*
  next_start
}

# first <regex>: the line number of the first recorded call that matches
first() {
  grep -n -m1 -E "^$1" "$MOCK/events" | cut -d: -f1
}

# caller_refused <label> [NAME=value...]: a start as uid 0 with these variables exits 1
# before the lock (the state directory is not even made), before any helper call and
# before any load
caller_refused() {
  local label="$1"
  shift
  start_as root "$@"
  if [[ "$status" -ne 1 || -e "$VARLIB/pc-oc" ]] || ! grep -q '^pc-oc: gpu: ' <<<"$stderr" ||
    [[ -n "$(calls nvml)$(calls python3)$(calls setpriv)$(calls load)" ]]; then
    printf '%s: status %s\nstderr:\n%s\ncalls:\n%s\nunder /var/lib: %s\n' "$label" "$status" \
      "$stderr" "$(cat "$MOCK/events" 2>/dev/null)" "$(ls -A "$VARLIB")" >&2
    return 1
  fi
}

# bad_uids <locale>, bad_gids <locale>: every value of Amendment 1's list is refused
bad_uids() {
  local l="LC_ALL=$1" g="SUDO_GID=$CALLER_GID" v
  caller_refused "SUDO_UID unset" "$l" "$g"
  # 4294971538 is 2^32 + 4242; 4999 has no passwd entry, 4245 a relative home, 4246 none
  for v in "" 0 00 +0 -1 0x0 4294967296 4294967295 4294971538 00000004242 $'4242\n' \
    "4242 " " 4242" ４２４２ pc-oc-caller 12x "4242 --reuid=0" 4999 4245 4246; do
    caller_refused "SUDO_UID='$v'" "$l" "SUDO_UID=$v" "$g"
  done
}
bad_gids() {
  local l="LC_ALL=$1" u="SUDO_UID=$CALLER_UID" v
  caller_refused "SUDO_GID unset" "$l" "$u"
  # 4294971639 is 2^32 + 4343
  for v in "" +0 -1 0x0 4294967296 4294967295 4294971639 00000004343 $'4343\n' \
    "4343 " " 4343" ４３４３ pc-oc-caller 12x "4343 --regid=0"; do
    caller_refused "SUDO_GID='$v'" "$l" "$u" "SUDO_GID=$v"
  done
}

# values_refused <label> <sed script> [NAME=value...]: with gpu/search.values changed by
# the script, a start is refused
values_refused() {
  local label="$1" script="$2"
  shift 2
  values_with "$script"
  search "$@"
  if ! refused || ! grep -q '^pc-oc: gpu: ' <<<"$stderr"; then
    printf 'search.values with %s was not refused\n' "$label" >&2
    return 1
  fi
}

# signalled <TERM|INT|HUP>: the signal reaches the search while the load of the core
# step at 120 runs (the mock load sends it, then goes on for 0.3 s and reports a pass)
signalled() {
  plan "core@120/0 signal=$1"
  search
  [ "$(<"$MOCK/signal.sent")" = "$1" ]
  [ "$status" -ne 0 ]
  last_load "core 2 3 @120/0 pass"
  ends_at_zero
  grep -Eq '(^|[[:space:]])core=120([[:space:]]|$)' "$STATE/pending"
  grep -Eq '(^|[[:space:]])mem=0([[:space:]]|$)' "$STATE/pending"
  no_result
}

# load_gone: no process of the mock load's hang= calls is alive
load_gone() {
  local pid
  for pid in $(<"$MOCK/load.pids"); do
    if kill -0 "$pid" 2>/dev/null; then
      printf 'a process of the load is still alive: %s\n' "$(ps -o pid=,stat=,args= -p "$pid")" >&2
      return 1
    fi
  done
}

# gone_at_zero: no process of the mock load's hang= calls was there, as a zombie either,
# when the last zero ran
gone_at_zero() {
  local last
  last="$(grep '^zero ' "$MOCK/nvml.loads" | tail -n 1)"
  if [[ "$last" != "zero alive=" ]]; then
    printf 'processes of the load still there at the last zero: %s\n' "${last#zero alive=}" >&2
    return 1
  fi
}

# stopped <TERM|INT|HUP> [deaf]: the signal reaches the search while the load of the core
# step at 120 runs, a load that goes on for 30 s unless it is told to stop; with deaf, one
# that goes on even then, as the two processes under it do. The search ends it, waits for
# it, runs zero and exits, all within 10 s (Amendment 3, ruling 1; Amendment 4, point 4).
stopped() {
  local start=$SECONDS pids=2
  [[ -z "${2-}" ]] || pids=3
  plan "core@120/0 signal=$1 hang=30${2:+ $2}"
  search
  if ((SECONDS - start >= 10)); then
    printf 'the search took %s s after the signal\n' "$((SECONDS - start))" >&2
    return 1
  fi
  [ "$(<"$MOCK/signal.sent")" = "$1" ]
  [ "$(wc -w <"$MOCK/load.pids")" -eq "$pids" ]
  [ "$status" -ne 0 ]
  last_load "core 2 3 @120/0 pass"
  ends_at_zero
  # the load and its child were gone, reaped too, when the last zero ran
  gone_at_zero
  load_gone
  grep -Eq '(^|[[:space:]])core=120([[:space:]]|$)' "$STATE/pending"
  no_result
}

# term_then_kill: the deaf load of this start was sent TERM before any other signal and
# went on, and the last helper call came 4 s or more after that: the 5 s the ticket gives
# a load to end before KILL, less one for a script that counts whole seconds
term_then_kill() {
  local told zeroed
  told="$(sed -En '1s/^TERM [0-9]+ ([0-9]+)$/\1/p' "$MOCK/load.heard" 2>/dev/null || true)"
  [[ -n "$told" ]] || {
    printf 'the load noted no TERM ahead of any other signal (none sent, or KILL at once): %s\n' \
      "$(cat "$MOCK/load.heard" 2>&1)" >&2
    return 1
  }
  zeroed="$(date -r "$MOCK/nvml.calls" +%s%3N)"
  ((zeroed - told >= 4000)) || {
    printf 'the last helper call came %s ms after TERM reached the load\n' "$((zeroed - told))" >&2
    return 1
  }
}

# timeout_said <mhz>: one stderr line of the last run has the word timeout and names the
# step by its offset
timeout_said() {
  grep -v '^mock ' <<<"$stderr" | grep -iw 'timeout' | grep -Eq "(^|[^0-9])$1([^0-9]|\$)" || {
    printf 'no stderr line with the word timeout and %s:\n%s\n' "$1" "$stderr" >&2
    return 1
  }
}

# shouted: stderr names "sudo reboot" and says something in capitals
shouted() {
  if ! grep -Fq 'sudo reboot' <<<"$stderr" || ! grep -Eq '[A-Z]{2,} [A-Z]{2,}' <<<"$stderr"; then
    printf 'no capital-letter message with sudo reboot:\n%s\n' "$stderr" >&2
    return 1
  fi
}

@test "search: every load passing, one baseline, then core steps 90 to 240, then memory steps 200 to 1500, then one soak, and nothing else (#135 case 1)" {
  search
  all_passed
  [ "$(baseline_loads)" = "core 2 3 mem 4 6 1" ]
  [ "$(soaks core)" = "210/1300:pass" ]
  [ "$(soaks mem)" = "210/1300:pass" ]
  [ "$(loads | wc -l)" -eq 24 ]
}

@test "search: every load passing, result holds core 210 and memory 1300, both soaked, and stdout gives both and says they are not applied (#135 case 1)" {
  search
  status_is 0
  result_is 210 1300
  result_soaked
  [[ "$output" == *210* && "$output" == *1300* ]]
  # "not applied yet", "not yet applied": the wording is the script's
  grep -Eqi 'not .*appl' <<<"$output"
  log_ok
  for mhz in 90 120 150 180 210 240; do
    logged "$mhz" 0 pass
  done
  for mhz in 200 300 400 500 600 700 800 900 1000 1100 1200 1300 1400 1500; do
    logged 0 "$mhz" pass
  done
}

@test "search: every load passing, the last helper call is zero, no pending is left, and every set found the pending file of its step (#135 case 1)" {
  search
  status_is 0
  ends_at_zero
  [ -z "$(find "$STATE" -name 'pending*')" ]
  # 6 core steps, 14 memory steps and the soak each set at least the clock they test
  [ "$(calls nvml | grep -c '^set core ')" -ge 7 ]
  [ "$(calls nvml | grep -c '^set mem ')" -ge 15 ]
  sets_had_pending
  # the helper was always python3 -I on nvml.py of the script's own tree, with a command
  # of its interface
  helper_calls_ok
  [ "$(calls nvml | grep -Evxc 'get|zero|set (core|mem) (0|[1-9][0-9]*)')" -eq 0 ]
}

@test "search: start-up runs in the ticket's order: calling user, offsets read, power limit read back, load check, and only then a load and a set (#135 start-up)" {
  search
  status_is 0
  [ "$(first 'getent passwd 4242$')" -lt "$(first 'nvml get$')" ]
  [ "$(first 'nvml get$')" -lt "$(first 'nvidia-smi --query-gpu=power.limit ')" ]
  [ "$(first 'nvidia-smi --query-gpu=power.limit ')" -lt "$(first 'load check$')" ]
  [ "$(first 'load check$')" -lt "$(first 'load (core|mem) ')" ]
  [ "$(first 'load (core|mem) ')" -lt "$(first 'nvml set ')" ]
  [ "$(grep -c '^check ' "$MOCK/load.calls")" -eq 1 ]
}

@test "search: the state directory is locked from the load check to the last load (#135 start-up 2)" {
  search
  status_is 0
  [ "$(wc -l <"$MOCK/load.detail")" -eq 25 ]
  [ "$(grep -c ' lock=held ' "$MOCK/load.detail")" -eq 25 ]
  # the lock went with the process: a second start is not refused
  next_start
  search
  [[ "$stderr" != *"already running"* ]]
}

@test "search: a run touches no sudo, no systemctl and no other python3, asks nvidia-smi only for power.limit, and those mocks do stand where a call would land (#135 Check)" {
  search
  status_is 0
  [ -z "$(calls sudo)$(calls systemctl)$(calls python3)" ]
  [ "$(calls nvidia-smi | sort -u)" = "--query-gpu=power.limit --format=csv,noheader,nounits" ]
  [ "$(calls getent | sort -u)" = "passwd 4242" ]
  # positive control: the same names, called on purpose in the same namespace, are the
  # mocks and their calls are recorded. A name that is not the mock is not called.
  next_start
  # shellcheck disable=SC2016 # the inner shell expands these
  run in_ns root /usr/bin/bash -c 'PATH=/usr/bin
    for tool in sudo systemctl sleep python3; do
      [[ "$(sed -n 2p "/usr/bin/$tool")" == "# pc-oc-test-mock" ]] || exit 95
      "$tool" --control "$tool" || [[ "$tool" == python3 ]] || exit 94
      "/usr/bin/$tool" --control absolute || [[ "$tool" == python3 ]] || exit 94
    done'
  status_is 0
  for tool in sudo systemctl sleep python3; do
    [ "$(calls "$tool")" = "--control $tool"$'\n'"--control absolute" ]
  done
  # and the guard starts nothing when a bind is not a mock
  echo "not a mock" >"$GUARD_MOCKS/sleep"
  run in_ns root /usr/bin/true
  status_is 97
}

@test "search: the core step at 180 failing stores core 120, and the memory phase still runs (#135 case 2)" {
  plan 'core@180/0 fail'
  search
  status_is 0
  [ "$(core_steps)" = "90 120 150 180" ]
  logged 180 0 fail
  [ "$(mem_steps)" = "200 300 400 500 600 700 800 900 1000 1100 1200 1300 1400 1500" ]
  [ "$(soaks core)" = "120/1300:pass" ]
  result_is 120 1300
  ends_at_zero
}

@test "search: the first core step failing stores core 0 (#135 case 3)" {
  plan 'core@90/0 fail'
  search
  status_is 0
  [ "$(core_steps)" = "90" ]
  [ "$(mem_steps)" = "200 300 400 500 600 700 800 900 1000 1100 1200 1300 1400 1500" ]
  [ "$(soaks mem)" = "0/1300:pass" ]
  result_is 0 1300
  ends_at_zero
}

@test "search: a core phase whose last passing step is below the margin stores 0, never less (#135 phases)" {
  values_with 's/^core_margin_mhz=30/core_margin_mhz=200/'
  plan 'core@150/0 fail'
  search
  status_is 0
  result_is 0 1300
}

@test "search: memory read_gbs 4 percent under the baseline at 600 is reason=throughput and stores memory 300 (#135 case 4)" {
  plan 'mem@0/600 read_gbs=384.0'
  search
  status_is 0
  [ "$(mem_steps)" = "200 300 400 500 600" ]
  logged 0 600 fail throughput
  [ "$(soaks mem)" = "210/300:pass" ]
  result_is 210 300
}

@test "search: memory read_gbs 2.9 percent under the baseline, and exactly mem_drop_pct under it, still pass (#135 case 4)" {
  plan 'mem@0/600 read_gbs=388.4' 'mem@0/700 read_gbs=388.0'
  search
  all_passed
  logged 0 600 pass
  logged 0 700 pass
}

@test "search: the load saying invalid at a step ends the search: zero, exit 1, the step logged as failed, no result, and the message says to run it again (#135 case 5)" {
  plan 'mem@0/600 invalid'
  search
  search_ended "mem 4 6 1 @0/600 invalid" 0 600
  said reboot
  [ "$(mem_steps)" = "200 300 400 500 600" ]
}

@test "search: the start after an invalid step repeats neither that step nor the baseline nor the core phase, and ends with core 210 and memory 300 (#135 case 5)" {
  plan 'mem@0/600 invalid'
  search
  status_is 1
  next_start
  search
  status_is 0
  [ -z "$(baseline_loads)" ]
  [ -z "$(core_steps)" ]
  # the step at 600 counts as failed: it is not run again and none above it is
  [[ ! " $(mem_steps) " =~ \ ([6-9]|1[0-5])00\  ]]
  [ "$(soaks core)" = "210/300:pass" ]
  [ "$(soaks mem)" = "210/300:pass" ]
  result_is 210 300
  result_soaked
  ends_at_zero
}

@test "search: reason=xid at a core step ends the search the same way, and the next start goes on with core 90 (#135 case 5)" {
  plan 'core@150/0 xid'
  search
  search_ended "core 2 3 @150/0 fail" 150 0
  logged 150 0 'fail|invalid' xid
  said reboot
  next_start
  search
  status_is 0
  [ -z "$(baseline_loads)" ]
  [[ ! " $(core_steps) " =~ \ (150|180|210|240)\  ]]
  result_is 90 1300
}

@test "search: a pending file at start is logged as reason=crash, zero is the first helper call after get, and the step counts as failed (#135 case 6)" {
  crashed_at core@150/0
  # the search was killed in the step: same boot, the offset is still set
  echo 150 >"$MOCK/nvml.core"
  search
  status_is 0
  [ "$(calls nvml | head -n 1)" = get ]
  [ "$(calls nvml | grep -vx -m1 get)" = zero ]
  logged 150 0 fail crash
  [ -z "$(baseline_loads)" ]
  [[ ! " $(core_steps) " =~ \ (150|180|210|240)\  ]]
  result_is 90 1300
  [ ! -e "$STATE/pending" ]
  ends_at_zero
}

@test "search: a pending file from another boot with every offset at 0 is the same crash: logged, zero, the search goes on (#135 case 6)" {
  crashed_at mem@0/700
  printf '%s\n' "$BOOT_B" >"$GUARD_BOOT_ID"
  search
  status_is 0
  [ "$(calls nvml | grep -vx -m1 get)" = zero ]
  logged 0 700 fail crash
  [ -z "$(baseline_loads)$(core_steps)" ]
  [[ ! " $(mem_steps) " =~ \ ([7-9]|1[0-5])00\  ]]
  result_is 210 400
}

@test "search: a pending file from another boot and a non-zero offset from get: exit 1 with the reboot message, offsets zeroed, no set and no load (#135 case 6)" {
  crashed_at core@150/0
  printf '%s\n' "$BOOT_B" >"$GUARD_BOOT_ID"
  echo 150 >"$MOCK/nvml.core"
  search
  refused
  said reboot
  [ "$(calls nvml | head -n 1)" = get ]
  ends_at_zero
}

@test "search: a core baseline load in pstate 5 stops the search: exit 1, the message names the pstate, no set call (#135 case 7)" {
  plan 'core@0/0 pstate_min=5'
  search
  status_is 1
  said pstate
  no_set
  [ -z "$(core_steps)$(mem_steps)" ]
  no_result
  ends_at_zero
}

@test "search: a memory baseline load in pstate 3, a baseline that fails and one that is invalid each stop the search before any set (#135 case 7)" {
  for line in 'mem@0/0 pstate_min=3' 'core@0/0 fail' 'mem@0/0 fail' 'mem@0/0 invalid'; do
    fresh
    plan "$line"
    search
    status_is 1
    said '^pc-oc: gpu: '
    no_set
    [ -z "$(core_steps)$(mem_steps)" ]
    no_result
    ends_at_zero
  done
}

@test "search: a memory clock that moved by 100 at the +200 step stops the search: exit 1, the message gives both numbers, zero ran (#135 case 7)" {
  plan 'mem@0/200 mem_mhz_max=9100'
  search
  status_is 1
  # the two deltas, or the two clocks
  if ! { said '(^|[^0-9])100([^0-9]|$)' && said '(^|[^0-9])200([^0-9]|$)'; } 2>/dev/null; then
    said '(^|[^0-9])9100([^0-9]|$)'
    said '(^|[^0-9])9200([^0-9]|$)'
  fi
  last_load "mem 4 6 1 @0/200 pass"
  ends_at_zero
  no_result
}

@test "search: at the first memory step a clock 5 MHz off the requested one passes and one 6 MHz off stops the search (#135 case 7)" {
  plan 'mem@0/200 mem_mhz_max=9205'
  search
  all_passed
  fresh
  plan 'mem@0/200 mem_mhz_max=9194'
  search
  status_is 1
  last_load "mem 4 6 1 @0/200 pass"
  ends_at_zero
  no_result
}

@test "search: nvml.py set exiting 1 is followed by zero before anything else, exit 1 (#135 case 8)" {
  helper_fails 1 1 set
  search
  status_is 1
  failed="$(grep -m1 '^set .* rc=1 ' "$MOCK/nvml.calls")"
  zero_follows "${failed%% rc=*}"
  [ -z "$(core_steps)$(mem_steps)" ]
  ends_at_zero
  no_result
}

@test "search: nvml.py set exiting 137 is followed by zero before anything else, exit 1 (#135 case 8)" {
  helper_fails 1 137 set
  search
  status_is 1
  failed="$(grep -m1 '^set .* rc=137 ' "$MOCK/nvml.calls")"
  zero_follows "${failed%% rc=*}"
  [ -z "$(core_steps)$(mem_steps)" ]
  ends_at_zero
  no_result
}

@test "search: the memory set of the first memory step failing is followed by zero, no load of that step runs, exit 1 (#135 case 8)" {
  helper_fails 1 1 set mem 200
  search
  status_is 1
  zero_follows "set mem 200"
  [ "$(core_steps)" = "90 120 150 180 210 240" ]
  [ -z "$(mem_steps)" ]
  ends_at_zero
  no_result
  said 'search gpu'
}

@test "search: zero failing after a failed set is said in capitals, with sudo reboot as the way to clear the offsets (#135 case 8)" {
  helper_fails 1 1 set
  helper_fails all 1 zero
  search
  [ "$status" -ne 0 ]
  [ "$(calls nvml | tail -n 1)" = zero ]
  shouted
  no_result
}

@test "search: zero failing at the end of a search whose loads all passed is said in capitals too (#135 case 8)" {
  helper_fails all 1 zero
  search
  [ "$(calls nvml | tail -n 1)" = zero ]
  shouted
}

@test "search: the final zero exiting 1 or 137 after an otherwise clean run: exit 1, a line says the offsets may still be set, and the result is written (#135 case 18)" {
  for code in 1 137; do
    fresh
    helper_fails all "$code" zero
    search
    status_is 1
    [ "$(phases)" = "baseline core mem soak-core soak-mem" ]
    [ "$(calls nvml | tail -n 1)" = zero ]
    # the fake helper's own line does not name the offsets; the script's must
    said 'offsets'
    shouted
    result_is 210 1300
    result_soaked
  done
}

@test "search: not root is refused: exit 1, no helper call, no load (#135 case 9)" {
  start_as user "SUDO_UID=$CALLER_UID" "SUDO_GID=$CALLER_GID"
  refused
  said '^pc-oc: gpu: '
  [ -z "$(calls nvml)$(calls setpriv)$(calls load)" ]
  # positive control: the same start as uid 0 does all three
  fresh
  search
  status_is 0
  [ -n "$(calls nvml)" ] && [ -n "$(calls setpriv)" ] && [ -n "$(calls load)" ]
}

@test "search: SUDO_UID unset, 0 or not digits is refused: exit 1, no set call (#135 case 9)" {
  start_as root "SUDO_GID=$CALLER_GID"
  refused
  for uid in 0 12x; do
    start_as root "SUDO_UID=$uid" "SUDO_GID=$CALLER_GID"
    refused
  done
}

@test "search: a power limit that does not read back as pl_w is refused with the apply message (#135 case 9)" {
  echo 150.00 >"$MOCK/smi.limit"
  search
  refused
  said_line "$MSG_POWER"
  [ "$(calls nvidia-smi)" = "--query-gpu=power.limit --format=csv,noheader,nounits" ]
}

@test "search: a non-zero offset without a pending file is refused with the revert message, on any pstate and clock (#135 case 9)" {
  echo 120 >"$MOCK/nvml.core"
  search
  refused
  said_line "$MSG_OFFSETS"
  fresh
  echo 50 >"$MOCK/nvml.mem"
  search
  refused
  said_line "$MSG_OFFSETS"
  # only the last line differs from a card at stock
  fresh
  printf '%s\n' 'p0.core offset=0 min=-500 max=500' 'p0.mem offset=0 min=-2000 max=3000' \
    'p1.core unsupported' 'p1.mem unsupported' \
    'p2.core offset=0 min=-500 max=500' 'p2.mem offset=-50 min=-2000 max=3000' >"$MOCK/nvml.get"
  search
  refused
  said_line "$MSG_OFFSETS"
}

@test "search: nvml.py get failing at start is refused: exit 1, no set call (#135 case 9)" {
  helper_fails 1 1 get
  search
  refused
  said '^pc-oc: gpu: '
}

@test "search: load.sh check exiting 3 is refused and its line is shown, whichever stream it came on (#135 case 9)" {
  for stream in stdout stderr; do
    fresh
    echo "3 $stream" >"$MOCK/load.check"
    search
    refused
    [[ "$output$stderr" == *"gpu_burn is not built for the pinned source: run gpu/burn-build.sh"* ]]
    # the check ran as the calling user
    [[ "$(calls setpriv)" == "--reuid=$CALLER_UID --regid=$CALLER_GID --init-groups "*" check" ]]
  done
}

@test "search: a second start while the state directory is locked is refused with already running (#135 case 9)" {
  mkdir -p "$STATE"
  exec 8<"$STATE"
  flock -n 8
  search
  exec 8<&-
  refused
  said_line "pc-oc: gpu: search: already running"
  # a start that does not hold the lock leaves the offsets of the one that does alone
  [ -z "$(calls nvml)" ]
  # positive control: with the lock gone the same start runs
  search
  status_is 0
}

@test "search: search.values that is absent, or has a missing, repeated or unknown key, is refused (#135 case 9)" {
  rm "$REPO/gpu/search.values"
  search
  refused
  # a key the file lacks is not taken from the environment either
  values_refused "core_step_mhz missing" '/^core_step_mhz=/d' core_step_mhz=30
  values_refused "soak_backoffs missing" '/^soak_backoffs=/d' soak_backoffs=3
  values_refused "mem_max_mhz twice" '/^mem_max_mhz=/p'
  values_refused "core_load_s twice, two values" 's/^(core_load_s)=3(.*)$/\1=3\2\n\1=4\2/'
  # shellcheck disable=SC2016 # $a is a sed address here and in the next call
  values_refused "an unknown key" '$a core_extra_mhz=30  # src: research-111'
  # shellcheck disable=SC2016
  values_refused "pl_w, a key of gpu/values" '$a pl_w=216  # src: smi'
}

@test "search: a search.values value outside the ticket's pattern is refused (#135 case 9)" {
  for value in "" 090 00 -90 +90 90x x90 9.5 10000 '"90"' " 90" 0x5a; do
    values_refused "core_start_mhz=$value" "s/^core_start_mhz=90/core_start_mhz=$value/"
  done
  values_refused "a space before =" 's/^mem_step_mhz=/mem_step_mhz =/'
  # the three keys without a bound of their own
  values_refused "soak_backoffs=10000" 's/^soak_backoffs=3/soak_backoffs=10000/'
  values_refused "mem_device_index=1x" 's/^mem_device_index=1/mem_device_index=1x/'
  values_refused "mem_drop_pct=03" 's/^mem_drop_pct=3/mem_drop_pct=03/'
  values_refused "mem_soak_s=7s" 's/^mem_soak_s=7/mem_soak_s=7s/'
}

@test "search: a search.values value outside the ticket's bounds is refused (#135 case 9)" {
  values_refused "core_max_mhz=301" 's/^core_max_mhz=240/core_max_mhz=301/'
  values_refused "mem_max_mhz=2001" 's/^mem_max_mhz=1500/mem_max_mhz=2001/'
  values_refused "core_start_mhz above core_max_mhz" 's/^core_start_mhz=90/core_start_mhz=241/'
  values_refused "mem_start_mhz above mem_max_mhz" 's/^mem_start_mhz=200/mem_start_mhz=1501/'
  for key in core_step_mhz core_margin_mhz mem_step_mhz mem_margin_mhz; do
    values_refused "$key=14" "s/^$key=[0-9]+/$key=14/"
    values_refused "$key=0" "s/^$key=[0-9]+/$key=0/"
  done
  for key in core_warmup_s core_load_s core_soak_s mem_warmup_s mem_load_s mem_soak_s; do
    values_refused "$key=0" "s/^$key=[0-9]+/$key=0/"
    values_refused "$key=3601" "s/^$key=[0-9]+/$key=3601/"
  done
}

@test "search: search.values without load_grace_s, with it twice, or with a value outside 1 to 3600 or the ticket's pattern is refused (#135 case 21)" {
  # a key the file lacks is not taken from the environment either
  values_refused "load_grace_s missing" '/^load_grace_s=/d' load_grace_s=120
  values_refused "load_grace_s twice" '/^load_grace_s=/p'
  values_refused "load_grace_s twice, two values" 's/^(load_grace_s)=3600(.*)$/\1=120\2\n\1=60\2/'
  for value in 0 3601 "" 01 1s -1; do
    values_refused "load_grace_s=$value" "s/^load_grace_s=3600/load_grace_s=$value/"
  done
}

@test "search: search.values with every bound reached is accepted: one core step at 300 and one memory step at 2000, margins of 15 (#135 case 9)" {
  values_with 's/^core_(start|max)_mhz=[0-9]+/core_\1_mhz=300/
    s/^mem_(start|max)_mhz=[0-9]+/mem_\1_mhz=2000/
    s/^(core|mem)_(step|margin)_mhz=[0-9]+/\1_\2_mhz=15/
    s/^(core|mem)_(warmup|load|soak)_s=[0-9]+/\1_\2_s=3600/'
  search
  status_is 0
  [ "$(loads | sed -n '3,$p')" = "core 3600 3600 @300/0 pass
mem 3600 3600 1 @0/2000 pass
core 3600 3600 @285/1985 pass
mem 3600 3600 1 @285/1985 pass" ]
  result_is 285 1985
  # the mock sleep stood in /usr/bin: 3600 s cost no time, whether the script waits or not
  [ "$SECONDS" -lt 30 ]
}

@test "search: gpu/values that does not parse is refused: exit 1, no set call (#135 case 9)" {
  for content in "" "pl_w=abc  # src: smi" "pl_w=0216  # src: smi"; do
    printf '%s\n' "$content" >"$REPO/gpu/values"
    search
    refused
  done
}

@test "search: a core soak that fails once and then passes stores core one step lower (#135 case 10)" {
  plan 'core@210/1300 fail'
  search
  status_is 0
  [ "$(soaks core)" = "210/1300:fail 180/1300:pass" ]
  [ "$(soaks mem)" = "180/1300:pass" ]
  result_is 180 1300
  result_soaked
  ends_at_zero
}

@test "search: a core soak that fails soak_backoffs times and then passes stores what passed (#135 case 10)" {
  plan 'core@210/1300 fail' 'core@180/1300 fail' 'core@150/1300 fail'
  search
  status_is 0
  [ "$(soaks core)" = "210/1300:fail 180/1300:fail 150/1300:fail 120/1300:pass" ]
  result_is 120 1300
  result_soaked
}

@test "search: a core soak that fails soak_backoffs + 1 times stores core 0 (#135 case 10)" {
  plan 'core@210/1300 fail' 'core@180/1300 fail' 'core@150/1300 fail' 'core@120/1300 fail'
  search
  status_is 0
  [[ "$(soaks core)" == "210/1300:fail 180/1300:fail 150/1300:fail 120/1300:fail"* ]]
  [[ "$(soaks core)" != *" 90/"* ]]
  [[ " $(soaks mem) " == *" 0/1300:pass "* ]]
  result_is 0 1300
  result_soaked
  ends_at_zero
}

@test "search: a memory soak that fails once and then passes stores memory one step lower (#135 case 10)" {
  plan 'mem@210/1300 fail'
  search
  status_is 0
  [ "$(soaks mem)" = "210/1300:fail 210/1200:pass" ]
  result_is 210 1200
  result_soaked
  ends_at_zero
}

@test "search: a memory soak that fails soak_backoffs + 1 times stores memory 0 (#135 case 10)" {
  plan 'mem@210/1300 fail' 'mem@210/1200 fail' 'mem@210/1100 fail' 'mem@210/1000 fail'
  search
  status_is 0
  [[ "$(soaks mem)" == "210/1300:fail 210/1200:fail 210/1100:fail 210/1000:fail"* ]]
  [[ "$(soaks mem)" != *"/900:"* ]]
  result_is 210 0
  result_soaked
  ends_at_zero
}

@test "search: a core soak load saying invalid ends the search with no result; the next start writes one only for values a soak load passed with (#135 case 10)" {
  plan 'core@210/1300 invalid times=1'
  search
  status_is 1
  [ "$(soaks core)" = "210/1300:invalid" ]
  [ -z "$(soaks mem)" ]
  ends_at_zero
  no_result
  said 'search gpu'
  next_start
  search
  status_is 0
  [ -z "$(baseline_loads)$(core_steps)$(mem_steps)" ]
  [ -n "$(soaks core)" ] && [ -n "$(soaks mem)" ]
  result_soaked
  ends_at_zero
}

@test "search: SIGTERM during the memory soak leaves no result, though both phases and the core soak had passed; the next start soaks before it writes one (#135 case 11)" {
  plan 'mem@210/1300 signal=TERM times=1'
  search
  [ "$(<"$MOCK/signal.sent")" = TERM ]
  [ "$status" -ne 0 ]
  [ "$(soaks core)" = "210/1300:pass" ]
  ends_at_zero
  no_result
  lock_free
  next_start
  search
  status_is 0
  # the core soak passed at 210 in the first start; the memory value must pass one now
  grep -qx 'core_offset_mhz=210' "$STATE/result"
  mhz="$(sed -n 's/^mem_offset_mhz=//p' "$STATE/result")"
  [ "$mhz" = 0 ] || soaked mem "$mhz"
  ends_at_zero
}

@test "search: the soak loads last core_soak_s and mem_soak_s, on the device index of search.values (#135 phases)" {
  values_with 's/^core_soak_s=5/core_soak_s=11/; s/^mem_soak_s=7/mem_soak_s=13/
    s/^mem_device_index=1/mem_device_index=2/'
  search
  status_is 0
  loads | grep -Eqx 'core [0-9]+ 11 @210/1300 pass'
  loads | grep -Eqx 'mem [0-9]+ 13 2 @210/1300 pass'
  [ "$(loads | grep -c '^mem 4 6 2 @')" -eq 15 ]
  result_is 210 1300
}

@test "search: SIGTERM during a step: zero runs, pending stays, the exit code is not 0, nothing is loaded after it (#135 case 11)" {
  signalled TERM
}

@test "search: SIGINT during a step ends the same way (#135 case 11)" {
  signalled INT
}

@test "search: SIGHUP during a step ends the same way (#135 case 11)" {
  signalled HUP
}

@test "search: SIGTERM during a load that would go on for 30 s: the search ends the load, waits for it, then zero, and exits within 10 s; no process of the load is left (#135 case 17)" {
  stopped TERM
}

@test "search: SIGINT during a load that would go on for 30 s ends the same way (#135 case 17)" {
  stopped INT
}

@test "search: SIGHUP during a load that would go on for 30 s ends the same way (#135 case 17)" {
  stopped HUP
}

@test "search: a load that ignores TERM, as its child does, and is not back warm-up + load + load_grace_s after its start: TERM, 5 s, KILL to all it started, zero, exit 1 and the word timeout, within 15 s; the next start does not repeat the step and ends a memory load by the same cap (#135 case 19)" {
  start=$SECONDS
  values_with 's/^(core|mem)_(warmup|load)_s=[0-9]+/\1_\2_s=1/; s/^load_grace_s=3600/load_grace_s=1/'
  plan 'core@120/0 hang=30 deaf'
  search
  if ((SECONDS - start >= 15)); then
    printf 'the search took %s s\n' "$((SECONDS - start))" >&2
    return 1
  fi
  status_is 1
  [ "$(wc -w <"$MOCK/load.pids")" -eq 3 ]
  last_load "core 1 1 @120/0 pass"
  ends_at_zero
  # the load, its child and the child of that child were gone, reaped too, at the last zero
  gone_at_zero
  load_gone
  term_then_kill
  timeout_said 120
  not_passed 120 0
  grep -Eq '(^|[[:space:]])core=120([[:space:]]|$)' "$STATE/pending"
  no_result
  lock_free
  # the step counts as failed: the next start goes on with the memory phase, where a load
  # that would go on for 30 s but obeys TERM is ended 3 s after its start. The 5 s are for
  # a load that does not obey: with this one gone, the search is back before 7 s are over
  next_start
  start=$SECONDS
  plan 'mem@0/200 hang=30'
  search
  if ((SECONDS - start >= 7)); then
    printf 'the second start took %s s\n' "$((SECONDS - start))" >&2
    return 1
  fi
  status_is 1
  [ -z "$(loads | grep -E '^core 1 1 @(120|150|180|210|240)/0 ' || true)" ]
  logged 120 0 'fail|invalid'
  last_load "mem 1 1 1 @0/200 pass"
  [ "$(<"$MOCK/load.stopped")" = TERM ]
  ends_at_zero
  gone_at_zero
  load_gone
  timeout_said 200
  not_passed 0 200
  grep -Eq '(^|[[:space:]])mem=200([[:space:]]|$)' "$STATE/pending"
  no_result
}

@test "search: a soak load that takes 6 s, where warm-up + soak seconds + load_grace_s is 8, is left to end and its pass counts (#135 case 19)" {
  # 6 s is more than warm-up + core_soak_s (5), than warm-up + core_load_s + load_grace_s
  # (5) and than load_grace_s alone: a cap made of any of these ends this load
  values_with 's/^core_(warmup|load)_s=[0-9]+/core_\1_s=1/; s/^core_soak_s=5/core_soak_s=4/
    s/^load_grace_s=3600/load_grace_s=3/'
  plan 'core@210/1300 hang=6'
  search
  status_is 0
  [ "$(wc -w <"$MOCK/load.pids")" -eq 2 ]
  [ ! -e "$MOCK/load.stopped" ]
  [ "$(loads | grep -c '^core 1 4 @210/1300 pass$')" -eq 1 ]
  result_is 210 1300
  load_gone
  ends_at_zero
}

@test "search: SIGTERM during a load that ignores TERM, as its child does: KILL 5 s later to all the load started, then zero; back within 10 s, nothing of the load is left (#135 case 20)" {
  stopped TERM deaf
  term_then_kill
}

@test "search: every load, the check included, went through setpriv with the calling uid and gid and env -i, and none was started by uid 0 directly (#135 case 12)" {
  search
  status_is 0
  prefix="--reuid=$CALLER_UID --regid=$CALLER_GID --init-groups /usr/bin/env -i"
  prefix+=" HOME=$CALLER_HOME PATH=/usr/bin /usr/bin/bash $REPO/gpu/load.sh"
  [ "$(calls load | wc -l)" -eq 25 ]
  # the same arguments, call for call, each behind the ticket's command line
  [ "$(calls setpriv)" = "$(calls load | sed "s|^|$prefix |")" ]
  # setpriv execs: a load that came through it has the pid setpriv had
  [ "$(sed -En 's/^pid=([0-9]+) .*/\1/p' "$MOCK/load.detail")" = "$(<"$MOCK/setpriv.pids")" ]
  [ "$(load_env)" = "HOME=$CALLER_HOME PATH=/usr/bin" ]
}

@test "search: a load stdout with a line outside the grammar makes the step invalid (#135 case 13)" {
  for action in junk 'log=/home/pc-oc-caller/a:b' 'dup=Xid=0' 'reason=ok!'; do
    fresh
    plan "core@120/0 $action"
    search
    search_ended "core 2 3 @120/0 pass" 120 0
  done
}

@test "search: a load stdout with a missing key makes the step invalid (#135 case 13)" {
  for key in result reason pstate_min core_mhz_max mem_mhz_max limited xid log; do
    fresh
    plan "core@120/0 drop=$key"
    search
    search_ended "core 2 3 @120/0 pass" 120 0
  done
  fresh
  plan 'mem@0/300 drop=read_gbs'
  search
  search_ended "mem 4 6 1 @0/300 pass" 0 300
  fresh
  plan 'core@120/0 empty'
  search
  search_ended "core 2 3 @120/0 pass" 120 0
}

@test "search: a load stdout with a repeated key makes the step invalid (#135 case 13)" {
  for line in result=pass result=fail xid=0 log=/home/pc-oc-caller/other; do
    fresh
    plan "core@120/0 dup=$line"
    search
    search_ended "core 2 3 @120/0 pass" 120 0
  done
}

@test "search: a load whose exit status and result key disagree makes the step invalid: pass with 1, 3 or 7, fail with 0 or 3 (#135 case 16)" {
  # the block is a statement by the calling user's account; only 0 with pass, 1 with fail
  # and 3 with invalid agree
  for status in 1 3 7; do
    fresh
    plan "core@120/0 rc=$status"
    search
    search_ended "core 2 3 @120/0 pass" 120 0
  done
  for status in 0 3; do
    fresh
    plan "core@120/0 fail rc=$status"
    search
    search_ended "core 2 3 @120/0 fail" 120 0
  done
  fresh
  plan 'mem@0/300 rc=1'
  search
  search_ended "mem 4 6 1 @0/300 pass" 0 300
}

@test "search: a baseline load that says pass and exits 1 stops the search before any set (#135 case 16)" {
  plan 'core@0/0 rc=1'
  search
  status_is 1
  no_set
  no_result
}

@test "search: a core step whose core_mhz_max is 16 below baseline + offset is invalid; 15 below passes (#135 case 14)" {
  # baseline 2535, offset 120
  plan 'core@120/0 core_mhz_max=2639'
  search
  search_ended "core 2 3 @120/0 pass" 120 0
  fresh
  plan 'core@120/0 core_mhz_max=2640'
  search
  all_passed
}

@test "search: a step whose load passes in pstate 3 does not pass; pstate 2 does (#135 one step)" {
  plan 'core@150/0 pstate_min=3'
  search
  not_passed 150 0
  # as a failed step it ends the phase, as an invalid one the search: 180 never runs
  [[ ! " $(core_steps) " =~ \ (180|210|240)\  ]]
  [ ! -e "$STATE/result" ] || result_is 90 1300
  ends_at_zero
  fresh
  plan 'core@150/0 pstate_min=2' 'mem@0/700 pstate_min=1'
  search
  all_passed
}

@test "search: a later memory step whose clock is 6 MHz off does not pass (#135 one step)" {
  plan 'mem@0/700 mem_mhz_max=9706'
  search
  not_passed 0 700
  [[ ! " $(mem_steps) " =~ \ ([89]|1[0-5])00\  ]]
  [ ! -e "$STATE/result" ] || result_is 210 400
  ends_at_zero
}

@test "search: every SUDO_UID of the #117 list dies before the lock, the helper and any load, in LC_ALL=C (#135 amendment 1)" {
  bad_uids C
  # positive control: the fixture's caller is let through in this locale
  search LC_ALL=C
  all_passed
}

@test "search: every SUDO_UID of the #117 list dies the same way in en_US.UTF-8 (#135 amendment 1)" {
  locale -a | grep -qix 'en_US\.utf-\?8' || skip "no en_US.UTF-8 locale on this machine"
  bad_uids en_US.UTF-8
  search LC_ALL=en_US.UTF-8
  all_passed
}

@test "search: every such SUDO_GID dies before the lock, the helper and any load, in LC_ALL=C (#135 amendment 1)" {
  bad_gids C
  search LC_ALL=C
  status_is 0
  [[ "$(calls setpriv | head -n 1)" == "--reuid=$CALLER_UID --regid=$CALLER_GID --init-groups "* ]]
}

@test "search: every such SUDO_GID dies the same way in en_US.UTF-8 (#135 amendment 1)" {
  locale -a | grep -qix 'en_US\.utf-\?8' || skip "no en_US.UTF-8 locale on this machine"
  bad_gids en_US.UTF-8
  search LC_ALL=en_US.UTF-8
  status_is 0
  [[ "$(calls setpriv | head -n 1)" == "--reuid=$CALLER_UID --regid=$CALLER_GID --init-groups "* ]]
}

@test "search: a bad calling user is reported before the lock is looked at (#135 amendment 1)" {
  mkdir -p "$STATE"
  exec 8<"$STATE"
  flock -n 8
  start_as root "SUDO_UID=0" "SUDO_GID=$CALLER_GID"
  first_status="$status" first_stderr="$stderr"
  search
  exec 8<&-
  [ "$first_status" -eq 1 ]
  grep -q '^pc-oc: gpu: ' <<<"$first_stderr"
  [[ "$first_stderr" != *"already running"* ]]
  # positive control: with a good caller the same held lock is what stops the start
  said_line "pc-oc: gpu: search: already running"
  [ -z "$(calls nvml)$(calls setpriv)$(calls load)" ]
}

@test "search: nothing but SUDO_UID and SUDO_GID is taken from the environment: same steps, same result, state in /var/lib/pc-oc, loads see only HOME and PATH (#135 amendment 1)" {
  evil="$BATS_TEST_TMPDIR/evil"
  mkdir -p "$evil/state" "$evil/tmp"
  search "PC_OC_STATE=$evil/state" "SYSFS_ROOT=$evil" "HOME=$evil" "TMPDIR=$evil/tmp" \
    USER=root LOGNAME=root SUDO_USER=root "SUDO_HOME=$evil" "XDG_CACHE_HOME=$evil" \
    "XDG_STATE_HOME=$evil" "XDG_RUNTIME_DIR=$evil" "here=$evil" "home=$evil" \
    "state=$evil/state" "boot_id=$BOOT_B" "BOOT_ID=$BOOT_B" pl_w=1 core_start_mhz=15 \
    core_max_mhz=15 core_margin_mhz=15 core_load_s=9 mem_start_mhz=15 mem_max_mhz=15 \
    mem_device_index=7 mem_drop_pct=99 soak_backoffs=0 DRY_RUN=1 DEBUG=1 PC_OC_DEBUG=1 \
    "NVML=$evil/nvml.py" "LOAD=$evil/load.sh" "SEARCH_VALUES=$evil/search.values"
  all_passed
  [ "$(baseline_loads)" = "core 2 3 mem 4 6 1" ]
  [ "$(soaks core) $(soaks mem)" = "210/1300:pass 210/1300:pass" ]
  [ "$(loads | wc -l)" -eq 24 ]
  [ -e "$STATE/log" ]
  [ -z "$(find "$evil" -mindepth 2)" ]
  helper_calls_ok
  [ "$(calls getent | sort -u)" = "passwd 4242" ]
  [ "$(load_env)" = "HOME=$CALLER_HOME PATH=/usr/bin" ]
  [ "$(mock_paths)" = "PATH=/usr/bin" ]
}

@test "search.values: every line is key=value with a # src: id that resolves in sources/manifest.tsv (#135 case 15)" {
  [ "$(wc -l <"$ROOT/gpu/search.values")" -eq 18 ]
  while IFS= read -r line; do
    [[ "$line" =~ ^[a-z_]+=(0|[1-9][0-9]{0,3})[[:space:]]+#\ src:\ ([a-z0-9-]+)$ ]] || {
      echo "not key=value  # src: <id>: $line" >&2
      return 1
    }
    cut -f1 "$ROOT/sources/manifest.tsv" | grep -qx "${BASH_REMATCH[2]}" || {
      echo "the id does not resolve: $line" >&2
      return 1
    }
  done <"$ROOT/gpu/search.values"
}

@test "search.values: the shipped file holds the ticket's eighteen numbers, once each (#135 interface)" {
  for pair in core_start_mhz=90 core_step_mhz=30 core_max_mhz=240 core_margin_mhz=30 \
    core_warmup_s=30 core_load_s=120 core_soak_s=600 mem_start_mhz=200 mem_step_mhz=100 \
    mem_max_mhz=1500 mem_margin_mhz=200 mem_warmup_s=30 mem_load_s=90 mem_soak_s=360 \
    mem_drop_pct=3 mem_device_index=1 soak_backoffs=3 load_grace_s=120; do
    [ "$(grep -c "^${pair%%=*}=" "$ROOT/gpu/search.values")" -eq 1 ]
    grep -Eq "^$pair([[:space:]]|\$)" "$ROOT/gpu/search.values"
  done
}

@test "offsets.md: names every command of the runbook, in the ticket's order, and the three of Amendment 1 (#135 case 15)" {
  doc="$ROOT/gpu/offsets.md"
  at=-1
  for text in 'sudo pacman -S memtest_vulkan' 'gpu/burn-build.sh' 'sudo os/install.sh' \
    'sudo pc-oc apply gpu' 'sudo pc-oc search gpu' 'systemd.mask=pc-oc-gpu.service'; do
    # the first place it is named after the one before it
    next="$(grep -boF -- "$text" "$doc" | cut -d: -f1 | awk -v at="$at" '$1 > at' | head -n 1)"
    [ -n "$next" ] || {
      echo "missing, or not named after the one the ticket puts ahead of it: $text" >&2
      return 1
    }
    at="$next"
  done
  grep -qF 'StartLimitIntervalSec=infinity' "$doc"
  grep -qF 'systemctl restart pc-oc-gpu.service' "$doc"
  grep -qF 'systemctl reset-failed pc-oc-gpu.service' "$doc"
  grep -qi 'reboot' "$doc"
  grep -qw 'result' "$doc"
  grep -qw 'log' "$doc"
  grep -Eq '70 ?min' "$doc"
}

# section <heading>: the text of that "## " section of gpu/offsets.md, up to the next one
section() {
  awk -v want="## $1" '/^## / { inside = ($0 == want) } inside' "$ROOT/gpu/offsets.md"
}

@test "#150 case 16: offsets.md: the first-run section names the power limit, clock=unchecked and core_clock_delta, and its Report line asks for that fact; the trust section names the power limit and the memory soak" {
  measures="$(section 'What the first run measures')"
  trusts="$(section 'What the search trusts')"
  [ -n "$measures" ]
  [ -n "$trusts" ]
  grep -qi 'power limit' <<<"$measures"
  grep -qF 'clock=unchecked' <<<"$measures"
  grep -qF 'core_clock_delta' <<<"$measures"
  # the Report line is still one line, and it asks for the fifth fact: by its number or by
  # one of its three names
  [ "$(grep -c '^Report:' <<<"$measures")" -eq 1 ]
  grep '^Report:' <<<"$measures" | grep -Eqi 'five|fifth|power limit|clock=unchecked|core_clock_delta'
  grep -qi 'power limit' <<<"$trusts"
  grep -qi 'memory soak' <<<"$trusts"
  grep -qi 'cyberpunk' <<<"$trusts"
}

# Own cases of the implementation (#135), after the contract's last one.

@test "search: own: a memory device index above 9 and a drop of 100 percent are refused before anything runs" {
  values_refused 'mem_device_index=12' 's/^mem_device_index=[0-9]+/mem_device_index=12/'
  fresh
  values_refused 'mem_drop_pct=100' 's/^mem_drop_pct=[0-9]+/mem_drop_pct=100/'
}

@test "search: own: a memory baseline that reads 0 GB/s is no verdict: exit 1 before any set" {
  plan 'mem@0/0 read_gbs=0.00'
  search
  status_is 1
  no_set
  [ -z "$(core_steps)$(mem_steps)" ]
  no_result
  ends_at_zero
}

@test "search: own: only a step the search died in, found at 0 in another boot, is reported as the reboot fact" {
  crashed_at mem@0/700
  printf '%s\n' "$BOOT_B" >"$GUARD_BOOT_ID"
  search
  status_is 0
  [[ "$output" == *"measured: the reboot cleared the offsets"* ]]
  # a step the search ended itself was set to 0 by the search, not by the reboot
  fresh
  plan 'core@150/0 xid'
  search
  status_is 1
  next_start
  printf '%s\n' "$BOOT_B" >"$GUARD_BOOT_ID"
  search
  status_is 0
  [[ "$output" != *"measured:"* ]]
  # and in the same boot nothing was measured either
  fresh
  crashed_at core@150/0
  echo 150 >"$MOCK/nvml.core"
  search
  status_is 0
  [[ "$output" != *"measured:"* ]]
}

# The three cases below: a start that holds the lock and finds a pending step whose
# offset is still set (same boot) runs nvml.py zero on every way out.

@test "search: own: a pending step and a progress file that does not parse: exit 1, and zero ran" {
  crashed_at core@150/0
  echo 150 >"$MOCK/nvml.core"
  echo 'core_last=12x' >"$STATE/progress"
  search
  status_is 1
  said 'progress does not parse'
  ends_at_zero
}

@test "search: own: a pending step and a log that cannot be written: exit 1, and zero ran" {
  crashed_at core@150/0
  echo 150 >"$MOCK/nvml.core"
  rm -f "$STATE/log"
  mkdir "$STATE/log"
  search
  status_is 1
  ends_at_zero
}

@test "search: own: a pending step and a signal while the first get runs: exit 1, and zero ran" {
  crashed_at core@150/0
  echo 150 >"$MOCK/nvml.core"
  # the fake helper's get reads this fifo, so it stays until the lines below are written;
  # TERM reaches the search (the pid guard.sh wrote for this start) in between
  rm -f "$MOCK/search.pid"
  mkfifo "$MOCK/nvml.get"
  (
    for _ in {1..100}; do
      ! grep -qx 'nvml get' "$MOCK/events" 2>/dev/null || break
      sleep 0.05
    done
    [[ ! -s "$MOCK/search.pid" ]] || kill -TERM "$(<"$MOCK/search.pid")"
    sleep 0.3
    # shellcheck disable=SC2016 # the inner shell expands these
    timeout 10 bash -c 'printf "%s\n" "$@" >"$0"' "$MOCK/nvml.get" \
      'p0.core offset=150 min=-500 max=500' 'p0.mem offset=0 min=-2000 max=3000' \
      'p1.core unsupported' 'p1.mem unsupported' \
      'p2.core offset=150 min=-500 max=500' 'p2.mem offset=0 min=-2000 max=3000'
  ) 3>&- &
  search
  wait
  status_is 1
  [ "$(calls nvml | paste -sd' ')" = "get zero" ]
  ends_at_zero
  no_load
}

@test "search: own: a tool the load started in a process group of its own is ended before zero as well" {
  local pid left="" runner group session
  # gpu/load.sh of the fake tree (guard.sh binds nothing there) is a runner of this case:
  # its core load at offset 120 starts a tool under timeout(1), as the real gpu/load.sh
  # does, tells the search to stop and obeys no TERM. Any other call is the contract's
  # mock load. The tool notes its process group and session, then stays for 20 s.
  cp "$FIX/load.sh" "$REPO/gpu/load.mock.sh"
  cat >"$REPO/gpu/tool.sh" <<'EOF'
#!/usr/bin/bash
s=/var/lib/pc-oc-test-mock
/usr/bin/mkfifo "$s/wait.$$"
stat="$(<"/proc/$$/stat")"
read -r _ _ group session _ <<<"${stat##*) }"
echo "$group $session" >"$s/tool.ids"
echo "$$" >"$s/tool.pid"
read -rt 20 _ <>"$s/wait.$$"
EOF
  cat >"$REPO/gpu/load.sh" <<'EOF'
#!/usr/bin/bash
here="${BASH_SOURCE[0]%/*}"
s=/var/lib/pc-oc-test-mock
core=0
[[ ! -e "$s/nvml.core" ]] || core="$(<"$s/nvml.core")"
[[ "${1-}" == core && "$core" == 120 ]] || exec /usr/bin/bash "$here/load.mock.sh" "$@"
printf 'load %s\n' "$*" >>"$s/events"
/usr/bin/mkfifo "$s/wait.$$"
/usr/bin/timeout -k 10 20 /usr/bin/bash "$here/tool.sh" &
tool=$!
for _ in {1..500}; do
  [[ ! -s "$s/tool.pid" ]] || break
  read -rt 0.01 _ <>"$s/wait.$$" || true
done
echo "$$ $tool $(<"$s/tool.pid")" >>"$s/load.pids"
trap ':' TERM INT HUP
kill -TERM "$(<"$s/search.pid")"
end=$((SECONDS + 20))
while ((SECONDS < end)); do
  read -rt 1 _ <>"$s/wait.$$" || true
done
EOF
  search
  # first of all nothing this case started outlives it, whatever the search did; only a
  # pid that still is a process of this test's tree gets the KILL
  for pid in $(<"$MOCK/load.pids"); do
    if { tr '\0' ' ' <"/proc/$pid/cmdline"; } 2>/dev/null | grep -qF " $REPO/gpu/"; then
      left+=" $pid"
      kill -KILL "$pid" 2>/dev/null || true
    fi
  done
  status_is 1
  # the case is the one its name says: the load's session, another process group
  read -r runner _ <"$MOCK/load.pids"
  read -r group session <"$MOCK/tool.ids"
  [ "$session" = "$runner" ]
  [ "$group" != "$runner" ]
  gone_at_zero
  [ -z "$left" ]
  ends_at_zero
  lock_free
}

@test "search: own: a start that finds a result runs nothing, leaves the file as it is and exits 0" {
  local before
  search
  all_passed
  before="$(stat -c '%i %y' "$STATE/result") $(<"$STATE/result")"
  next_start
  search
  status_is 0
  no_set
  no_load
  [[ "$output" == *"core_offset_mhz=210"* && "$output" == *"nothing was run"* ]]
  [ "$(stat -c '%i %y' "$STATE/result") $(<"$STATE/result")" = "$before" ]
}

@test "search: own: the stop at a memory clock in another unit counts no step: the next start sets 200 again and stops the same way" {
  plan 'mem@0/200 mem_mhz_max=9100'
  search
  status_is 1
  [ ! -e "$STATE/pending" ]
  next_start
  search
  status_is 1
  said 'unit of the NVML memory offset'
  [ "$(mem_steps)" = 200 ]
  logged 0 200 invalid clock
  ends_at_zero
  no_result
  [ ! -e "$STATE/pending" ]
}

@test "search: own: a gpu/load.sh check that is not back after load_grace_s is ended: exit 1, nothing set" {
  local start=$SECONDS
  # a runner of this case in the fake tree: its check stays for 20 s unless it is told to
  # stop; any other call is the contract's mock load
  cp "$FIX/load.sh" "$REPO/gpu/load.mock.sh"
  cat >"$REPO/gpu/load.sh" <<'EOF'
#!/usr/bin/bash
s=/var/lib/pc-oc-test-mock
[[ "$*" == check ]] || exec /usr/bin/bash "${BASH_SOURCE[0]%/*}/load.mock.sh" "$@"
printf 'load %s\n' "$*" >>"$s/events"
echo "$$" >>"$s/load.pids"
/usr/bin/mkfifo "$s/wait.$$"
read -rt 20 _ <>"$s/wait.$$"
EOF
  values_with 's/^load_grace_s=[0-9]+/load_grace_s=1/'
  search
  status_is 1
  if ((SECONDS - start >= 10)); then
    printf 'the search took %s s with a cap of 1 s on the check\n' "$((SECONDS - start))" >&2
    return 1
  fi
  timeout_said 1
  load_gone
  [ "$(calls load)" = check ]
  no_set
  no_result
  lock_free
}

@test "search: own: a clock that is stored as 0 is not soaked" {
  plan 'core@90/0 fail'
  search
  status_is 0
  [ -z "$(soaks core)" ]
  [ "$(soaks mem)" = "0/1300:pass" ]
  result_is 0 1300
  # both stored as 0: no soak load at all
  fresh
  plan 'core@90/0 fail' 'mem@0/200 fail'
  search
  status_is 0
  [ -z "$(soaks core)$(soaks mem)" ]
  result_is 0 0
}

@test "search: own: a block with a key its kind does not have, or with a key twice, makes the step invalid" {
  local action
  for action in 'dup=extra=1' 'dup=read_gbs=400.0' 'dup=xid=0'; do
    fresh
    plan "core@120/0 $action"
    search
    search_ended "core 2 3 @120/0 pass" 120 0
    logged 120 0 invalid block
  done
}

@test "search: own: a block of 4097 bytes makes the step invalid, one of 4096 bytes does not" {
  local value
  # the block of the core step at 120 is 103 bytes and the log value: the 91 of #134 and
  # the 12 of the power_cap line of #150
  power_cap_blocks
  value="/$(printf 'a%.0s' {1..3993})"
  plan "core@120/0 log=$value"
  search
  [ "$(stat -c %s "$STATE/block")" -eq 4097 ]
  search_ended "core 2 3 @120/0 pass" 120 0
  logged 120 0 invalid block
  fresh
  plan "core@120/0 log=${value%a}"
  search
  status_is 0
  logged 120 0 pass
}

@test "search: own: a block of more than 16 lines makes the step invalid" {
  # 9 lines of the kind, the power_cap line of #150 among them, and xid=0 eight more times
  power_cap_blocks
  plan "core@120/0$(printf ' dup=xid=0%.0s' {1..8})"
  search
  [ "$(wc -l <"$STATE/block")" -eq 17 ]
  search_ended "core 2 3 @120/0 pass" 120 0
  logged 120 0 invalid block
}

@test "search: own: a reason that is empty or has more than lower-case letters, digits, _ and - makes the step invalid" {
  local action
  for action in 'reason=Ok' 'reason=a.b' 'reason='; do
    fresh
    plan "core@120/0 $action"
    search
    search_ended "core 2 3 @120/0 pass" 120 0
    logged 120 0 invalid block
  done
}

@test "search: own: a block that says pass and names an Xid is no pass: the step is invalid" {
  plan 'core@120/0 xid=1'
  search
  search_ended "core 2 3 @120/0 pass" 120 0
  logged 120 0 invalid block
}

@test "search: own: a block that says pass and limited=1 is no pass: the step is invalid" {
  plan 'core@120/0 limited=1'
  search
  search_ended "core 2 3 @120/0 pass" 120 0
  logged 120 0 invalid block
}

# The cases below: stdout, or stdout and stderr, of the search is a pipe whose reader
# leaves (| head, a pager that was quit, tee after Ctrl+C). A print nobody takes ends
# nothing above the zero, changes no verdict and keeps no line from the log; the search
# then ends where no step is open, exit 1.

# piped <reader...>: a start as search makes it, its stdout into the reader. SIGPIPE has
# its default action when the search starts, whatever this test run was started with.
# Under run, status is the exit status of the search and output what the reader printed.
piped() {
  in_ns root /usr/bin/env --default-signal=PIPE -i PATH=/usr/bin "SUDO_UID=$CALLER_UID" \
    "SUDO_GID=$CALLER_GID" /usr/bin/bash "$REPO/gpu/search.sh" | "$@"
  return "${PIPESTATUS[0]}"
}

# piped_both <reader...>: the same with stderr in that pipe as well, as 2>&1 | reader
piped_both() {
  in_ns root /usr/bin/env --default-signal=PIPE -i PATH=/usr/bin "SUDO_UID=$CALLER_UID" \
    "SUDO_GID=$CALLER_GID" /usr/bin/bash "$REPO/gpu/search.sh" 2>&1 | "$@"
  return "${PIPESTATUS[0]}"
}

# piped_err <reader...>: stderr alone in the pipe, stdout in the file stdout of the
# test's temporary directory
piped_err() {
  in_ns root /usr/bin/env --default-signal=PIPE -i PATH=/usr/bin "SUDO_UID=$CALLER_UID" \
    "SUDO_GID=$CALLER_GID" /usr/bin/bash "$REPO/gpu/search.sh" 2>&1 >"$BATS_TEST_TMPDIR/stdout" | "$@"
  return "${PIPESTATUS[0]}"
}

@test "search: own: stdout into a reader that has left, TERM during a load: the step is logged, zero ran, exit 1" {
  # head leaves after the lines of the two baseline loads and of the core step at 90
  plan 'core@120/0 signal=TERM hang=30'
  run --separate-stderr piped head -n 3
  ends_at_zero
  status_is 1
  [ "$(<"$MOCK/signal.sent")" = TERM ]
  logged 120 0 invalid signal
  gone_at_zero
  load_gone
  [ -e "$STATE/pending" ]
  no_result
  lock_free
  # with a reader that stays it ends the same way, and the reader gets the step's line
  fresh
  plan 'core@120/0 signal=TERM hang=30'
  run --separate-stderr piped cat
  ends_at_zero
  status_is 1
  logged 120 0 invalid signal
  grep -Fxq 'phase=core core=120 mem=0 result=invalid reason=signal' <<<"$output"
  said 'got a signal'
}

@test "search: own: stdout into a reader that has left, no signal: the step that ran for nobody keeps its verdict, then the search ends: zero ran, exit 1, and the next start goes on" {
  run --separate-stderr piped head -n 3
  ends_at_zero
  status_is 1
  [ "$(wc -l <<<"$output")" -eq 3 ]
  # the step at 120 passed, its line could not be printed: in the log and counted, and
  # no further step was started
  [ "$(core_steps)" = "90 120" ]
  logged 120 0 pass
  [ ! -e "$STATE/pending" ]
  said 'could not be printed'
  no_result
  next_start
  search
  status_is 0
  [ "$(core_steps)" = "150 180 210 240" ]
  result_is 210 1300
}

@test "search: own: a pending step with its offset still set, stdout into a reader that has left: the crash is logged, zero ran, exit 1" {
  crashed_at core@150/0
  echo 150 >"$MOCK/nvml.core"
  run --separate-stderr piped true
  ends_at_zero
  status_is 1
  [ "$(calls nvml | paste -sd' ')" = "get zero" ]
  logged 150 0 fail crash
  [ -z "$(calls load)" ]
  # the crash is counted once: the next start stores core 90 and goes on with memory
  next_start
  search
  status_is 0
  [ -z "$(core_steps)" ]
  result_is 90 1300
}

@test "search: own: stdout and stderr into one reader that has left, TERM during a load: the step is logged, zero ran, exit 1" {
  # sed leaves at the line of the core step at 90, so "got a signal" has no reader either
  plan 'core@120/0 signal=TERM hang=30'
  run --separate-stderr piped_both sed '/core=90 .*result=pass/q'
  ends_at_zero
  status_is 1
  [ "$(<"$MOCK/signal.sent")" = TERM ]
  logged 120 0 invalid signal
  gone_at_zero
  load_gone
  [ -e "$STATE/pending" ]
  lock_free
}

@test "search: own: the search ignores SIGPIPE and every load it starts has the default action back" {
  local search load n=0
  # gpu/load.sh of the fake tree is a stand-in of this case: it notes the signals the
  # search and it itself ignore (SigIgn of /proc/<pid>/status, where SIGPIPE, signal 13,
  # is the bit 0x1000), then it is the contract's mock load
  cp "$FIX/load.sh" "$REPO/gpu/load.mock.sh"
  cat >"$REPO/gpu/load.sh" <<'EOF'
#!/usr/bin/bash
# pc-oc-test-mock
s=/var/lib/pc-oc-test-mock
ign() { /usr/bin/sed -n 's/^SigIgn:[[:space:]]*//p' "/proc/$1/status"; }
echo "$(ign "$(<"$s/search.pid")") $(ign "$$")" >>"$s/load.sigign"
exec /usr/bin/bash "${BASH_SOURCE[0]%/*}/load.mock.sh" "$@"
EOF
  run --separate-stderr piped head -n 3
  ends_at_zero
  status_is 1
  while read -r search load; do
    n=$((n + 1))
    if (((16#$search & 0x1000) == 0 || (16#$load & 0x1000) != 0)); then
      printf 'load %s: SigIgn of the search %s, of the load %s\n' "$n" "$search" "$load" >&2
      return 1
    fi
  done <"$MOCK/load.sigign"
  # the check, the two baseline loads and the core steps at 90 and 120
  [ "$n" -eq 5 ]
}

@test "search: own: a pending step, a zero that fails and nobody to read the capitals: one zero, exit 1" {
  crashed_at core@150/0
  echo 150 >"$MOCK/nvml.core"
  helper_fails all 1 zero
  run --separate-stderr piped_both true
  status_is 1
  # the message that could not be printed did not end the start above its own exit: a
  # start that left there would run zero once more on its way out
  [ "$(calls nvml | paste -sd' ')" = "get zero" ]
  logged 150 0 fail crash
}

@test "search: own: a start-up refusal nobody reads is exit 1 all the same and calls nothing" {
  rm "$REPO/gpu/search.values"
  run --separate-stderr piped_both true
  status_is 1
  [ -z "$(calls nvml)$(calls python3)$(calls setpriv)$(calls load)" ]
  [ ! -e "$VARLIB/pc-oc" ]
}

@test "search: own: stdout into a reader that left before the first line: the load that ran is logged, no further one starts, nothing is set, exit 1" {
  run --separate-stderr piped true
  ends_at_zero
  status_is 1
  [ "$(baseline_loads)" = "core 2 3" ]
  logged 0 0 pass
  no_set
  said 'could not be printed'
  next_start
  search
  all_passed
}

@test "search: own: a finished search whose result nobody reads does not say 0: the result is written, zero ran, exit 1" {
  # head leaves after the lines of all 24 steps, ahead of the lines of the result
  run --separate-stderr piped head -n 24
  ends_at_zero
  status_is 1
  [ "$(wc -l <"$STATE/log")" -eq 24 ]
  result_is 210 1300
  said 'could not be printed'
  # the same for a start that finds that result and has nobody to show it to
  next_start
  run --separate-stderr piped true
  ends_at_zero
  status_is 1
  no_set
  no_load
  said 'could not be printed'
  result_is 210 1300
}

@test "search: own: stderr alone into a reader that has left: the load dies of its own SIGPIPE, an invalid step, zero ran, exit 1" {
  # the mock load writes a line to stderr ahead of its block: with the default action
  # that write ends it, and no block is no pass. What the search then says has no reader
  run --separate-stderr piped_err true
  ends_at_zero
  status_is 1
  [ "$(baseline_loads)" = "core 2 3" ]
  logged 0 0 invalid block
  grep -Fxq 'phase=baseline-core core=0 mem=0 result=invalid reason=block' "$BATS_TEST_TMPDIR/stdout"
  no_set
  no_result
  lock_free
}

# Contract for #150, cases 8 to 15 of its Check list. Every block of the mock load has the
# power_cap line here (power_cap_blocks). The numbers are the mock's: a core load reads
# 2535 MHz plus the core offset, at any memory offset, so the core baseline is 2535, the
# memory baseline's core clock is 2535 as well, and a memory soak at core 210 reads 2745
# unless the plan says otherwise. 2190 is a core clock held down by the power limit (the
# pre-flight of #121 saw 2130 to 2475 at stock).

@test "#150 case 8: search: a block without power_cap, with it twice, with power_cap=2 or with it empty makes the step invalid, reason block, and the offsets are zeroed" {
  local action
  for action in drop=power_cap dup=power_cap=0 dup=power_cap=1 power_cap=2 power_cap=; do
    power_cap_blocks
    plan "core@120/0 $action"
    search
    search_ended "core 2 3 @120/0 pass" 120 0
    logged 120 0 invalid block
  done
  # the memory kind has the key as well
  for action in drop=power_cap dup=power_cap=0 power_cap=2; do
    power_cap_blocks
    plan "mem@0/300 $action"
    search
    search_ended "mem 4 6 1 @0/300 pass" 0 300
    logged 0 300 invalid block
  done
  # and so has a baseline load: no verdict there is no search, nothing is set
  power_cap_blocks
  plan 'core@0/0 power_cap=2'
  search
  status_is 1
  logged 0 0 invalid block
  no_set
  no_result
}

@test "#150 case 9: search: a capped baseline and core loads far under baseline + offset: every core step and the core soak pass, each line ends clock=unchecked, and the baseline file holds core_power_cap=1" {
  # every core load at the power limit and its clock where the limit puts it, with an
  # offset as without: the step at 240 is 225 MHz under baseline + offset
  power_cap_blocks
  plan 'core@* power_cap=1 core_mhz_max=2190'
  search
  all_passed
  for mhz in 90 120 150 180 210 240; do
    step_line core "$mhz" 0 'result=pass reason=ok clock=unchecked'
  done
  step_line soak-core 210 1300 'result=pass reason=ok clock=unchecked'
  [ "$(grep -Ec ' phase=(core|soak-core) .* clock=unchecked$' "$STATE/log")" -eq 7 ]
  [ "$(grep -Ec ' phase=(mem|soak-mem|baseline-mem) .*clock=' "$STATE/log")" -eq 0 ]
  [ "$(grep -c '^core_power_cap=' "$STATE/baseline")" -eq 1 ]
  grep -Fxq 'core_power_cap=1' "$STATE/baseline"
  # the capped baseline alone is enough: a step that reports no cap itself is not checked
  power_cap_blocks
  plan 'core@0/0 power_cap=1 core_mhz_max=2190' 'core@* core_mhz_max=2190'
  search
  all_passed
  for mhz in 90 120 150 180 210 240; do
    step_line core "$mhz" 0 'result=pass reason=ok clock=unchecked'
  done
  step_line soak-core 210 1300 'result=pass reason=ok clock=unchecked'
  grep -Fxq 'core_power_cap=1' "$STATE/baseline"
}

@test "#150 case 10: search: an uncapped baseline and an uncapped core load: 16 MHz under baseline + offset is invalid, reason clock, as before; 15 under passes and the line has no clock= field" {
  # baseline 2535, offset 120
  power_cap_blocks
  plan 'core@120/0 core_mhz_max=2639'
  search
  search_ended "core 2 3 @120/0 pass" 120 0
  step_line core 120 0 'result=invalid reason=clock'
  grep -Fxq 'core_power_cap=0' "$STATE/baseline"
  power_cap_blocks
  plan 'core@120/0 core_mhz_max=2640'
  search
  all_passed
  step_line core 120 0 'result=pass reason=ok'
  step_line soak-core 210 1300 'result=pass reason=ok'
  [ "$(grep -c 'clock=unchecked' "$STATE/log")" -eq 0 ]
  [ "$(grep -c 'clock=unchecked' <<<"$output")" -eq 0 ]
  [ "$(grep -c '^core_power_cap=' "$STATE/baseline")" -eq 1 ]
  grep -Fxq 'core_power_cap=0' "$STATE/baseline"
  # the core soak is checked as a step is: offset 210, 16 under
  power_cap_blocks
  plan 'core@210/1300 core_mhz_max=2729'
  search
  search_ended "core 2 5 @210/1300 pass" 210 1300
  step_line soak-core 210 1300 'result=invalid reason=clock'
}

@test "#150 case 11: search: an uncapped baseline and a capped core load: it passes whatever its clock, its line ends clock=unchecked, and no other line does" {
  power_cap_blocks
  plan 'core@120/0 power_cap=1 core_mhz_max=2300'
  search
  all_passed
  step_line core 120 0 'result=pass reason=ok clock=unchecked'
  step_line core 90 0 'result=pass reason=ok'
  step_line core 150 0 'result=pass reason=ok'
  step_line soak-core 210 1300 'result=pass reason=ok'
  [ "$(grep -c 'clock=unchecked' "$STATE/log")" -eq 1 ]
  grep -Fxq 'core_power_cap=0' "$STATE/baseline"
  # a capped step whose clock is at the offset is unchecked all the same
  power_cap_blocks
  plan 'core@120/0 power_cap=1'
  search
  all_passed
  step_line core 120 0 'result=pass reason=ok clock=unchecked'
  [ "$(grep -c 'clock=unchecked' "$STATE/log")" -eq 1 ]
  # the core soak
  power_cap_blocks
  plan 'core@210/1300 power_cap=1 core_mhz_max=2300'
  search
  all_passed
  step_line soak-core 210 1300 'result=pass reason=ok clock=unchecked'
  step_line core 210 0 'result=pass reason=ok'
  [ "$(grep -c 'clock=unchecked' "$STATE/log")" -eq 1 ]
}

@test "#150 case 11: search: only the core clock check is left out for a capped load: pstate, limited and the memory clock are judged as before" {
  power_cap_blocks
  plan 'core@150/0 power_cap=1 pstate_min=3'
  search
  not_passed 150 0
  [[ ! " $(core_steps) " =~ \ (180|210|240)\  ]]
  ends_at_zero
  power_cap_blocks
  plan 'core@150/0 power_cap=1 limited=1'
  search
  search_ended "core 2 3 @150/0 pass" 150 0
  logged 150 0 invalid block
  # a memory load at the power limit, in a search whose core loads are capped too
  power_cap_blocks
  plan 'core@* power_cap=1 core_mhz_max=2190' 'mem@0/700 power_cap=1 mem_mhz_max=9706'
  search
  not_passed 0 700
  [[ ! " $(mem_steps) " =~ \ ([89]|1[0-5])00\  ]]
  ends_at_zero
  # and one at the offset passes, with no field on its line
  power_cap_blocks
  plan 'mem@0/700 power_cap=1'
  search
  all_passed
  step_line mem 0 700 'result=pass reason=ok'
}

@test "#150 case 12: search: the memory soak at a core offset ends its line core_clock_delta=<n>, n its core clock less that of the memory baseline, signed; a memory step at core 0 has no such field; the verdict is the same for any n" {
  # a higher clock: 2745 under the soak, 2535 under the memory baseline
  power_cap_blocks
  search
  all_passed
  step_line soak-mem 210 1300 'result=pass reason=ok core_clock_delta=210'
  for mhz in 200 700 1300 1500; do
    step_line mem 0 "$mhz" 'result=pass reason=ok'
  done
  [ "$(grep -c 'core_clock_delta' "$STATE/log")" -eq 1 ]
  [ "$(grep -c '^mem_core_mhz_max=' "$STATE/baseline")" -eq 1 ]
  grep -Fxq 'mem_core_mhz_max=2535' "$STATE/baseline"
  # a lower one
  power_cap_blocks
  plan 'mem@210/1300 core_mhz_max=2500'
  search
  all_passed
  step_line soak-mem 210 1300 'result=pass reason=ok core_clock_delta=-35'
  # the same one
  power_cap_blocks
  plan 'mem@210/1300 core_mhz_max=2535'
  search
  all_passed
  step_line soak-mem 210 1300 'result=pass reason=ok core_clock_delta=0'
  # it is the memory baseline's core clock that counts, not the core baseline's 2535
  power_cap_blocks
  plan 'mem@0/0 core_mhz_max=2730'
  search
  all_passed
  step_line soak-mem 210 1300 'result=pass reason=ok core_clock_delta=15'
  grep -Fxq 'mem_core_mhz_max=2730' "$STATE/baseline"
  grep -Fxq 'core_mhz_max=2535' "$STATE/baseline"
}

@test "#150 case 13: search: a result after an unchecked core step: the power limit line is printed before the result lines, also when the step was in an earlier start; with no unchecked step it is not printed" {
  local moved='gpu: search: core offset 210 MHz moved the core clock by'
  # one capped step in an uncapped search; the memory soak reads 2700, 165 over its baseline
  power_cap_blocks
  plan 'core@120/0 power_cap=1 core_mhz_max=2300' 'mem@210/1300 core_mhz_max=2700'
  search_both
  all_passed
  [ "$(line_at "$MSG_UNCHECKED")" -lt "$(line_at core_offset_mhz=210)" ]
  line_at "$moved 165 MHz under the memory load"
  # a lower clock under the memory soak
  power_cap_blocks
  plan 'core@120/0 power_cap=1 core_mhz_max=2300' 'mem@210/1300 core_mhz_max=2500'
  search_both
  all_passed
  line_at "$MSG_UNCHECKED"
  line_at "$moved -35 MHz under the memory load"
  # the unchecked step in one start, the end in the next: the memory step at 700 ends the
  # first start, the second runs no core step and no unchecked core soak
  power_cap_blocks
  plan 'core@120/0 power_cap=1 core_mhz_max=2300' 'mem@0/700 invalid times=1'
  search
  search_ended "mem 4 6 1 @0/700 invalid" 0 700
  [ "$(grep -c ' clock=unchecked$' "$STATE/log")" -eq 1 ]
  next_start
  search_both
  status_is 0
  [ -z "$(core_steps)" ]
  result_is 210 400
  [ "$(grep -c ' clock=unchecked$' "$STATE/log")" -eq 1 ]
  [ "$(line_at "$MSG_UNCHECKED")" -lt "$(line_at core_offset_mhz=210)" ]
  line_at "$moved 210 MHz under the memory load"
  # no unchecked step: no such line, on either stream
  power_cap_blocks
  search_both
  all_passed
  [ "$(grep -c 'clock=unchecked' "$STATE/log")" -eq 0 ]
  [ "$(grep -Fc "$MSG_UNCHECKED" <<<"$output")" -eq 0 ]
}

@test "#150 case 14: search: a baseline file without core_power_cap is refused at the start: exit 1, no set, no load, and one line names the file and sudo rm -r of the state directory" {
  local named
  power_cap_blocks
  old_baseline
  search_both
  status_is 1
  no_set
  no_load
  no_result
  named="$(grep -F '/var/lib/pc-oc/gpu/search/baseline' <<<"$output")"
  [ "$(wc -l <<<"$named")" -eq 1 ]
  [[ "$named" =~ sudo\ rm\ -r\ /var/lib/pc-oc/gpu/search([^/[:alnum:]]|$) ]]
  # the same in the middle of a search that the script before #150 began
  power_cap_blocks
  old_baseline
  printf '%s\n' core_last=120 >"$STATE/progress"
  search_both
  status_is 1
  no_set
  no_load
  no_result
  named="$(grep -F '/var/lib/pc-oc/gpu/search/baseline' <<<"$output")"
  [ "$(wc -l <<<"$named")" -eq 1 ]
  [[ "$named" =~ sudo\ rm\ -r\ /var/lib/pc-oc/gpu/search([^/[:alnum:]]|$) ]]
}

@test "#150 case 15: search: the result file of a capped search and of an uncapped one with the same steps is the same, byte for byte, but for finished=" {
  power_cap_blocks
  search
  all_passed
  [ "$(grep -c 'clock=unchecked' "$STATE/log")" -eq 0 ]
  sed 's/^finished=.*/finished=/' "$STATE/result" >"$BATS_TEST_TMPDIR/uncapped"
  power_cap_blocks
  plan 'core@* power_cap=1 core_mhz_max=2190'
  search
  all_passed
  [ "$(grep -c ' clock=unchecked$' "$STATE/log")" -eq 7 ]
  sed 's/^finished=.*/finished=/' "$STATE/result" >"$BATS_TEST_TMPDIR/capped"
  cmp "$BATS_TEST_TMPDIR/uncapped" "$BATS_TEST_TMPDIR/capped"
  # and it is the file of #135, which gpu/apply.sh reads (#142): the two offsets and
  # finished=, in that order, nothing else
  [ "$(<"$BATS_TEST_TMPDIR/capped")" = $'core_offset_mhz=210\nmem_offset_mhz=1300\nfinished=' ]
}

# Own cases of the implementation (#150): what the contract leaves open, one choice each.

# end_lines: of the text on stdin, the lines that #150 puts ahead of the result
end_lines() {
  grep -E 'power limit|moved the core clock' || true
}

@test "search: own: #150: the two end lines are on stdout behind pc-oc:, the power limit line, then the moved line, then the result; without an unchecked step the moved line is printed alone" {
  local moved='gpu: search: core offset 210 MHz moved the core clock by 210 MHz under the memory load'
  local at
  plan 'core@120/0 power_cap=1 core_mhz_max=2300'
  search
  all_passed
  [ "$(end_lines <<<"$output")" = "pc-oc: $MSG_UNCHECKED"$'\n'"pc-oc: $moved" ]
  at="$(line_at "$MSG_UNCHECKED")"
  [ "$(line_at "$moved")" -eq $((at + 1)) ]
  [ "$(line_at core_offset_mhz=210)" -eq $((at + 2)) ]
  # nothing of it on stderr
  [ "$(grep -Ec 'power limit|moved the core clock' <<<"$stderr")" -eq 0 ]
  # no unchecked step: the measurement of the memory soak is printed all the same
  fresh
  search
  all_passed
  [ "$(end_lines <<<"$output")" = "pc-oc: $moved" ]
  [ "$(line_at core_offset_mhz=210)" -eq $(($(line_at "$moved") + 1)) ]
  # no core offset in the result, so no memory soak at one: neither line
  fresh
  plan 'core@90/0 fail'
  search
  status_is 0
  result_is 0 1300
  [ -z "$(end_lines <<<"$output")" ]
  [ "$(grep -c 'core_clock_delta' "$STATE/log")" -eq 0 ]
}

@test "search: own: #150: after more than one memory soak the moved line gives the last one's number, and a memory soak that fails has its core_clock_delta too" {
  plan 'mem@210/1300 fail core_mhz_max=2600' 'mem@210/1200 core_mhz_max=2700'
  search
  status_is 0
  result_is 210 1200
  [ "$(soaks mem)" = "210/1300:fail 210/1200:pass" ]
  step_line soak-mem 210 1300 'result=fail reason=errors core_clock_delta=65'
  step_line soak-mem 210 1200 'result=pass reason=ok core_clock_delta=165'
  [ "$(end_lines <<<"$output")" = "pc-oc: gpu: search: core offset 210 MHz moved the core clock by 165 MHz under the memory load" ]
  # the core soak backed off first: the number belongs to the core offset of the result
  fresh
  plan 'core@210/1300 fail' 'mem@180/1300 core_mhz_max=2700'
  search
  status_is 0
  result_is 180 1300
  [ "$(end_lines <<<"$output")" = "pc-oc: gpu: search: core offset 180 MHz moved the core clock by 165 MHz under the memory load" ]
}

@test "search: own: #150: a memory soak with an Xid, or with no pass in its block, still says how far the core clock moved; one whose block is refused does not" {
  plan 'mem@210/1300 xid core_mhz_max=2700'
  search
  search_ended "mem 4 7 1 @210/1300 fail" 210 1300
  step_line soak-mem 210 1300 'result=fail reason=xid core_clock_delta=165'
  fresh
  plan 'mem@210/1300 invalid'
  search
  search_ended "mem 4 7 1 @210/1300 invalid" 210 1300
  step_line soak-mem 210 1300 'result=invalid reason=limited core_clock_delta=210'
  fresh
  plan 'mem@210/1300 junk'
  search
  search_ended "mem 4 7 1 @210/1300 pass" 210 1300
  step_line soak-mem 210 1300 'result=invalid reason=block'
}

@test "search: own: #150: clock=unchecked is on passed core loads only: a capped core step that fails or gives no verdict has no field, and a load that fails is a fail whatever its power_cap says" {
  plan 'core@150/0 power_cap=1 fail'
  search
  status_is 0
  [ "$(core_steps)" = "90 120 150" ]
  step_line core 150 0 'result=fail reason=errors'
  [ "$(grep -c 'clock=unchecked' "$STATE/log")" -eq 0 ]
  [ "$(grep -Fc "$MSG_UNCHECKED" <<<"$output")" -eq 0 ]
  fresh
  plan 'core@150/0 power_cap=1 pstate_min=3'
  search
  search_ended "core 2 3 @150/0 pass" 150 0
  step_line core 150 0 'result=invalid reason=pstate'
  fresh
  plan 'core@150/0 power_cap=2 fail'
  search
  status_is 0
  step_line core 150 0 'result=fail reason=errors'
  [ "$(core_steps)" = "90 120 150" ]
}

@test "search: own: #150: the lines of the two baseline loads carry no field, capped or not, and the power_cap of a memory load changes nothing" {
  plan 'core@0/0 power_cap=1' 'mem@* power_cap=1'
  search
  all_passed
  step_line baseline-core 0 0 'result=pass reason=ok'
  step_line baseline-mem 0 0 'result=pass reason=ok'
  grep -Fxq 'core_power_cap=1' "$STATE/baseline"
  [ "$(grep -c ' phase=\(mem\|soak-mem\|baseline-mem\) .*clock=' "$STATE/log")" -eq 0 ]
  # every memory load capped and no core load: no step is unchecked, no power limit line
  fresh
  plan 'mem@* power_cap=1'
  search
  all_passed
  grep -Fxq 'core_power_cap=0' "$STATE/baseline"
  [ "$(grep -c 'clock=unchecked' "$STATE/log")" -eq 0 ]
  step_line soak-mem 210 1300 'result=pass reason=ok core_clock_delta=210'
  [ "$(grep -Fc "$MSG_UNCHECKED" <<<"$output")" -eq 0 ]
  [ "$(printf '%s\n' core_mhz_max=2535 mem_mhz_max=9000 read_gbs=400.0 core_power_cap=0 mem_core_mhz_max=2535)" = "$(<"$STATE/baseline")" ]
}

@test "search: own: #150: the old baseline is refused where the baseline is read: after the load check, with one line on stderr, the file left as it is and zero run; a start that finds a result prints it" {
  local before
  old_baseline
  before="$(<"$STATE/baseline")"
  search
  status_is 1
  said_line "pc-oc: gpu: search: /var/lib/pc-oc/gpu/search/baseline has no core_power_cap line, so a gpu/search.sh before #150 wrote it: nothing was set. Start the search over: sudo rm -r /var/lib/pc-oc/gpu/search"
  [ "$(grep -v '^mock ' <<<"$stderr" | grep -c .)" -eq 1 ]
  [ -z "$output" ]
  [ "$(calls load)" = check ]
  no_set
  ends_at_zero
  [ "$(<"$STATE/baseline")" = "$before" ]
  [ ! -e "$STATE/log" ]
  # a search that the script before #150 finished: its result is not judged again
  fresh
  old_baseline
  printf '%s\n' core_offset_mhz=210 mem_offset_mhz=1300 finished=2026-09-30T10:00:00Z >"$STATE/result"
  search
  status_is 0
  no_set
  no_load
  [[ "$output" == *"core_offset_mhz=210"* && "$output" == *"nothing was run"* ]]
  [ -z "$(end_lines <<<"$output")" ]
}

@test "search: own: #150: a baseline file with core_power_cap that lacks mem_core_mhz_max, or whose core_power_cap is not 0 or 1, does not parse: exit 1, nothing set, no load" {
  local lines
  for lines in 'core_power_cap=0' 'core_power_cap=2 mem_core_mhz_max=2535' \
    'core_power_cap= mem_core_mhz_max=2535' 'core_power_cap=1 mem_core_mhz_max=0' \
    'core_power_cap=1 mem_core_mhz_max=2535x'; do
    fresh
    old_baseline
    # shellcheck disable=SC2086 # one line per word
    printf '%s\n' $lines >>"$STATE/baseline"
    search
    refused
    said_line "pc-oc: gpu: search: /var/lib/pc-oc/gpu/search/baseline does not parse: remove /var/lib/pc-oc/gpu/search to start the search over"
  done
  # and the five lines the search writes are taken
  fresh
  old_baseline
  printf '%s\n' core_power_cap=1 mem_core_mhz_max=2500 >>"$STATE/baseline"
  search
  status_is 0
  [ -z "$(baseline_loads)" ]
  step_line core 90 0 'result=pass reason=ok clock=unchecked'
  step_line soak-mem 210 1300 'result=pass reason=ok core_clock_delta=245'
}

@test "search: own: #150: the log is what remembers: a start that finds the result prints the end lines again, and without the lines of the log it prints the result alone" {
  local first
  plan 'core@120/0 power_cap=1 core_mhz_max=2300' 'mem@210/1300 core_mhz_max=2700'
  search
  all_passed
  first="$(end_lines <<<"$output")"
  [ "$(wc -l <<<"$first")" -eq 2 ]
  next_start
  search
  status_is 0
  no_load
  [ "$(end_lines <<<"$output")" = "$first" ]
  [ "$(line_at "$MSG_UNCHECKED")" -lt "$(line_at core_offset_mhz=210)" ]
  # the field of an unchecked step taken out of the log: only the moved line is left
  sed -i 's/ clock=unchecked$//' "$STATE/log"
  search
  status_is 0
  [ "$(end_lines <<<"$output")" = "$(tail -n 1 <<<"$first")" ]
  # a memory step is no soak, and a line that only looks like the field does not count
  printf '%s\n' '2026-09-30T10:00:00Z phase=mem core=0 mem=300 result=pass reason=ok clock=unchecked' \
    '2026-09-30T10:00:01Z phase=soak-mem core=210 mem=1300 result=pass reason=ok core_clock_delta=12x' \
    >"$STATE/log"
  search
  status_is 0
  [ -z "$(end_lines <<<"$output")" ]
  # no log at all: the result is printed, exit 0
  rm "$STATE/log"
  search
  status_is 0
  [ -z "$(end_lines <<<"$output")" ]
  [[ "$output" == *"core_offset_mhz=210"* && "$output" == *"nothing was run"* ]]
}

@test "search: own: #150: a memory block whose core_mhz_max is no number is no pass: the step is invalid, reason block; at the baseline nothing is set" {
  local value
  for value in abc '' 0 123456 -5; do
    fresh
    plan "mem@0/300 core_mhz_max=$value"
    search
    search_ended "mem 4 6 1 @0/300 pass" 0 300
    step_line mem 0 300 'result=invalid reason=block'
  done
  fresh
  plan 'mem@210/1300 core_mhz_max=abc'
  search
  search_ended "mem 4 7 1 @210/1300 pass" 210 1300
  step_line soak-mem 210 1300 'result=invalid reason=block'
  fresh
  plan 'mem@0/0 core_mhz_max='
  search
  status_is 1
  logged 0 0 invalid block
  no_set
  no_result
  [ ! -e "$STATE/baseline" ]
}

@test "search: own: #150: the power limit line with nobody to read it ends nothing early: the result is written, zero ran, exit 1" {
  plan 'core@120/0 power_cap=1 core_mhz_max=2300'
  # head leaves after the lines of all 24 steps, ahead of the power limit line
  run --separate-stderr piped head -n 24
  ends_at_zero
  status_is 1
  [ "$(wc -l <"$STATE/log")" -eq 24 ]
  [ "$(grep -c ' clock=unchecked$' "$STATE/log")" -eq 1 ]
  result_is 210 1300
  said 'could not be printed'
  # a reader that takes the power limit line and leaves ahead of the moved line
  next_start
  run --separate-stderr piped head -n 1
  [ "$output" = "pc-oc: $MSG_UNCHECKED" ]
  ends_at_zero
  status_is 1
  no_set
  no_load
  said 'could not be printed'
}
