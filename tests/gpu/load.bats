#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

# Contract for gpu/load.sh (#134, cases 6 to 14 of the ticket's Check list). No case loads
# the GPU: gpu_burn, memtest_vulkan, nvidia-smi and journalctl are recording mocks, first
# on PATH and bound over /usr/bin/<name> in a private mount namespace
# (fixtures/load/guard.sh), so a load.sh that pins PATH or calls a tool by absolute path
# still cannot reach the real ones. The load mocks replay timed output, so a run takes its
# warm-up + load seconds: 1 + 1, or 1 + 2 where two samples after the warm-up are needed.
# The cases named "#140 case N" are the contract for #140, those named "#150 case N", at
# the end, the contract for #150 (cases 1 to 7 of its Check list): of the seven limit
# reasons only the four slowdowns void a load, and the block has the key power_cap on the
# line after limited.

load fixtures/load/helper

setup() {
  common_setup
  use_mocks curl make nvidia-smi journalctl memtest_vulkan
  # the other form of ${XDG_CACHE_HOME:-$HOME/.cache}; burn-build.bats sets the variable
  unset XDG_CACHE_HOME
  SHA="$(sha256sum "$FIX/gpu-burn-src/Makefile" | cut -d' ' -f1)"
  write_pin "$SHA"
  BUILD="$HOME/.cache/pc-oc/gpu-burn/$VERSION"
  mkdir -p "$BUILD"
  cp "$FIX/mocks/gpu_burn" "$BUILD/gpu_burn"
  : >"$BUILD/compare.fatbin"
  printf '%s\n' "$SHA" >"$BUILD/built"
  export GUARD_ICD="$BATS_TEST_TMPDIR/icd.d"
  mkdir -p "$GUARD_ICD"
  cp "$FIX/icd.d/nvidia_icd.json" "$GUARD_ICD/"
  : >"$GUARD_ICD/.pc-oc-test-mock"
  export MOCK_BURN_OUT="$FIX/core/pass.out"
  export MOCK_MEMTEST_OUT="$FIX/mem/pass.out"
  export MOCK_SMI_ROWS="$FIX/smi/steady.rows"
  export MOCK_JOURNAL_AFTER="$FIX/journal/quiet.txt"
}

# load_sh <args...>: gpu/load.sh as the caller's uid, inside the namespace
load_sh() {
  run --separate-stderr in_ns user "$REPO/gpu/load.sh" "$@"
}

# verdict <exit code> <result>: the run ended with this exit code and result= line, and
# stdout is a well-formed block
verdict() {
  status_is "$1"
  block_ok
  [[ "$(value result)" == "$2" ]] || {
    printf 'want result=%s\nstdout:\n%s\nstderr:\n%s\n' "$2" "$output" "$stderr" >&2
    return 1
  }
}

# smi_rows <warm-up reasons> <later reasons>: an nvidia-smi scenario with these reason
# bitmasks (bits in fixtures/load/mocks/nvidia-smi) during and after the warm-up
smi_rows() {
  export MOCK_SMI_ROWS="$BATS_TEST_TMPDIR/smi.rows"
  printf 'warm P0 2520 8001 131.40 52 %s\npost P0 2520 8001 131.40 58 %s\n' "$1" "$2" \
    >"$MOCK_SMI_ROWS"
}

# smi_scenario <row>...: an nvidia-smi scenario of these rows
smi_scenario() {
  export MOCK_SMI_ROWS="$BATS_TEST_TMPDIR/smi.rows"
  printf '%s\n' "$@" >"$MOCK_SMI_ROWS"
}

# key_order: the keys of the stdout block in the order printed, on one line
key_order() {
  local l
  for l in "${lines[@]}"; do printf '%s ' "${l%%=*}"; done
}

# after_limited: the stdout line that follows the limited= line
after_limited() {
  local i
  for i in "${!lines[@]}"; do
    [[ "${lines[i]}" != limited=* ]] || {
      printf '%s\n' "${lines[i + 1]-}"
      return 0
    }
  done
  return 1
}

# keys: the keys of the stdout block, sorted, on one line
keys() {
  local l
  for l in "${lines[@]}"; do printf '%s\n' "${l%%=*}"; done | sort | tr '\n' ' '
}

@test "load core: the pass fixture gives result=pass, exit 0, every line in the grammar, all keys (#134 case 6)" {
  load_sh core 1 1
  verdict 0 pass
  # the eight keys of #134 and power_cap (#150)
  block_ok 9
  [ "$(value reason)" = ok ]
  [ "$(value pstate_min)" = 0 ]
  [ "$(value core_mhz_max)" = 2520 ]
  [ "$(value mem_mhz_max)" = 8001 ]
  [ "$(value limited)" = 0 ]
  [ "$(value power_cap)" = 0 ]
  [ "$(value xid)" = 0 ]
  log="$(value log)"
  [[ "$log" == "$HOME/.cache/pc-oc/gpu-load/"?* ]]
  [ -d "$log" ]
}

@test "load core: a FAULTY summary gives fail (#134 case 7)" {
  MOCK_BURN_OUT="$FIX/core/faulty.out" load_sh core 1 1
  verdict 1 fail
}

