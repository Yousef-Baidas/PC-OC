# shellcheck shell=bash disable=SC2034,SC2154 # status, output and stderr are set by bats
# run; the constants below are read by tests/gpu/search.bats
# Shared helpers for the #135 and #150 contracts: tests/gpu/search.bats.

# The calling user of the fixture passwd, and the two boot ids guard.sh can bind.
CALLER_UID=4242
CALLER_GID=4343
CALLER_HOME=/home/pc-oc-caller
BOOT_A=0a0a0a0a-0000-4000-8000-00000000000a
BOOT_B=0b0b0b0b-0000-4000-8000-00000000000b

# The two messages the ticket gives word for word besides "already running".
MSG_OFFSETS="pc-oc: gpu: search: offsets are set by something else: run sudo pc-oc revert gpu"
MSG_POWER="pc-oc: gpu: search: apply the power limit first: sudo pc-oc apply gpu"

# The one switch of the #150 contract. 1: the mock load prints the power_cap line of #150
# in every block, on the line after limited. 0 keeps the block of #134, the only one
# gpu/search.sh reads until #150 is built; the cases of #150 turn it on for themselves
# (power_cap_blocks). The worker of #150 sets this default to 1 and changes nothing else
# in these fixtures.
BLOCK_POWER_CAP=1

# The line of #150 that a search ending with a result prints when a core step or core soak
# of it was not checked against its clock. The ticket gives it from "gpu:" on; the other
# messages of the script start "pc-oc: ", so line_at takes it with or without that.
MSG_UNCHECKED="gpu: search: the core load ran at the power limit, so the core clock was not checked against the offset"

# common_setup: the fake tree (lib/, gpu/pl.sh, gpu/values and the script under test from
# the repo; the tiny gpu/search.values, the mock gpu/load.sh and a gpu/nvml.py that is never
# run from the fixtures), the scratch that guard.sh binds over /var/lib, and the mocks it
# binds over /usr/bin. STATE is the search's state directory and MOCK the mocks' records,
# both seen from outside the namespace.
common_setup() {
  unset "${!GIT_@}"
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  FIX="$BATS_TEST_DIRNAME/fixtures/search"
  REPO="$BATS_TEST_TMPDIR/repo"
  VARLIB="$BATS_TEST_TMPDIR/varlib"
  MOCK="$VARLIB/pc-oc-test-mock"
  STATE="$VARLIB/pc-oc/gpu/search"
  export GUARD_MOCKS="$BATS_TEST_TMPDIR/bin"
  export GUARD_VARLIB="$VARLIB"
  export GUARD_PASSWD="$FIX/passwd"
  export GUARD_BOOT_ID="$BATS_TEST_TMPDIR/boot_id"
  mkdir -p "$REPO/gpu" "$GUARD_MOCKS"
  cp -r "$ROOT/lib" "$REPO/lib"
  cp "$ROOT/gpu/pl.sh" "$ROOT/gpu/values" "$REPO/gpu/"
  # absent until #135 lands: every case is red then, setup is not
  cp "$ROOT/gpu/search.sh" "$REPO/gpu/" 2>/dev/null || true
  cp "$FIX/search.values" "$REPO/gpu/search.values"
  cp "$FIX/load.sh" "$REPO/gpu/load.sh"
  # the helper is mocks/python3; the file only has to be there for the script to name it
  echo 'raise SystemExit("fake tree: python3 is a mock here, this file is never run")' \
    >"$REPO/gpu/nvml.py"
  cp "$FIX"/mocks/* "$GUARD_MOCKS/"
  fresh
}

# fresh: empty state directory, empty mock records, no plan, offsets 0, boot id A, and a
# power limit that reads back as pl_w of gpu/values. Run by setup, and between two
# variants of one case.
fresh() {
  local pl_w
  rm -rf "$VARLIB"
  mkdir -p "$MOCK"
  : >"$MOCK/scratch"
  printf '%s\n' "$BOOT_A" >"$GUARD_BOOT_ID"
  pl_w="$(sed -n 's/^pl_w=\([0-9][0-9]*\).*/\1/p' "$REPO/gpu/values")"
  printf '%s.00\n' "$pl_w" >"$MOCK/smi.limit"
  cp "$FIX/search.values" "$REPO/gpu/search.values"
  # the mock load runs under env -i: a file is all of the switch that reaches it
  ((BLOCK_POWER_CAP == 0)) || : >"$MOCK/block.power_cap"
}

