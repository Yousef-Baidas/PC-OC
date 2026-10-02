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
# soak (5 and 7 seconds) and a whole search takes about a second.

load fixtures/search/helper

setup() {
  common_setup
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

# shouted: stderr names "sudo reboot" and says something in capitals
shouted() {
  if ! grep -Fq 'sudo reboot' <<<"$stderr" || ! grep -Eq '[A-Z]{2,} [A-Z]{2,}' <<<"$stderr"; then
    printf 'no capital-letter message with sudo reboot:\n%s\n' "$stderr" >&2
    return 1
  fi
}

@test "search: every load passing, one baseline, then core steps 90 to 240, then memory steps 200 to 1500, then one soak, and nothing else (#135 case 1)" {
  skip "contract #135 pending"
  search
  all_passed
  [ "$(baseline_loads)" = "core 2 3 mem 4 6 1" ]
  [ "$(soaks core)" = "210/1300:pass" ]
  [ "$(soaks mem)" = "210/1300:pass" ]
  [ "$(loads | wc -l)" -eq 24 ]
}

@test "search: every load passing, result holds core 210 and memory 1300, both soaked, and stdout gives both and says they are not applied (#135 case 1)" {
  skip "contract #135 pending"
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
  skip "contract #135 pending"
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
  skip "contract #135 pending"
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
  skip "contract #135 pending"
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
  skip "contract #135 pending"
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
  skip "contract #135 pending"
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
  skip "contract #135 pending"
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
  skip "contract #135 pending"
  values_with 's/^core_margin_mhz=30/core_margin_mhz=200/'
  plan 'core@150/0 fail'
  search
  status_is 0
  result_is 0 1300
}

@test "search: memory read_gbs 4 percent under the baseline at 600 is reason=throughput and stores memory 300 (#135 case 4)" {
  skip "contract #135 pending"
  plan 'mem@0/600 read_gbs=384.0'
  search
  status_is 0
  [ "$(mem_steps)" = "200 300 400 500 600" ]
  logged 0 600 fail throughput
  [ "$(soaks mem)" = "210/300:pass" ]
  result_is 210 300
}

@test "search: memory read_gbs 2.9 percent under the baseline, and exactly mem_drop_pct under it, still pass (#135 case 4)" {
  skip "contract #135 pending"
  plan 'mem@0/600 read_gbs=388.4' 'mem@0/700 read_gbs=388.0'
  search
  all_passed
  logged 0 600 pass
  logged 0 700 pass
}

@test "search: the load saying invalid at a step ends the search: zero, exit 1, the step logged as failed, no result, and the message says to run it again (#135 case 5)" {
  skip "contract #135 pending"
  plan 'mem@0/600 invalid'
  search
  search_ended "mem 4 6 1 @0/600 invalid" 0 600
  said reboot
  [ "$(mem_steps)" = "200 300 400 500 600" ]
}

@test "search: the start after an invalid step repeats neither that step nor the baseline nor the core phase, and ends with core 210 and memory 300 (#135 case 5)" {
  skip "contract #135 pending"
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
  skip "contract #135 pending"
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
  skip "contract #135 pending"
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
  skip "contract #135 pending"
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
  skip "contract #135 pending"
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
  skip "contract #135 pending"
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
  skip "contract #135 pending"
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
  skip "contract #135 pending"
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
  skip "contract #135 pending"
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
  skip "contract #135 pending"
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
  skip "contract #135 pending"
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
  skip "contract #135 pending"
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
  skip "contract #135 pending"
  helper_fails 1 1 set
  helper_fails all 1 zero
  search
  [ "$status" -ne 0 ]
  [ "$(calls nvml | tail -n 1)" = zero ]
  shouted
  no_result
}

@test "search: zero failing at the end of a search whose loads all passed is said in capitals too (#135 case 8)" {
  skip "contract #135 pending"
  helper_fails all 1 zero
  search
  [ "$(calls nvml | tail -n 1)" = zero ]
  shouted
}

@test "search: not root is refused: exit 1, no helper call, no load (#135 case 9)" {
  skip "contract #135 pending"
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
  skip "contract #135 pending"
  start_as root "SUDO_GID=$CALLER_GID"
  refused
  for uid in 0 12x; do
    start_as root "SUDO_UID=$uid" "SUDO_GID=$CALLER_GID"
    refused
  done
}

@test "search: a power limit that does not read back as pl_w is refused with the apply message (#135 case 9)" {
  skip "contract #135 pending"
  echo 150.00 >"$MOCK/smi.limit"
  search
  refused
  said_line "$MSG_POWER"
  [ "$(calls nvidia-smi)" = "--query-gpu=power.limit --format=csv,noheader,nounits" ]
}

@test "search: a non-zero offset without a pending file is refused with the revert message, on any pstate and clock (#135 case 9)" {
  skip "contract #135 pending"
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
  skip "contract #135 pending"
  helper_fails 1 1 get
  search
  refused
  said '^pc-oc: gpu: '
}

@test "search: load.sh check exiting 3 is refused and its line is shown, whichever stream it came on (#135 case 9)" {
  skip "contract #135 pending"
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
  skip "contract #135 pending"
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
  skip "contract #135 pending"
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
  skip "contract #135 pending"
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
  skip "contract #135 pending"
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

@test "search: search.values with every bound reached is accepted: one core step at 300 and one memory step at 2000, margins of 15 (#135 case 9)" {
  skip "contract #135 pending"
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
  skip "contract #135 pending"
  for content in "" "pl_w=abc  # src: smi" "pl_w=0216  # src: smi"; do
    printf '%s\n' "$content" >"$REPO/gpu/values"
    search
    refused
  done
}

@test "search: a core soak that fails once and then passes stores core one step lower (#135 case 10)" {
  skip "contract #135 pending"
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
  skip "contract #135 pending"
  plan 'core@210/1300 fail' 'core@180/1300 fail' 'core@150/1300 fail'
  search
  status_is 0
  [ "$(soaks core)" = "210/1300:fail 180/1300:fail 150/1300:fail 120/1300:pass" ]
  result_is 120 1300
  result_soaked
}

@test "search: a core soak that fails soak_backoffs + 1 times stores core 0 (#135 case 10)" {
  skip "contract #135 pending"
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
  skip "contract #135 pending"
  plan 'mem@210/1300 fail'
  search
  status_is 0
  [ "$(soaks mem)" = "210/1300:fail 210/1200:pass" ]
  result_is 210 1200
  result_soaked
  ends_at_zero
}

@test "search: a memory soak that fails soak_backoffs + 1 times stores memory 0 (#135 case 10)" {
  skip "contract #135 pending"
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
  skip "contract #135 pending"
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
  skip "contract #135 pending"
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
  skip "contract #135 pending"
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
  skip "contract #135 pending"
  signalled TERM
}

@test "search: SIGINT during a step ends the same way (#135 case 11)" {
  skip "contract #135 pending"
  signalled INT
}

@test "search: SIGHUP during a step ends the same way (#135 case 11)" {
  skip "contract #135 pending"
  signalled HUP
}

@test "search: every load, the check included, went through setpriv with the calling uid and gid and env -i, and none was started by uid 0 directly (#135 case 12)" {
  skip "contract #135 pending"
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
  skip "contract #135 pending"
  for action in junk 'log=/home/pc-oc-caller/a:b' 'dup=Xid=0' 'reason=ok!'; do
    fresh
    plan "core@120/0 $action"
    search
    search_ended "core 2 3 @120/0 pass" 120 0
  done
}

@test "search: a load stdout with a missing key makes the step invalid (#135 case 13)" {
  skip "contract #135 pending"
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
  skip "contract #135 pending"
  for line in result=pass result=fail xid=0 log=/home/pc-oc-caller/other; do
    fresh
    plan "core@120/0 dup=$line"
    search
    search_ended "core 2 3 @120/0 pass" 120 0
  done
}

@test "search: a load whose exit status and result key disagree makes the step invalid: pass with 1, 3 or 7, fail with 0 or 3 (#135 case 16)" {
  skip "contract #135 pending"
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
  skip "contract #135 pending"
  plan 'core@0/0 rc=1'
  search
  status_is 1
  no_set
  no_result
}

@test "search: a core step whose core_mhz_max is 16 below baseline + offset is invalid; 15 below passes (#135 case 14)" {
  skip "contract #135 pending"
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
  skip "contract #135 pending"
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
  skip "contract #135 pending"
  plan 'mem@0/700 mem_mhz_max=9706'
  search
  not_passed 0 700
  [[ ! " $(mem_steps) " =~ \ ([89]|1[0-5])00\  ]]
  [ ! -e "$STATE/result" ] || result_is 210 400
  ends_at_zero
}

@test "search: every SUDO_UID of the #117 list dies before the lock, the helper and any load, in LC_ALL=C (#135 amendment 1)" {
  skip "contract #135 pending"
  bad_uids C
  # positive control: the fixture's caller is let through in this locale
  search LC_ALL=C
  all_passed
}

@test "search: every SUDO_UID of the #117 list dies the same way in en_US.UTF-8 (#135 amendment 1)" {
  skip "contract #135 pending"
  locale -a | grep -qix 'en_US\.utf-\?8' || skip "no en_US.UTF-8 locale on this machine"
  bad_uids en_US.UTF-8
  search LC_ALL=en_US.UTF-8
  all_passed
}

@test "search: every such SUDO_GID dies before the lock, the helper and any load, in LC_ALL=C (#135 amendment 1)" {
  skip "contract #135 pending"
  bad_gids C
  search LC_ALL=C
  status_is 0
  [[ "$(calls setpriv | head -n 1)" == "--reuid=$CALLER_UID --regid=$CALLER_GID --init-groups "* ]]
}

@test "search: every such SUDO_GID dies the same way in en_US.UTF-8 (#135 amendment 1)" {
  skip "contract #135 pending"
  locale -a | grep -qix 'en_US\.utf-\?8' || skip "no en_US.UTF-8 locale on this machine"
  bad_gids en_US.UTF-8
  search LC_ALL=en_US.UTF-8
  status_is 0
  [[ "$(calls setpriv | head -n 1)" == "--reuid=$CALLER_UID --regid=$CALLER_GID --init-groups "* ]]
}

@test "search: a bad calling user is reported before the lock is looked at (#135 amendment 1)" {
  skip "contract #135 pending"
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
  skip "contract #135 pending"
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
  skip "contract #135 pending"
  [ "$(wc -l <"$ROOT/gpu/search.values")" -eq 17 ]
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

@test "search.values: the shipped file holds the ticket's seventeen numbers, once each (#135 interface)" {
  skip "contract #135 pending"
  for pair in core_start_mhz=90 core_step_mhz=30 core_max_mhz=240 core_margin_mhz=30 \
    core_warmup_s=30 core_load_s=120 core_soak_s=600 mem_start_mhz=200 mem_step_mhz=100 \
    mem_max_mhz=1500 mem_margin_mhz=200 mem_warmup_s=30 mem_load_s=90 mem_soak_s=360 \
    mem_drop_pct=3 mem_device_index=1 soak_backoffs=3; do
    [ "$(grep -c "^${pair%%=*}=" "$ROOT/gpu/search.values")" -eq 1 ]
    grep -Eq "^$pair([[:space:]]|\$)" "$ROOT/gpu/search.values"
  done
}

@test "offsets.md: names every command of the runbook, in the ticket's order, and the three of Amendment 1 (#135 case 15)" {
  skip "contract #135 pending"
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