@test "load core: a non-zero error count with an OK summary gives fail (#134 case 7)" {
  MOCK_BURN_OUT="$FIX/core/errors-ok.out" load_sh core 1 1
  verdict 1 fail
}

@test "load core: gpu_burn exiting 0 without a summary gives invalid (#134 case 7)" {
  MOCK_BURN_OUT="$FIX/core/no-summary.out" load_sh core 1 1
  verdict 3 invalid
}

@test "load core: gpu_burn outliving the timeout gives invalid, though it printed an OK summary (#134 case 7)" {
  # the mock timeout checks nothing; it cuts the ticket's warm-up + load + 60 s to 2 s
  cp /usr/bin/timeout "$BATS_TEST_TMPDIR/real-timeout"
  export MOCK_REAL_TIMEOUT="$BATS_TEST_TMPDIR/real-timeout"
  use_mocks timeout
  MOCK_BURN_OUT="$FIX/core/hang.out" load_sh core 1 1
  verdict 3 invalid
  [ "$(cat "$MOCK_STATE/timeout.duration")" = 62 ]
}

@test "load core: samples taken after warm-up + load, while gpu_burn waits out its shutdown, do not change the result (#134 case 11)" {
  MOCK_BURN_OUT="$FIX/core/slow-exit.out" MOCK_SMI_ROWS="$FIX/smi/limit-late.rows" load_sh core 1 1
  verdict 0 pass
  [ "$(value limited)" = 0 ]
  [ "$(value core_mhz_max)" = 2520 ]
}

@test "load mem: exit 65 with throughput lines gives pass and read_gbs is the median after the warm-up (#134 case 8)" {
  load_sh mem 1 2 1
  verdict 0 pass
  # the nine keys of #134 and power_cap (#150)
  block_ok 10
  [ "$(value reason)" = ok ]
  [ "$(value limited)" = 0 ]
  [ "$(value power_cap)" = 0 ]
  [ "$(value xid)" = 0 ]
  # 10.0 three times in the warm-up, then 50.0, 42.0, 40.0
  read_gbs="$(value read_gbs)"
  [[ "$read_gbs" =~ ^[0-9]+(\.[0-9]+)?$ ]]
  awk -v v="$read_gbs" 'BEGIN { exit !(v == 42) }'
}

@test "load mem: exit 67 gives fail (#134 case 9)" {
  MOCK_MEMTEST_EXIT=67 load_sh mem 1 1 1
  verdict 1 fail
}