# power_cap_blocks: a fresh state in which every block of the mock load has the power_cap
# line of #150 (power_cap=0 unless the plan says otherwise), whatever the default of
# BLOCK_POWER_CAP is. For the rest of the test, so a later fresh keeps it.
power_cap_blocks() {
  BLOCK_POWER_CAP=1
  fresh
}

# old_baseline: the state directory with the baseline file a search before #150 wrote:
# the three lines of #135, no core_power_cap and no mem_core_mhz_max
old_baseline() {
  mkdir -p "$STATE"
  printf '%s\n' core_mhz_max=2535 mem_mhz_max=9000 read_gbs=400.0 >"$STATE/baseline"
}

# next_start: put the records of the starts so far aside, so the helpers below see only
# the next one. The state directory, the offsets and the plan stay.
next_start() {
  local f
  mkdir -p "$MOCK/earlier"
  for f in events nvml.calls load.calls load.detail load.env setpriv.pids python3.argv; do
    [[ ! -e "$MOCK/$f" ]] || mv "$MOCK/$f" "$MOCK/earlier/$f"
  done
}

# lock_free: wait, 3 s at most, until nothing holds the lock on the state directory. A
# load that outlives a signalled search keeps the descriptor it inherited until it ends;
# that none may outlive it is case 17's business, not that of the case that waits here.
lock_free() {
  local n
  for n in {1..30}; do
    if flock -n "$STATE" true 2>/dev/null; then return 0; fi
    sleep 0.1
  done
  echo "the state directory is still locked 3 s after the search ended" >&2
  return 1
}

# in_ns <user|root> <command...>: run the command in a private mount namespace behind
# guard.sh. "root" is unshare -r, where /usr/bin/id -u prints 0; "user" keeps the caller's
# uid. INT, TERM and HUP are set back to their default action first: a signal that is
# ignored when a shell starts cannot be trapped by it, and a test run may be started that
# way. timeout only bounds a search that hangs.
in_ns() {
  local who="$1"
  shift
  local -a map=(--map-user="$(id -u)" --map-group="$(id -g)" --keep-caps)
  [[ "$who" == user ]] || map=(-r)
  GUARD_AS="$who" timeout -k 5 60 env --default-signal=INT,TERM,HUP \
    unshare "${map[@]}" -m bash "$FIX/guard.sh" "$@"
}

# start_as <user|root> [NAME=value...]: one start of gpu/search.sh whose whole environment
# is PATH=/usr/bin, as pc-oc pins it, plus the variables given
start_as() {
  local who="$1"
  shift
  run --separate-stderr in_ns "$who" /usr/bin/env -i PATH=/usr/bin "$@" \
    /usr/bin/bash "$REPO/gpu/search.sh"
}

# search [NAME=value...]: a start as uid 0 for the fixture's calling user, the way
# "sudo pc-oc search gpu" leaves it
search() {
  start_as root "SUDO_UID=$CALLER_UID" "SUDO_GID=$CALLER_GID" "$@"
}

# search_both: the same start with stderr in stdout, so output holds the lines of both in
# the order they were written
search_both() {
  run in_ns root /usr/bin/env -i PATH=/usr/bin "SUDO_UID=$CALLER_UID" "SUDO_GID=$CALLER_GID" \
    /usr/bin/bash "$REPO/gpu/search.sh"
  stderr=""
}

# line_at <text>: the number of the output line of the last run that is this text, alone
# or behind "pc-oc: "; fails unless exactly one line is
line_at() {
  local at
  at="$(grep -n -Fx -e "$1" -e "pc-oc: $1" <<<"$output" | cut -d: -f1)"
  [[ "$at" =~ ^[0-9]+$ ]] || {
    printf 'not exactly one line "%s" (lines: %s):\n%s\n' "$1" "${at:-none}" "$output" >&2
    return 1
  }
  printf '%s\n' "$at"
}

# plan <line>...: lines for the mock load's plan (fixtures/search/load.sh)
plan() {
  printf '%s\n' "$@" >>"$MOCK/load.plan"
}

# helper_fails <nth|all> <exit code> <command prefix>: a line for the fake helper's plan
helper_fails() {
  printf '%s\n' "$*" >>"$MOCK/nvml.fail"
}

# values_with <sed script>: gpu/search.values of the fake tree, changed by the script
values_with() {
  sed -E "$1" "$FIX/search.values" >"$REPO/gpu/search.values"
}

