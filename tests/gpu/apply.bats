#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup() {
  unset "${!GIT_@}"
  REPO="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$REPO/gpu" "$BATS_TEST_TMPDIR/bin"
  cp -r "$BATS_TEST_DIRNAME/../../lib" "$REPO/lib"
  cp "$BATS_TEST_DIRNAME/../../gpu/"{apply.sh,revert.sh,probe.sh} "$REPO/gpu/"
  export MOCK_DIR="$BATS_TEST_DIRNAME/fixtures/apply"
  export MOCK_STATE="$BATS_TEST_TMPDIR/mock"
  mkdir -p "$MOCK_STATE"
  printf '160.00\n' >"$MOCK_STATE/pl"
  : >"$MOCK_STATE/calls"
  ln -s "$MOCK_DIR/nvidia-smi" "$BATS_TEST_TMPDIR/bin/nvidia-smi"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  export PC_OC_STATE="$BATS_TEST_TMPDIR/state"
}

# set_pl <watts>: write the gpu/values file of the fake repo
set_pl() {
  printf 'pl_w=%s  # src: smi\n' "$1" >"$REPO/gpu/values"
}

@test "apply gpu refuses pl_w 99 below the mocked min and logs no -pl" {
  set_pl 99
  run --separate-stderr bash "$REPO/gpu/apply.sh"
  [ "$status" -eq 1 ]
  [ "$stderr" = "pc-oc: gpu: pl_w 99 outside [100, 216]" ]
  [ ! -s "$MOCK_STATE/calls" ]
}

@test "apply gpu refuses pl_w 217 above the mocked max and logs no -pl" {
  set_pl 217
  run --separate-stderr bash "$REPO/gpu/apply.sh"
  [ "$status" -eq 1 ]
  [ "$stderr" = "pc-oc: gpu: pl_w 217 outside [100, 216]" ]
  [ ! -s "$MOCK_STATE/calls" ]
}

@test "apply gpu with pl_w 216 logs -pl 216 once and exits 0" {
  set_pl 216
  run --separate-stderr bash "$REPO/gpu/apply.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$MOCK_STATE/calls")" = "-pl 216" ]
  [ "$(cat "$MOCK_STATE/pl")" = "216.00" ]
}

@test "apply gpu exits 1 when the read-back differs because -pl was ignored" {
  ln -sf "$MOCK_DIR/nvidia-smi-ignore-pl" "$BATS_TEST_TMPDIR/bin/nvidia-smi"
  set_pl 216
  run --separate-stderr bash "$REPO/gpu/apply.sh"
  [ "$status" -eq 1 ]
  [[ "$stderr" == "pc-oc: gpu: "* ]]
  [[ "$stderr" != *"not implemented"* ]]
  [ "$(cat "$MOCK_STATE/calls")" = "-pl 216" ]
}

@test "apply then revert gpu logs -pl 160 and removes the snapshot" {
  set_pl 216
  run --separate-stderr bash "$REPO/gpu/apply.sh"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^gpu.pl_w=160' "$PC_OC_STATE/gpu/stock")" -eq 1 ]
  run --separate-stderr bash "$REPO/gpu/revert.sh"
  [ "$status" -eq 0 ]
  [ "$(tail -n 1 "$MOCK_STATE/calls")" = "-pl 160" ]
  [ "$(cat "$MOCK_STATE/pl")" = "160.00" ]
  [ ! -e "$PC_OC_STATE/gpu/stock" ]
}

@test "second apply gpu keeps the first snapshot" {
  set_pl 216
  run --separate-stderr bash "$REPO/gpu/apply.sh"
  [ "$status" -eq 0 ]
  cp "$PC_OC_STATE/gpu/stock" "$BATS_TEST_TMPDIR/first"
  set_pl 200
  run --separate-stderr bash "$REPO/gpu/apply.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$MOCK_STATE/pl")" = "200.00" ]
  cmp "$PC_OC_STATE/gpu/stock" "$BATS_TEST_TMPDIR/first"
  grep -q '^gpu.pl_w=160' "$PC_OC_STATE/gpu/stock"
}

@test "revert gpu with no snapshot exits 1 and logs no -pl" {
  run --separate-stderr bash "$REPO/gpu/revert.sh"
  [ "$status" -eq 1 ]
  [ "$stderr" = "pc-oc: gpu: no stock snapshot" ]
  [ ! -s "$MOCK_STATE/calls" ]
}
