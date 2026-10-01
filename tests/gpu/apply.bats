#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup() {
  unset "${!GIT_@}"
  REPO="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$REPO/gpu" "$BATS_TEST_TMPDIR/bin"
  cp -r "$BATS_TEST_DIRNAME/../../lib" "$REPO/lib"
  cp "$BATS_TEST_DIRNAME/../../gpu/"{apply.sh,revert.sh,probe.sh,pl.sh} "$REPO/gpu/"
  export MOCK_DIR="$BATS_TEST_DIRNAME/fixtures/apply"
  export MOCK_STATE="$BATS_TEST_TMPDIR/mock"
  mkdir -p "$MOCK_STATE"
  # stock 150.00 differs from the card default 160.00, so revert-to-default fails
  printf '150.00\n' >"$MOCK_STATE/pl"
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

@test "apply then revert gpu logs -pl 150 and removes the snapshot" {
  set_pl 216
  run --separate-stderr bash "$REPO/gpu/apply.sh"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^gpu.pl_w=150' "$PC_OC_STATE/gpu/stock")" -eq 1 ]
  run --separate-stderr bash "$REPO/gpu/revert.sh"
  [ "$status" -eq 0 ]
  [ "$(tail -n 1 "$MOCK_STATE/calls")" = "-pl 150" ]
  [ "$(cat "$MOCK_STATE/pl")" = "150.00" ]
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
  grep -q '^gpu.pl_w=150' "$PC_OC_STATE/gpu/stock"
}

@test "revert gpu with no snapshot says nothing to revert, exits 0 and logs no -pl" {
  run --separate-stderr bash "$REPO/gpu/revert.sh"
  [ "$status" -eq 0 ]
  [ "$stderr" = "pc-oc: gpu: nothing to revert" ]
  [ ! -s "$MOCK_STATE/calls" ]
}

@test "apply gpu refuses pl_w 0250 as non-canonical and logs no -pl" {
  set_pl 0250
  run --separate-stderr bash "$REPO/gpu/apply.sh"
  [ "$status" -eq 1 ]
  [[ "$stderr" == "pc-oc: gpu: "* ]]
  [[ "$stderr" != *"not implemented"* ]]
  [ ! -s "$MOCK_STATE/calls" ]
}

@test "apply gpu refuses pl_w 08 as non-canonical and logs no -pl" {
  set_pl 08
  run --separate-stderr bash "$REPO/gpu/apply.sh"
  [ "$status" -eq 1 ]
  [[ "$stderr" == "pc-oc: gpu: "* ]]
  [[ "$stderr" != *"not implemented"* ]]
  [ ! -s "$MOCK_STATE/calls" ]
}

@test "apply gpu refuses a 64-bit wrapping pl_w and logs no -pl" {
  set_pl 18446744073709551832
  run --separate-stderr bash "$REPO/gpu/apply.sh"
  [ "$status" -eq 1 ]
  [[ "$stderr" == "pc-oc: gpu: "* ]]
  [[ "$stderr" != *"not implemented"* ]]
  [ ! -s "$MOCK_STATE/calls" ]
}

@test "first apply gpu whose -pl fails exits 1 and leaves the state dir empty" {
  ln -sf "$MOCK_DIR/nvidia-smi-fail-pl" "$BATS_TEST_TMPDIR/bin/nvidia-smi"
  set_pl 216
  run --separate-stderr bash "$REPO/gpu/apply.sh"
  [ "$status" -eq 1 ]
  [[ "$stderr" == "pc-oc: gpu: "* ]]
  [[ "$stderr" != *"not implemented"* ]]
  [ "$(cat "$MOCK_STATE/calls")" = "-pl 216" ]
  [ -z "$(find "$PC_OC_STATE" -type f 2>/dev/null)" ]
}

# set_snapshot <pl_w>: write a stock snapshot as probe.sh would have
set_snapshot() {
  mkdir -p "$PC_OC_STATE/gpu"
  printf 'source=/x bytes=1 items=1\ngpu.pl_w=%s\n' "$1" >"$PC_OC_STATE/gpu/stock"
}