# status_is <n>: the last run exited <n>; on a mismatch show what it printed
status_is() {
  [[ "$status" -eq "$1" ]] || {
    printf 'status %s, want %s\nstdout:\n%s\nstderr:\n%s\n' "$status" "$1" "$output" "$stderr" >&2
    return 1
  }
}

# said <regex>: a stderr line of the last run matches, in any letter case. The mocks'
# own lines ("mock <name>: ...") pass through the search and do not count.
said() {
  grep -v '^mock ' <<<"$stderr" | grep -Eiq -- "$1" || {
    printf 'stderr does not match %s:\n%s\n' "$1" "$stderr" >&2
    return 1
  }
}

# said_line <text>: stderr of the last run has exactly this line
said_line() {
  grep -Fxq -- "$1" <<<"$stderr" || {
    printf 'stderr has no line "%s":\n%s\n' "$1" "$stderr" >&2
    return 1
  }
}

# calls <tool>: the calls a mock recorded, in order, without the tool's name; tool is one
# of nvml, load, setpriv, getent, nvidia-smi, systemctl, sleep, sudo, python3
calls() {
  [[ -e "$MOCK/events" ]] || return 0
  sed -n "s/^$1 //p" "$MOCK/events"
}

# loads: the core and mem loads of this start, "<arguments> @<core>/<mem> <result>"
loads() {
  [[ -e "$MOCK/load.calls" ]] || return 0
  grep -Ev '^check ' "$MOCK/load.calls" || true
}

# The load arguments below are the seconds and the device index of fixtures/search/
# search.values: a step is "core 2 3" or "mem 4 6 1", a soak load lasts 5 (core) or 7 (mem).

# baseline_loads: the loads that ran at offsets 0/0, sorted, on one line
baseline_loads() {
  loads | sed -En 's|^(.*) @0/0 [a-z]+$|\1|p' | sort | paste -sd' '
}

# core_steps, mem_steps: the offsets the phase stepped through, in order, on one line
core_steps() {
  loads | sed -En 's|^core 2 3 @([1-9][0-9]*)/0 [a-z]+$|\1|p' | paste -sd' '
}
mem_steps() {
  loads | sed -En 's|^mem 4 6 1 @0/([1-9][0-9]*) [a-z]+$|\1|p' | paste -sd' '
}

# soaks <core|mem>: the soak loads of that kind, "<core>/<mem>:<result>", on one line
soaks() {
  local shape='core [0-9]+ 5'
  [[ "$1" == core ]] || shape='mem [0-9]+ 7 1'
  loads | sed -En "s|^$shape @([0-9]+/[0-9]+) ([a-z]+)\$|\\1:\\2|p" | paste -sd' '
}

# phases: what the loads of this start were, in order, repeats squeezed, on one line
phases() {
  loads | sed -E \
    -e 's|^.* @0/0 [a-z]+$|baseline|' \
    -e 's|^core 2 3 @[1-9][0-9]*/0 [a-z]+$|core|' \
    -e 's|^mem 4 6 1 @0/[1-9][0-9]* [a-z]+$|mem|' \
    -e 's|^core [0-9]+ 5 @.*$|soak-core|' \
    -e 's|^mem [0-9]+ 7 1 @.*$|soak-mem|' | uniq | paste -sd' '
}

# last_load <line>: the last load of this start is this line of load.calls, so nothing
# was loaded after it
last_load() {
  [[ "$(loads | tail -n 1)" == "$1" ]] || {
    printf 'last load: %s\nwant: %s\n' "$(loads | tail -n 1)" "$1" >&2
    return 1
  }
}

# no_set, no_load: the fake helper got no set, the mock load ran no core or mem load
no_set() {
  [[ -z "$(calls nvml | grep '^set' || true)" ]] || {
    printf 'set calls:\n%s\n' "$(calls nvml | grep '^set')" >&2
    return 1
  }
}
no_load() {
  [[ -z "$(loads)" ]] || {
    printf 'loads:\n%s\n' "$(loads)" >&2
    return 1
  }
}

# helper_calls_ok: every python3 call of this start was "-I <gpu/nvml.py of the fake
# tree> <command>", and there was at least one
helper_calls_ok() {
  local flag path _
  [[ -s "$MOCK/python3.argv" ]] || return 1
  while read -r flag path _; do
    [[ "$flag" == -I && "$(realpath -- "$path")" == "$(realpath -- "$REPO/gpu/nvml.py")" ]] || {
      printf 'python3 was called with: %s %s\n' "$flag" "$path" >&2
      return 1
    }
  done <"$MOCK/python3.argv"
}

