#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup() {
  skip "contract #12 pending"
  SCRIPT="$BATS_TEST_DIRNAME/../../bench/game.sh"
  FIX="$BATS_TEST_DIRNAME/fixtures/game"
  # run-100.csv: 99 frames at 10.0 ms, then 1 at 40.0 ms
  # run-200.csv: 197 frames at 10.0 ms, 1 each at 50.0, 25.0 and 20.0 ms
  RUN100="$FIX/run-100.csv"
  RUN200="$FIX/run-200.csv"
}

# value <key>: print the value of stdout line <key>=
value() {
  local l
  for l in "${lines[@]}"; do
    [[ "$l" == "$1="* ]] && printf '%s\n' "${l#"$1="}" && return 0
  done
  return 1
}

# contract_order: stdout is input.* lines, then result.* lines, nothing else
contract_order() {
  local seen=0 l
  for l in "${lines[@]}"; do
    case "$l" in
      input.*=*) [ "$seen" -eq 0 ] || return 1 ;;
      result.*=*) seen=1 ;;
      *) return 1 ;;
    esac
  done
}

@test "parse gives 97.1 avg fps and 25.0 1% low for 99 frames at 10 ms and 1 at 40 ms" {
  run --separate-stderr bash "$SCRIPT" parse "$RUN100"
  [ "$status" -eq 0 ]
  contract_order
  # 1000 * 100 / (99 * 10 + 40) = 97.087
  [ "$(value result.game.run1.avg_fps)" = 97.1 ]
  [ "$(value result.game.run1.low1_fps)" = 25.0 ]
  [ "$(value result.game.avg_fps)" = 97.1 ]
  [ "$(value result.game.low1_fps)" = 25.0 ]
}

@test "parse uses MangoHud's 1% low: the frametime at index 0.01 * n - 1, slowest first" {
  run --separate-stderr bash "$SCRIPT" parse "$RUN200"
  [ "$status" -eq 0 ]
  # slowest first 50, 25, 20 ms; index 0.01 * 200 - 1 = 1 is 25 ms: 40.0 fps,
  # not the slowest frame (20.0) nor the mean of the slowest 1% (26.7 or 30.0)
  [ "$(value result.game.run1.low1_fps)" = 40.0 ]
  # 1000 * 200 / (197 * 10 + 50 + 25 + 20) = 96.852
  [ "$(value result.game.run1.avg_fps)" = 96.9 ]
}

@test "parse prints each run, then the mean of the runs, and its inputs" {
  run --separate-stderr bash "$SCRIPT" parse "$RUN100" "$RUN200"
  [ "$status" -eq 0 ]
  contract_order
  [ "$(value result.game.run1.avg_fps)" = 97.1 ]
  [ "$(value result.game.run1.low1_fps)" = 25.0 ]
  [ "$(value result.game.run2.avg_fps)" = 96.9 ]
  [ "$(value result.game.run2.low1_fps)" = 40.0 ]
  [ "$(value result.game.avg_fps)" = 97.0 ]
  [ "$(value result.game.low1_fps)" = 32.5 ]
  [ "$(value input.mangohud)" = v0.8.4 ]
  [ "$(value input.files)" = 2 ]
  [ -n "$(value input.low1_definition)" ]
}

@test "parse line 1 names the logs read, their bytes and the frame count" {
  run --separate-stderr bash "$SCRIPT" parse "$RUN100" "$RUN200"
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" =~ ^input\.source=(/[^\ ]+)\ bytes=([0-9]+)\ items=([0-9]+)$ ]]
  [[ "${BASH_REMATCH[1]}" == *"$RUN100"* ]]
  [[ "${BASH_REMATCH[1]}" == *"$RUN200"* ]]
  [ "${BASH_REMATCH[2]}" -eq "$(($(wc -c <"$RUN100") + $(wc -c <"$RUN200")))" ]
  [ "${BASH_REMATCH[3]}" -eq 300 ]
}

@test "parse exits 1 with pc-oc: bench: on a log with a header and no frames" {
  run --separate-stderr bash "$SCRIPT" parse "$FIX/header-only.csv"
  [ "$status" -eq 1 ]
  [[ "$stderr" == "pc-oc: bench: "* ]]
  [[ "$stderr" != *"not implemented"* ]]
}

@test "parse with no files exits 2" {
  run --separate-stderr bash "$SCRIPT" parse
  [ "$status" -eq 2 ]
}