@test "revert gpu whose read-back differs exits 1 and keeps the snapshot" {
  set_pl 216
  run --separate-stderr bash "$REPO/gpu/apply.sh"
  [ "$status" -eq 0 ]
  ln -sf "$MOCK_DIR/nvidia-smi-ignore-pl" "$BATS_TEST_TMPDIR/bin/nvidia-smi"
  run --separate-stderr bash "$REPO/gpu/revert.sh"
  [ "$status" -eq 1 ]
  [[ "$stderr" == "pc-oc: gpu: "* ]]
  [[ "$stderr" != *"not implemented"* ]]
  [ -f "$PC_OC_STATE/gpu/stock" ]
}

@test "apply gpu exits 1 when the read-back is 1 W off the request" {
  ln -sf "$MOCK_DIR/nvidia-smi-off-by-one" "$BATS_TEST_TMPDIR/bin/nvidia-smi"
  set_pl 200
  run --separate-stderr bash "$REPO/gpu/apply.sh"
  [ "$status" -eq 1 ]
  [[ "$stderr" == "pc-oc: gpu: "* ]]
  [ "$(cat "$MOCK_STATE/calls")" = "-pl 200" ]
  [ "$(cat "$MOCK_STATE/pl")" = "201.00" ]
}

@test "revert gpu with snapshot pl_w 300.00 above the mocked max exits 1, logs no -pl, keeps the snapshot" {
  set_snapshot 300.00
  run --separate-stderr bash "$REPO/gpu/revert.sh"
  [ "$status" -eq 1 ]
  [[ "$stderr" == "pc-oc: gpu: "* ]]
  [[ "$stderr" != *"not implemented"* ]]
  [ ! -s "$MOCK_STATE/calls" ]
  [ -f "$PC_OC_STATE/gpu/stock" ]
}

@test "revert gpu with snapshot pl_w 50.00 below the mocked min exits 1, logs no -pl, keeps the snapshot" {
  set_snapshot 50.00
  run --separate-stderr bash "$REPO/gpu/revert.sh"
  [ "$status" -eq 1 ]
  [[ "$stderr" == "pc-oc: gpu: "* ]]
  [ ! -s "$MOCK_STATE/calls" ]
  [ -f "$PC_OC_STATE/gpu/stock" ]
}

@test "apply then revert gpu leaves no gpu dir under the state dir" {
  set_pl 216
  run --separate-stderr bash "$REPO/gpu/apply.sh"
  [ "$status" -eq 0 ]
  run --separate-stderr bash "$REPO/gpu/revert.sh"
  [ "$status" -eq 0 ]
  [ ! -e "$PC_OC_STATE/gpu" ]
}

@test "revert gpu keeps a gpu state dir that still holds another file" {
  set_pl 216
  run --separate-stderr bash "$REPO/gpu/apply.sh"
  [ "$status" -eq 0 ]
  printf 'x\n' >"$PC_OC_STATE/gpu/other"
  run --separate-stderr bash "$REPO/gpu/revert.sh"
  [ "$status" -eq 0 ]
  [ -f "$PC_OC_STATE/gpu/other" ]
}

@test "the -pl call, power.limit read-back and 0.5 W tolerance appear only in gpu/pl.sh, not in apply.sh or revert.sh" {
  gpu="$BATS_TEST_DIRNAME/../../gpu"
  grep -q -e 'nvidia-smi -pl "' "$gpu/pl.sh"
  grep -q -e 'power\.limit' "$gpu/pl.sh"
  run grep -nE -e 'nvidia-smi -pl "|power\.limit|0\.5' "$gpu/apply.sh" "$gpu/revert.sh"
  [ "$status" -eq 1 ]
}

@test "no file under gpu/ contains EUID" {
  run grep -rn -e EUID "$BATS_TEST_DIRNAME/../../gpu"
  [ "$status" -eq 1 ] || printf '%s\n' "$output" >&2
  [ "$status" -eq 1 ]
  [ "$output" = "" ]
}