# offsets: what the fake helper holds now, "<core>/<mem>"
offsets() {
  local core=0 mem=0
  [[ ! -e "$MOCK/nvml.core" ]] || core="$(<"$MOCK/nvml.core")"
  [[ ! -e "$MOCK/nvml.mem" ]] || mem="$(<"$MOCK/nvml.mem")"
  printf '%s/%s\n' "$core" "$mem"
}

# ends_at_zero: the last thing this start did with the helper or a load was "nvml.py
# zero", it exited 0, and both offsets are 0. So every set of this start has a zero after it.
ends_at_zero() {
  local last
  last="$(grep -E '^(nvml|load|setpriv) ' "$MOCK/events" | tail -n 1)"
  [[ "$last" == "nvml zero" ]] || {
    printf 'last helper or load call: %s\nhelper calls:\n%s\n' "$last" "$(calls nvml)" >&2
    return 1
  }
  [[ "$(tail -n 1 "$MOCK/nvml.calls")" == "zero rc=0 |"* ]] || {
    printf 'the last zero: %s\n' "$(tail -n 1 "$MOCK/nvml.calls")" >&2
    return 1
  }
  [[ "$(offsets)" == 0/0 ]] || {
    printf 'offsets at the end: %s\n' "$(offsets)" >&2
    return 1
  }
}

# zero_follows <set command>: the first call that fake helper got after this set is zero,
# and no load or setpriv ran in between
zero_follows() {
  local after
  after="$(grep -E '^(nvml|load|setpriv) ' "$MOCK/events" | grep -A1 -m1 -Fx "nvml $1" | tail -n 1)"
  [[ "$after" == "nvml zero" ]] || {
    printf 'after "%s" came: %s\nhelper calls:\n%s\n' "$1" "$after" "$(calls nvml)" >&2
    return 1
  }
}

# sets_had_pending: every set of this start found the pending file, and the file named
# the offset being set (core=<n> for set core <n>, mem=<m> for set mem <m>)
sets_had_pending() {
  local line command pending clock mhz
  while IFS= read -r line; do
    command="${line%% rc=*}"
    pending=" ${line#* | } "
    read -r _ clock mhz <<<"$command"
    [[ "$pending" == *[[:space:]]"$clock=$mhz"[[:space:]]* ]] || {
      printf 'at "%s" pending was: %s\n' "$command" "${line#* | }" >&2
      return 1
    }
  done < <(grep '^set ' "$MOCK/nvml.calls")
}

# result_is <core> <mem>: the result file holds these two offsets and a finished= line,
# and nothing else
result_is() {
  local f="$STATE/result"
  [[ -e "$f" ]] || {
    printf 'no result file\nstdout:\n%s\nstderr:\n%s\n' "$output" "$stderr" >&2
    return 1
  }
  if ! grep -qx "core_offset_mhz=$1" "$f" || ! grep -qx "mem_offset_mhz=$2" "$f" ||
    ! grep -Eqx 'finished=[0-9][^[:space:]]*' "$f" || [[ "$(wc -l <"$f")" -ne 3 ]]; then
    printf 'result, want core %s and mem %s:\n%s\n' "$1" "$2" "$(<"$f")" >&2
    return 1
  fi
}

# soaked <core|mem> <mhz>: a soak load of that kind passed with that offset set
soaked() {
  local entry
  for entry in $(soaks "$1"); do
    case "$1" in
      core) [[ "$entry" != "$2/"*":pass" ]] || return 0 ;;
      *) [[ "$entry" != *"/$2:pass" ]] || return 0 ;;
    esac
  done
  return 1
}

# result_soaked: a clock's value in the result file is 0, or a soak load of that clock
# passed with that value set
result_soaked() {
  local clock mhz
  for clock in core mem; do
    mhz="$(sed -n "s/^${clock}_offset_mhz=//p" "$STATE/result")"
    [[ "$mhz" == 0 ]] || soaked "$clock" "$mhz" || {
      printf '%s %s is in the result; the %s soak loads were: %s\n' \
        "$clock" "$mhz" "$clock" "$(soaks "$clock")" >&2
      return 1
    }
  done
}

# no_result: no result file
no_result() {
  [[ ! -e "$STATE/result" ]] || {
    printf 'result exists:\n%s\n' "$(<"$STATE/result")" >&2
    return 1
  }
}