@test "load mem: exit 69, 64, 0 and 124 each give invalid (#134 case 9)" {
  for code in 69 64 0 124; do
    echo "memtest_vulkan exit code $code"
    rm -f "$MOCK_STATE"/*
    MOCK_MEMTEST_EXIT="$code" load_sh mem 1 1 1
    verdict 3 invalid
  done
}

@test "load mem: ERROR_DEVICE_LOST in the output gives fail (#134 case 9)" {
  MOCK_MEMTEST_OUT="$FIX/mem/device-lost.out" load_sh mem 1 2 1
  verdict 1 fail
}

@test "load mem: no throughput line after the warm-up gives invalid (#134 case 9)" {
  MOCK_MEMTEST_OUT="$FIX/mem/warmup-only.out" load_sh mem 1 1 1
  verdict 3 invalid
}

@test "load: a new NVRM: Xid line after the cursor gives fail, reason=xid, though the tool passed; journalctl got its own cursor back (#134 case 10)" {
  MOCK_JOURNAL_AFTER="$FIX/journal/xid.txt" load_sh core 1 1
  verdict 1 fail
  [ "$(value reason)" = xid ]
  [ "$(value xid)" = 2 ]
  [ -s "$MOCK_STATE/journalctl.cursor" ]
  [ "$(cat "$MOCK_STATE/journalctl.after")" = "$(cat "$MOCK_STATE/journalctl.cursor")" ]
}

@test "load: journalctl failing to give a cursor gives invalid (#134 case 10)" {
  MOCK_JOURNAL_FAIL=cursor load_sh core 1 1
  verdict 3 invalid
}

@test "load: journalctl failing after the load gives invalid (#134 case 10)" {
  MOCK_JOURNAL_FAIL=after load_sh core 1 1
  verdict 3 invalid
}

@test "load: a limit reason after the warm-up gives invalid, reason=limited (#134 case 11)" {
  # hw_slowdown: since #150 the power cap of smi/limit-post.rows is no limit
  smi_rows 0x0 0x8
  load_sh core 1 1
  verdict 3 invalid
  [ "$(value reason)" = limited ]
  [ "$(value limited)" = 1 ]
}

@test "load: the same limit reason during the warm-up only still passes (#134 case 11)" {
  smi_rows 0x8 0x0
  load_sh core 1 1
  verdict 0 pass
  [ "$(value limited)" = 0 ]
}

@test "load: an nvidia-smi sample that fails gives invalid (#134 case 11)" {
  MOCK_SMI_ROWS="$FIX/smi/fail-post.rows" load_sh core 1 2
  verdict 3 invalid
}

@test "load: an nvidia-smi sample that cannot be parsed gives invalid (#134 case 11)" {
  MOCK_SMI_ROWS="$FIX/smi/unknown-post.rows" load_sh core 1 2
  verdict 3 invalid
}

@test "load: pstate_min, core_mhz_max and mem_mhz_max ignore the warm-up samples (#134 case 11)" {
  MOCK_SMI_ROWS="$FIX/smi/ramp.rows" load_sh core 1 2
  verdict 0 pass
  [ "$(value pstate_min)" = 2 ]
  [ "$(value core_mhz_max)" = 2520 ]
  [ "$(value mem_mhz_max)" = 5001 ]
}

@test "load mem: memtest_vulkan saw VK_DRIVER_FILES set to the NVIDIA ICD and the device index (#134 case 12)" {
  load_sh mem 1 1 3
  verdict 0 pass
  [ "$(cat "$MOCK_STATE/memtest_vulkan.env")" = "VK_DRIVER_FILES=/usr/share/vulkan/icd.d/nvidia_icd.json" ]
  [ "$(cat "$MOCK_STATE/memtest_vulkan.args")" = 3 ]
}

@test "load core: gpu_burn ran with its build directory as cwd, -m 80% and -stts 5 (#134 case 12)" {
  load_sh core 1 1
  verdict 0 pass
  [ "$(cat "$MOCK_STATE/gpu_burn.cwd")" = "$(cd "$BUILD" && pwd -P)" ]
  [ "$(cat "$MOCK_STATE/gpu_burn.args")" = $'-m\n80%\n-stts\n5\n2' ]
}

@test "load: uid 0 is refused before any tool runs (#134 case 13)" {
  for args in "check" "core 1 1" "mem 1 1 1"; do
    echo "load.sh $args"
    # shellcheck disable=SC2086 # one word per argument, on purpose
    run --separate-stderr in_ns root "$REPO/gpu/load.sh" $args
    status_is 1
    [ -z "$output" ]
    [[ "$stderr" == "pc-oc: gpu: load: "*root* ]]
    no_tool_ran
  done
}

@test "load core: a missing build gives invalid and gpu_burn is not started (#134 case 13)" {
  mv "$BUILD" "$BATS_TEST_TMPDIR/build-elsewhere"
  load_sh core 1 1
  verdict 3 invalid
  [ ! -e "$MOCK_STATE/gpu_burn.args" ]
}

@test "load core: a stamp that is not the pin's sha256 gives invalid and gpu_burn is not started (#134 case 13)" {
  sha256sum "$FIX/gpu-burn-src/compare.cu" | cut -d' ' -f1 >"$BUILD/built"
  load_sh core 1 1
  verdict 3 invalid
  [ ! -e "$MOCK_STATE/gpu_burn.args" ]
}

@test "load check: exit 0 when the build, memtest_vulkan and the ICD are all there (#134 case 13)" {
  run in_ns user "$REPO/gpu/load.sh" check
  status_is 0
}

@test "load check: a build whose stamp does not match exits 3 and names the build script (#134 case 13)" {
  sha256sum "$FIX/gpu-burn-src/compare.cu" | cut -d' ' -f1 >"$BUILD/built"
  run in_ns user "$REPO/gpu/load.sh" check
  status_is 3
  [ "${#lines[@]}" -eq 1 ]
  [[ "$output" == *burn-build.sh* ]]
}

@test "load check: /usr/bin/memtest_vulkan not executable exits 3 and names it (#134 case 13)" {
  chmod 644 "$GUARD_MOCKS/memtest_vulkan"
  run in_ns user "$REPO/gpu/load.sh" check
  status_is 3
  [ "${#lines[@]}" -eq 1 ]
  [[ "$output" == *memtest_vulkan* ]]
}

@test "load check: no NVIDIA ICD file exits 3 and names it (#134 case 13)" {
  rm "$GUARD_ICD/nvidia_icd.json"
  run in_ns user "$REPO/gpu/load.sh" check
  status_is 3
  [ "${#lines[@]}" -eq 1 ]
  [[ "$output" == *nvidia_icd.json* ]]
}

@test "load: unknown kind, bad or zero seconds, seconds over 3600 and a missing device index exit 2 and run no tool (#134 case 14)" {
  for args in "bogus 1 1" "core x 1" "core 1 x" "core 0 1" "core 1 0" \
    "core 3601 1" "core 1 3601" "mem 1 1"; do
    echo "load.sh $args"
    # shellcheck disable=SC2086 # one word per argument, on purpose
    load_sh $args
    status_is 2
    no_tool_ran
  done
}

# Cases beyond the contract (#134): the readings of amendment 1 ruling 8 and the choices
# gpu/load.sh makes where the ticket is silent.

@test "load core: a burn process that died gives invalid, reason=died, though the summary says OK (#134)" {
  MOCK_BURN_OUT="$FIX/core/died.out" load_sh core 1 1
  verdict 3 invalid
  [ "$(value reason)" = died ]
}

@test "load core: a summary with two GPU lines gives invalid, reason=summary (#134)" {
  MOCK_BURN_OUT="$FIX/core/two-gpus.out" load_sh core 1 1
  verdict 3 invalid
  [ "$(value reason)" = summary ]
}

@test "load core: an OK summary passes whatever gpu_burn exits with (#134)" {
  MOCK_BURN_EXIT=1 load_sh core 1 1
  verdict 0 pass
}

@test "load mem: Error found in the output gives fail though the status byte is 65 (#134)" {
  MOCK_MEMTEST_OUT="$FIX/mem/error-found.out" load_sh mem 1 1 1
  verdict 1 fail
  [ "$(value reason)" = errors ]
}

@test "load mem: a status without the memtest_vulkan signature gives invalid, bit 1 set or not (#134)" {
  for code in 3 127 139; do
    echo "memtest_vulkan exit code $code"
    rm -f "$MOCK_STATE"/*
    MOCK_MEMTEST_EXIT="$code" load_sh mem 1 1 1
    verdict 3 invalid
    [ "$(value reason)" = exit ]
  done
}

@test "load: the log directory keeps the block, the tool output, the samples and the command (#134)" {
  load_sh core 1 1
  verdict 0 pass
  log="$(value log)"
  [ "$(cat "$log/result")" = "$output" ]
  grep -q '^Tested 1 GPUs:$' "$log/tool.out"
  [ "$(head -c 1 "$log/samples.csv")" = "#" ]
  [ "$(grep -c '^[0-9]' "$log/samples.csv")" -ge 1 ]
  [ "$(cat "$log/command")" = "timeout -k 10 62 ./gpu_burn -m 80% -stts 5 2" ]
  [ ! -e "$log/pipe" ]
}

@test "load: SIGTERM during the run gives invalid, reason=interrupted, and leaves no load behind (#134)" {
  in_ns user "$REPO/gpu/load.sh" core 1 20 >"$BATS_TEST_TMPDIR/out" 2>"$BATS_TEST_TMPDIR/err" 3>&- &
  job=$!
  for _ in {1..100}; do
    [[ ! -e "$MOCK_STATE/start" ]] || break
    sleep 0.1
  done
  [ -e "$MOCK_STATE/start" ]
  # the oldest match is load.sh itself; its subshells carry the same command line
  kill -TERM "$(pgrep -o -f "$REPO/gpu/load.sh core 1 20")"
  code=0
  wait "$job" || code=$?
  cat "$BATS_TEST_TMPDIR/out" "$BATS_TEST_TMPDIR/err"
  [ "$code" -eq 3 ]
  grep -qx 'result=invalid' "$BATS_TEST_TMPDIR/out"
  grep -qx 'reason=interrupted' "$BATS_TEST_TMPDIR/out"
  # the mock gpu_burn and its sleep run with the build directory as cwd
  build="$(cd "$BUILD" && pwd -P)"
  for p in /proc/[0-9]*; do
    [[ "$(readlink "$p/cwd" 2>/dev/null)" != "$build" ]] || {
      echo "still running: $p $(tr '\0' ' ' <"$p/cmdline")"
      return 1
    }
  done
  [ -z "$(pgrep -f "$REPO/gpu/load.sh")" ]
}

@test "load: no HOME and no XDG_CACHE_HOME gives invalid and no load is started (#134)" {
  HOME="" load_sh core 1 1
  verdict 3 invalid
  [ "$(value reason)" = log ]
  [ ! -e "$MOCK_STATE/gpu_burn.args" ]
  HOME="" run in_ns user "$REPO/gpu/load.sh" check
  status_is 3
  [ "${#lines[@]}" -eq 1 ]
}

@test "load: a pin that is not well formed counts as no build (#134)" {
  write_pin abc
  load_sh core 1 1
  verdict 3 invalid
  [ "$(value reason)" = build ]
  [ ! -e "$MOCK_STATE/gpu_burn.args" ]
  run in_ns user "$REPO/gpu/load.sh" check
  status_is 3
  [ "${#lines[@]}" -eq 1 ]
  [[ "$output" == *burn-build.sh* ]]
}

@test "load mem: runs without a gpu_burn build (#134)" {
  rm -r "$BUILD"
  load_sh mem 1 1 1
  verdict 0 pass
}

@test "load: an extra argument and a two-digit device index exit 2 and run no tool (#134)" {
  for args in "check now" "core 1 1 1" "mem 1 1 1 1" "mem 1 1 10" "mem 1 1 x" ""; do
    echo "load.sh $args"
    # shellcheck disable=SC2086 # one word per argument, on purpose
    load_sh $args
    status_is 2
    [ -z "$output" ]
    no_tool_ran
  done
}

# Contract for #140 (N is the number in the ticket's Check list). A load that ended before
# warm-up + load seconds is invalid, reason=short; all seven limit reasons are read, in
# whichever column the active one is. The load mocks end early through MOCK_BURN_RUN_MS and
# MOCK_MEMTEST_RUN_MS. Cases 3, 5 and 7 and the Xid case of 1 pin what gpu/load.sh of #134
# already does; the others need #140.
# #150 changed two rules of it. The block has one key more, power_cap (cases 1, 2 and 3
# count and name it). And case 4, "each of the seven limit reasons alone, Active in a
# sample after the warm-up, gives invalid, reason=limited", is gone: three of the seven
# (sw_power_cap, board_limit, reliability) are Active in every clean load on the real card
# and void nothing any more. Which four still do, and what the other three do, is pinned
# by #150 cases 1 to 4 and 6 at the end of this file.
# Check 8 (existing cases stay green) holds one verdict that comes before reason=short: the
# load of "ERROR_DEVICE_LOST in the output gives fail" ends by itself 2 s into mem 1 2, as a
# tool that lost its device does, and that case stays fail.

@test "#140 case 1: core: a complete OK output from a load that ended 1.5 s into core 1 3 gives invalid, reason=short, exit 3" {
  MOCK_BURN_RUN_MS=1500 load_sh core 1 3
  verdict 3 invalid
  block_ok 9
  [ "$(value reason)" = short ]
  # load.sh asked for the 4 s, and what the tool printed was complete and clean
  [ "$(tail -n 1 "$MOCK_STATE/gpu_burn.args")" = 4 ]
  grep -q -x $'\tGPU 0: OK' "$(value log)/tool.out"
}

@test "#140 case 1: core: a load that ended half a second before the end of core 1 1, after the last sample, is short as well" {
  MOCK_BURN_RUN_MS=1500 load_sh core 1 1
  verdict 3 invalid
  [ "$(value reason)" = short ]
}

@test "#140 case 1: core: a FAULTY summary and exit status 1 from a load that ended early give invalid, reason=short, not fail" {
  MOCK_BURN_EXIT=1 MOCK_BURN_RUN_MS=1500 MOCK_BURN_OUT="$FIX/core/faulty.out" load_sh core 1 3
  verdict 3 invalid
  [ "$(value reason)" = short ]
  grep -q 'GPU 0: FAULTY' "$(value log)/tool.out"
}

@test "#140 case 1: a new NVRM: Xid line keeps its place: a load that ended early gives fail, reason=xid" {
  MOCK_BURN_RUN_MS=1500 MOCK_JOURNAL_AFTER="$FIX/journal/xid.txt" load_sh core 1 3
  verdict 1 fail
  [ "$(value reason)" = xid ]
}

@test "#140 case 2: mem: a read line after the warm-up and status 65 from a load that ended 1.7 s into mem 1 3 gives invalid, reason=short, exit 3" {
  MOCK_MEMTEST_RUN_MS=1700 load_sh mem 1 3 1
  verdict 3 invalid
  block_ok 10
  [ "$(value reason)" = short ]
  # it ended by itself, with the read line of 1.5 s printed
  [ ! -e "$MOCK_STATE/memtest_vulkan.signal" ]
  grep -q 'checked: *45.0GB *50.0GB/sec' "$(value log)/tool.out"
}

@test "#140 case 2: mem: status 67 from a load that ended early gives invalid, reason=short, not fail" {
  MOCK_MEMTEST_EXIT=67 MOCK_MEMTEST_RUN_MS=1700 load_sh mem 1 3 1
  verdict 3 invalid
  [ "$(value reason)" = short ]
  [ ! -e "$MOCK_STATE/memtest_vulkan.signal" ]
}

@test "#140 case 3: the core and mem pass fixtures, run for their full time, still pass, with the key set of #134 and power_cap (#150)" {
  load_sh core 1 1
  verdict 0 pass
  [ "$(value reason)" = ok ]
  [ "$(keys)" = "core_mhz_max limited log mem_mhz_max power_cap pstate_min reason result xid " ]
  rm -f "$MOCK_STATE"/*
  load_sh mem 1 1 1
  verdict 0 pass
  [ "$(value reason)" = ok ]
  [ "$(keys)" = "core_mhz_max limited log mem_mhz_max power_cap pstate_min read_gbs reason result xid " ]
}

# "#140 case 4" stood here: each of the seven limit reasons alone gives invalid,
# reason=limited. Deleted for #150, which takes that rule back for three of the seven; the
# four that are left, each alone, are #150 case 4.

@test "#140 case 5: all seven limit reasons Active during the warm-up only: pass, limited=0" {
  # 0x6ec: the bits of the seven limit reasons
  smi_rows 0x6ec 0x0
  load_sh core 1 1
  verdict 0 pass
  [ "$(value limited)" = 0 ]
}

@test "#140 case 6: every sample's --query-gpu holds the seven limit reason fields and none of gpu_idle, applications_clocks_setting, sync_boost, which do not limit" {
  # 0x13: gpu_idle, applications_clocks_setting and sync_boost, Active after the warm-up
  smi_rows 0x0 0x13
  load_sh core 1 1
  verdict 0 pass
  [ "$(value limited)" = 0 ]
  [ -s "$MOCK_STATE/nvidia-smi.calls" ]
  while read -r -a call; do
    fields=""
    for arg in "${call[@]}"; do
      [[ "$arg" != --query-gpu=* ]] || fields=",${arg#--query-gpu=},"
    done
    # the driver's help lists every reason field under two names
    fields="${fields//clocks_throttle_reasons./clocks_event_reasons.}"
    for name in board_limit reliability sw_power_cap hw_slowdown sw_thermal_slowdown \
      hw_thermal_slowdown hw_power_brake_slowdown; do
      [[ "$fields" == *",clocks_event_reasons.$name,"* ]] || {
        echo "no $name field in: ${call[*]}"
        return 1
      }
    done
    for name in gpu_idle applications_clocks_setting sync_boost; do
      [[ "$fields" != *",clocks_event_reasons.$name,"* ]] || {
        echo "$name is queried: ${call[*]}"
        return 1
      }
    done
  done <"$MOCK_STATE/nvidia-smi.calls"
}

@test "#140 case 7a: core: an OK summary and no progress line with an error count gives invalid (lead ruling 2 on #134)" {
  MOCK_BURN_OUT="$FIX/core/no-progress.out" load_sh core 1 1
  verdict 3 invalid
  grep -q -x $'\tGPU 0: OK' "$(value log)/tool.out"
}

@test "#140 case 7b: journalctl exiting 1 with -- No entries -- and text on stderr gives invalid, reason=journal" {
  MOCK_JOURNAL_ERR="$FIX/journal/truncated.err" load_sh core 1 1
  verdict 3 invalid
  [ "$(value reason)" = journal ]
  [ -s "$MOCK_STATE/journalctl.after" ]
}

@test "#140 case 7c: journalctl exiting 1 with another line next to -- No entries -- on stdout gives invalid, reason=journal" {
  MOCK_JOURNAL_NOMATCH="$FIX/journal/header-no-entries.txt" load_sh core 1 1
  verdict 3 invalid
  [ "$(value reason)" = journal ]
  [ -s "$MOCK_STATE/journalctl.after" ]
}

@test "#140 case 7d: a sample during the warm-up that cannot be parsed, or that fails, gives invalid (#134 amendment 1, ruling 6)" {
  for row in unknown fail; do
    echo "warm-up sample: $row"
    rm -f "$MOCK_STATE"/*
    export MOCK_SMI_ROWS="$BATS_TEST_TMPDIR/smi.rows"
    printf 'warm %s\npost P0 2520 8001 131.40 58 0x0\n' "$row" >"$MOCK_SMI_ROWS"
    load_sh core 1 1
    verdict 3 invalid
  done
}

# Own cases for #140: where reason=short stands among the invalid reasons the contract
# leaves open (journal, sample and nosample come first), and what the log keeps.

@test "load: a load that ended early and a journal that cannot be read give invalid, reason=journal (#140)" {
  MOCK_BURN_RUN_MS=1500 MOCK_JOURNAL_ERR="$FIX/journal/truncated.err" load_sh core 1 3
  verdict 3 invalid
  [ "$(value reason)" = journal ]
}

@test "load: a failed sample, after which load.sh ends the load itself, gives invalid, reason=sample, not short (#140)" {
  MOCK_SMI_ROWS="$FIX/smi/fail-post.rows" load_sh core 1 3
  verdict 3 invalid
  [ "$(value reason)" = sample ]
}

@test "load: a load that ended during the warm-up gives invalid, reason=nosample (#140)" {
  # the pass fixture's last timed line is at 1.3 s, so the mock ends at 1.5 s of a 2 s warm-up
  MOCK_BURN_RUN_MS=1500 load_sh core 2 1
  verdict 3 invalid
  [ "$(value reason)" = nosample ]
}

@test "load mem: a short load still reports the read speed it measured, and the log keeps the ms at which the load was seen to end (#140)" {
  MOCK_MEMTEST_RUN_MS=1700 load_sh mem 1 3 1
  verdict 3 invalid
  [ "$(value reason)" = short ]
  awk -v v="$(value read_gbs)" 'BEGIN { exit !(v == 50) }'
  ended="$(<"$(value log)/ended")"
  echo "ended at $ended ms"
  ((ended >= 1700 && ended < 4000))
  rm -f "$MOCK_STATE"/*
  load_sh mem 1 1 1
  verdict 0 pass
  ended="$(<"$(value log)/ended")"
  echo "ended at $ended ms"
  ((ended >= 2000))
}

# Contract for #150, cases 1 to 7 of its Check list. limited=1, and with it invalid,
# reason=limited, is left to the four slowdown reasons; sw_power_cap, board_limit and
# reliability change neither result nor reason, and sw_power_cap after the warm-up is
# reported as power_cap=1, on the line after limited. Cases 1 and 2 replay what the real
# card gave at stock clocks: samples and tool output of two kept logs of the pre-flight
# (#121 comment 5953205480), in smi/recorded-*.rows, core/recorded.out, mem/recorded.out.

@test "#150 case 1: core: the recorded real samples, sw_power_cap Active in every one, with the recorded clean gpu_burn output: result=pass, limited=0, power_cap=1, exit 0" {
  MOCK_BURN_OUT="$FIX/core/recorded.out" MOCK_SMI_ROWS="$FIX/smi/recorded-core.rows" load_sh core 1 2
  verdict 0 pass
  block_ok 9
  [ "$(value reason)" = ok ]
  [ "$(value limited)" = 0 ]
  [ "$(value power_cap)" = 1 ]
  [ "$(value xid)" = 0 ]
  [ "$(value pstate_min)" = 2 ]
  [ "$(value core_mhz_max)" = 2205 ]
  [ "$(value mem_mhz_max)" = 8751 ]
  # what the run judged is the recording: every sample has sw_power_cap Active and no
  # other reason, the first after the warm-up is the line of 30001 ms
  log="$(value log)"
  capped='P2, [0-9]+, 8751, 159\.[0-9]+, 59, Active(, Not Active){6}'
  [ "$(grep -c '^[0-9]' "$log/samples.csv")" -ge 2 ]
  [ "$(grep -c '^[0-9]' "$log/samples.csv")" -eq "$(grep -Ec "^[0-9]+, $capped\$" "$log/samples.csv")" ]
  grep -Eq '^[0-9]+, P2, 2205, 8751, 159\.24, 59, Active(, Not Active){6}$' "$log/samples.csv"
  grep -q -x $'\tGPU 0: OK' "$log/tool.out"
  grep -q "100.0%  proc'd: 1672 (12086 Gflop/s)   errors: 0   temps: 63 C" "$log/tool.out"
}

@test "#150 case 2: mem: the recorded real samples, reliability Active in every one, with the recorded clean memtest_vulkan output: result=pass, limited=0, power_cap=0" {
  MOCK_MEMTEST_OUT="$FIX/mem/recorded.out" MOCK_SMI_ROWS="$FIX/smi/recorded-mem.rows" load_sh mem 1 2 0
  verdict 0 pass
  block_ok 10
  [ "$(value reason)" = ok ]
  [ "$(value limited)" = 0 ]
  [ "$(value power_cap)" = 0 ]
  [ "$(value xid)" = 0 ]
  [ "$(value pstate_min)" = 2 ]
  [ "$(value core_mhz_max)" = 2730 ]
  [ "$(value mem_mhz_max)" = 8751 ]
  # the real run reported 250.75, the median of 249.7, 250.7, 250.8, 250.8
  awk -v v="$(value read_gbs)" 'BEGIN { exit !(v >= 250.5 && v <= 250.8) }'
  log="$(value log)"
  flat='P2, 2730, 8751, 11[67]\.[0-9]+, 5[01](, Not Active){6}, Active'
  [ "$(grep -c '^[0-9]' "$log/samples.csv")" -ge 2 ]
  [ "$(grep -c '^[0-9]' "$log/samples.csv")" -eq "$(grep -Ec "^[0-9]+, $flat\$" "$log/samples.csv")" ]
  [ "$(cat "$MOCK_STATE/memtest_vulkan.signal")" = INT ]
}

@test "#150 case 3: board_limit Active in the samples after the warm-up: pass, limited=0, power_cap=0; the three reasons that void nothing, all Active: pass, limited=0, power_cap=1" {
  smi_rows 0x0 0x200
  load_sh core 1 1
  verdict 0 pass
  [ "$(value reason)" = ok ]
  [ "$(value limited)" = 0 ]
  [ "$(value power_cap)" = 0 ]
  rm -f "$MOCK_STATE"/*
  # 0x604: sw_power_cap, board_limit and reliability
  smi_rows 0x0 0x604
  load_sh mem 1 1 1
  verdict 0 pass
  [ "$(value reason)" = ok ]
  [ "$(value limited)" = 0 ]
  [ "$(value power_cap)" = 1 ]
}

@test "#150 case 4: each of the four slowdown reasons alone, Active in a sample after the warm-up, gives invalid, reason=limited, limited=1, power_cap=0; Active during the warm-up only, it changes nothing" {
  missed=""
  for column in hw_slowdown:0x8 hw_thermal_slowdown:0x40 hw_power_brake_slowdown:0x80 \
    sw_thermal_slowdown:0x20; do
    rm -f "$MOCK_STATE"/*
    smi_rows 0x0 "${column#*:}"
    load_sh core 1 1
    if ! (verdict 3 invalid && [ "$(value reason)" = limited ] && [ "$(value limited)" = 1 ] &&
      [ "$(value power_cap)" = 0 ]); then
      printf 'only %s Active after the warm-up: exit %s\n%s\n' "${column%:*}" "$status" "$output"
      missed+=" ${column%:*}"
    fi
    rm -f "$MOCK_STATE"/*
    smi_rows "${column#*:}" 0x0
    load_sh core 1 1
    if ! (verdict 0 pass && [ "$(value reason)" = ok ] && [ "$(value limited)" = 0 ] &&
      [ "$(value power_cap)" = 0 ]); then
      printf 'only %s Active in the warm-up: exit %s\n%s\n' "${column%:*}" "$status" "$output"
      missed+=" ${column%:*}(warm-up)"
    fi
  done
  [ -z "$missed" ] || {
    echo "not as the contract says:$missed"
    return 1
  }
}

@test "#150 case 5: sw_power_cap Active during the warm-up only: pass, limited=0, power_cap=0" {
  MOCK_SMI_ROWS="$FIX/smi/limit-warm.rows" load_sh core 1 1
  verdict 0 pass
  [ "$(value limited)" = 0 ]
  [ "$(value power_cap)" = 0 ]
}

@test "#150 case 6: a slowdown reason and sw_power_cap in one run, in one sample or in two: invalid, reason=limited, limited=1, power_cap=1" {
  # 0xc: hw_slowdown and sw_power_cap
  smi_rows 0x0 0xc
  load_sh core 1 1
  verdict 3 invalid
  [ "$(value reason)" = limited ]
  [ "$(value limited)" = 1 ]
  [ "$(value power_cap)" = 1 ]
  rm -f "$MOCK_STATE"/*
  # the power cap in the first sample after the warm-up, sw_thermal_slowdown from the second
  smi_scenario 'warm P0 2520 8001 131.40 52 0x0' 'post P0 2400 8001 160.02 71 0x4' \
    'post P0 2400 8001 131.40 71 0x20'
  load_sh core 1 2
  verdict 3 invalid
  [ "$(value reason)" = limited ]
  [ "$(value limited)" = 1 ]
  [ "$(value power_cap)" = 1 ]
}

@test "#150 case 7: power_cap= is the line after limited= for both kinds, and nothing else of the block of #134 moved" {
  load_sh core 1 1
  verdict 0 pass
  [ "$(after_limited)" = power_cap=0 ]
  [ "$(key_order)" = "result reason pstate_min core_mhz_max mem_mhz_max limited power_cap xid log " ]
  rm -f "$MOCK_STATE"/*
  load_sh mem 1 1 1
  verdict 0 pass
  [ "$(after_limited)" = power_cap=0 ]
  [ "$(key_order)" = "result reason pstate_min core_mhz_max mem_mhz_max limited power_cap xid read_gbs log " ]
  rm -f "$MOCK_STATE"/*
  # a load at the power limit; smi/limit-post.rows has sw_power_cap after the warm-up
  MOCK_SMI_ROWS="$FIX/smi/limit-post.rows" load_sh core 1 1
  verdict 0 pass
  [ "$(value limited)" = 0 ]
  [ "$(after_limited)" = power_cap=1 ]
  rm -f "$MOCK_STATE"/*
  MOCK_SMI_ROWS="$FIX/smi/limit-post.rows" load_sh mem 1 1 1
  verdict 0 pass
  [ "$(value limited)" = 0 ]
  [ "$(after_limited)" = power_cap=1 ]
  rm -f "$MOCK_STATE"/*
  # the same place in a block that is not a pass
  smi_rows 0x0 0x44
  load_sh core 1 1
  verdict 3 invalid
  [ "$(value limited)" = 1 ]
  [ "$(after_limited)" = power_cap=1 ]
}

@test "#150 case 7: a run with no sample after the warm-up prints limited= and power_cap= empty, power_cap= on the line after limited=" {
  # the load ended in the warm-up (the nosample case of #140)
  MOCK_BURN_RUN_MS=1500 load_sh core 2 1
  verdict 3 invalid
  [ "$(value reason)" = nosample ]
  block_ok 9
  [ "$(grep -c '^limited=$' <<<"$output")" -eq 1 ]
  [ "$(after_limited)" = power_cap= ]
  rm -f "$MOCK_STATE"/*
  # the same for the memory kind
  MOCK_MEMTEST_RUN_MS=1500 load_sh mem 2 1 1
  verdict 3 invalid
  block_ok 10
  [ "$(grep -c '^limited=$' <<<"$output")" -eq 1 ]
  [ "$(after_limited)" = power_cap= ]
  rm -f "$MOCK_STATE"/*
  # no load was started at all
  mv "$BUILD" "$BATS_TEST_TMPDIR/build-elsewhere"
  load_sh core 1 1
  verdict 3 invalid
  block_ok 9
  [ "$(grep -c '^limited=$' <<<"$output")" -eq 1 ]
  [ "$(after_limited)" = power_cap= ]
}

# Own case of the implementation (#150).

@test "load: own: #150: power_cap=1 stands next to a fail as well; reliability alone reaches neither key; a slowdown among the reasons that void nothing is limited=1 with power_cap=0" {
  smi_rows 0x0 0x4
  MOCK_BURN_OUT="$FIX/core/faulty.out" load_sh core 1 1
  verdict 1 fail
  [ "$(value limited)" = 0 ]
  [ "$(value power_cap)" = 1 ]
  rm -f "$MOCK_STATE"/*
  smi_rows 0x0 0x400
  load_sh core 1 1
  verdict 0 pass
  [ "$(value limited)" = 0 ]
  [ "$(value power_cap)" = 0 ]
  rm -f "$MOCK_STATE"/*
  # 0x620: sw_thermal_slowdown, board_limit and reliability
  smi_rows 0x0 0x620
  load_sh mem 1 1 1
  verdict 3 invalid
  [ "$(value reason)" = limited ]
  [ "$(value limited)" = 1 ]
  [ "$(value power_cap)" = 0 ]
}
