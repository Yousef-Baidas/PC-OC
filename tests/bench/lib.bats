#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup() {
  ROOT="$BATS_TEST_DIRNAME/../.."
  # the dirs the structural case scans; overridable so a broken copy can be shown red
  BENCH_DIR="${BENCH_DIR:-$ROOT/bench}"
  TESTS_DIR="${TESTS_DIR:-$ROOT/tests/bench}"
  # run through bash -c so die's exit cannot take the test shell with it
  LOAD="source '$ROOT/lib/common.sh'; source '$BENCH_DIR/lib.sh'"
}

@test "need with a missing tool prints the unified message and exits 1" {
  skip "contract #39 pending"
  run --separate-stderr bash -c "$LOAD; need no-such-tool-xyz 'pacman -S xyz'"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [ "$stderr" = "pc-oc: bench: no-such-tool-xyz not found; install: pacman -S xyz" ]
}

@test "need with a present tool prints nothing and exits 0" {
  skip "contract #39 pending"
  run --separate-stderr bash -c "$LOAD; need bash 'pacman -S bash'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
}

@test "input_line prints input.source=<source> bytes=<bytes> items=<items>" {
  skip "contract #39 pending"
  run --separate-stderr bash -c "$LOAD; input_line /tmp/a.csv 123 4"
  [ "$status" -eq 0 ]
  [ "$output" = "input.source=/tmp/a.csv bytes=123 items=4" ]
  [ -z "$stderr" ]
}

@test "input_line accepts zero bytes and zero items" {
  skip "contract #39 pending"
  run bash -c "$LOAD; input_line src 0 0"
  [ "$status" -eq 0 ]
  [ "$output" = "input.source=src bytes=0 items=0" ]
}

@test "input_line rejects bytes=-1 and prints nothing on stdout" {
  skip "contract #39 pending"
  run --separate-stderr bash -c "$LOAD; input_line src -1 3"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ "$stderr" == "pc-oc: bench: "*bytes* ]]
}

@test "input_line rejects items=x and prints nothing on stdout" {
  skip "contract #39 pending"
  run --separate-stderr bash -c "$LOAD; input_line src 3 x"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ "$stderr" == "pc-oc: bench: "*items* ]]
}

@test "input_line rejects empty and non-integer bytes" {
  skip "contract #39 pending"
  run --separate-stderr bash -c "$LOAD; input_line src '' 3"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *bytes* ]]
  run --separate-stderr bash -c "$LOAD; input_line src 1.5 3"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *bytes* ]]
}

@test "only bench/lib.sh defines need() or prints input.source=; only helper.bash defines value() and contract_order()" {
  skip "contract #39 pending"
  local scripts=("$BENCH_DIR"/*.sh) bats=("$TESTS_DIR"/*.bats) f bad=""
  echo "# $BENCH_DIR sha256=$(cat "${scripts[@]}" | sha256sum | cut -c1-12) scripts=${#scripts[@]} bats=${#bats[@]}" >&3
  for f in "${scripts[@]}"; do
    [ "$(basename "$f")" = lib.sh ] && continue
    grep -Eq '^[[:space:]]*(function[[:space:]]+)?need[[:space:]]*\(\)' "$f" && bad+="$f defines need()"$'\n'
    grep -Fq "printf 'input.source=" "$f" && bad+="$f prints input.source= by hand"$'\n'
  done
  for f in "${bats[@]}"; do
    grep -Eq '^[[:space:]]*(function[[:space:]]+)?value[[:space:]]*\(\)' "$f" && bad+="$f defines value()"$'\n'
    grep -Eq '^[[:space:]]*(function[[:space:]]+)?contract_order[[:space:]]*\(\)' "$f" && bad+="$f defines contract_order()"$'\n'
  done
  [ -z "$bad" ] || {
    printf '%s' "$bad" >&2
    return 1
  }
}