# The one field #150 lets a step's line end with, behind reason=: clock=unchecked on a
# core step or core soak, core_clock_delta=<n> on a memory load at a core offset.
FIELD_150='( clock=unchecked| core_clock_delta=-?[0-9]+)?'

# logged <core> <mem> <result regex> [reason regex]: the log has a line for that step,
# in the ticket's format "<utc> phase=... core=... mem=... result=... reason=...", with
# or without the field of #150 at its end (step_line is the helper that pins that field)
logged() {
  grep -Eq "^[^ ]+ phase=[^ ]+ core=$1 mem=$2 result=($3) reason=(${4:-[^ ]+})$FIELD_150\$" "$STATE/log" || {
    printf 'no log line core=%s mem=%s result=(%s) reason=(%s):\n%s\n' \
      "$1" "$2" "$3" "${4:-any}" "$(cat "$STATE/log" 2>&1)" >&2
    return 1
  }
}

# not_passed <core> <mem>: the log has no result=pass line for that step
not_passed() {
  if grep -Eq "^[^ ]+ phase=[^ ]+ core=$1 mem=$2 result=pass " "$STATE/log" 2>/dev/null; then
    printf 'the step core=%s mem=%s is logged as passed:\n%s\n' "$1" "$2" "$(<"$STATE/log")" >&2
    return 1
  fi
}

# step_line <phase> <core> <mem> <rest>: the line of that step is "phase=<phase>
# core=<core> mem=<mem> <rest>" to the last character, once on stdout of the last run and
# once, behind its time, in the log
step_line() {
  local line="phase=$1 core=$2 mem=$3 $4"
  if [[ "$(grep -c -Fx -- "$line" <<<"$output")" -ne 1 ]] ||
    [[ "$(cut -d' ' -f2- "$STATE/log" | grep -c -Fx -- "$line")" -ne 1 ]]; then
    printf 'not once on stdout and once in the log: %s\nstdout:\n%s\nlog:\n%s\n' \
      "$line" "$output" "$(cat "$STATE/log" 2>&1)" >&2
    return 1
  fi
}

# log_ok: every line of the log is in the ticket's format
log_ok() {
  local bad
  local format="^[^ ]+ phase=[^ ]+ core=[0-9]+ mem=[0-9]+ result=[a-z]+ reason=[^ ]+$FIELD_150\$"
  bad="$(grep -Ev "$format" "$STATE/log" || true)"
  [[ -s "$STATE/log" && -z "$bad" ]] || {
    printf 'log lines not in the format:\n%s\n' "$bad" >&2
    return 1
  }
}

# refused: the start ended with exit 1 before it wrote anything: no set, no core or mem
# load, no result
refused() {
  status_is 1 && no_set && no_load && no_result
}

# search_ended <last load> <core> <mem>: the whole search ended at this step, the way the
# ticket ends it on invalid: exit 1, that load was the last one, the step is in the log
# and did not pass, zero ran last, no result, and stderr says to run the command again
search_ended() {
  status_is 1 && last_load "$1" && logged "$2" "$3" 'fail|invalid' && ends_at_zero &&
    no_result && said 'search gpu'
}

# all_passed: the run of the ticket's case 1, as far as loads and result go
all_passed() {
  status_is 0 || return 1
  if [[ "$(phases)" != "baseline core mem soak-core soak-mem" ]] ||
    [[ "$(core_steps)" != "90 120 150 180 210 240" ]] ||
    [[ "$(mem_steps)" != "200 300 400 500 600 700 800 900 1000 1100 1200 1300 1400 1500" ]]; then
    printf 'phases: %s\ncore steps: %s\nmem steps: %s\nstderr:\n%s\n' \
      "$(phases)" "$(core_steps)" "$(mem_steps)" "$stderr" >&2
    return 1
  fi
  result_is 210 1300
}

# load_env: the environment the loads of this start saw, without what bash itself sets
# in a script started under env -i; sorted, repeats dropped, on one line
load_env() {
  grep -Ev '^(-- |PWD=|OLDPWD=|SHLVL=|_=)' "$MOCK/load.env" | sort -u | paste -sd' '
}

# mock_paths: the PATH values the mocks bound over /usr/bin saw, sorted, on one line
mock_paths() {
  cat "$MOCK"/python3.env "$MOCK"/setpriv.env "$MOCK"/getent.env "$MOCK"/nvidia-smi.env |
    grep '^PATH=' | sort -u | paste -sd' '
}
