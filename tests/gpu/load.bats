#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

# Contract for gpu/load.sh (#134, cases 6 to 14 of the ticket's Check list). No case loads
# the GPU: gpu_burn, memtest_vulkan, nvidia-smi and journalctl are recording mocks, first
# on PATH and bound over /usr/bin/<name> in a private mount namespace
# (fixtures/load/guard.sh), so a load.sh that pins PATH or calls a tool by absolute path
# still cannot reach the real ones. The load mocks replay timed output, so a run takes its
# warm-up + load seconds: 1 + 1, or 1 + 2 where two samples after the warm-up are needed.

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

@test "load core: the pass fixture gives result=pass, exit 0, every line in the grammar, all keys (#134 case 6)" {
  load_sh core 1 1
  verdict 0 pass
  block_ok 8
  [ "$(value reason)" = ok ]
  [ "$(value pstate_min)" = 0 ]
  [ "$(value core_mhz_max)" = 2520 ]
  [ "$(value mem_mhz_max)" = 8001 ]
  [ "$(value limited)" = 0 ]
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
  block_ok 9
  [ "$(value reason)" = ok ]
  [ "$(value limited)" = 0 ]
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
  MOCK_SMI_ROWS="$FIX/smi/limit-post.rows" load_sh core 1 1
  verdict 3 invalid
  [ "$(value reason)" = limited ]
  [ "$(value limited)" = 1 ]
}

@test "load: the same limit reason during the warm-up only still passes (#134 case 11)" {
  MOCK_SMI_ROWS="$FIX/smi/limit-warm.rows" load_sh core 1 1
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
