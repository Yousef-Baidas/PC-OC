#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup() {
  PROBE="$BATS_TEST_DIRNAME/../../gpu/probe.sh"
  STUB_DIR="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB_DIR"
  FIELDS='NVIDIA GeForce RTX 4060 Ti, 615.71.09, 95.06.1A.00.01, 160.00, 160.00, 100.00, 216.00, 3105, 9001'
  write_stub 0 "$FIELDS"
}

# write_stub <exit_code> <stdout>: put an nvidia-smi on PATH that logs its args
write_stub() {
  cat >"$STUB_DIR/nvidia-smi" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$BATS_TEST_TMPDIR/calls"
printf '%s\n' '$2'
exit $1
STUB
  chmod +x "$STUB_DIR/nvidia-smi"
  export PATH="$STUB_DIR:$PATH"
}

@test "probe gpu prints the power limit and its max among 9 key lines" {
  run --separate-stderr bash "$PROBE"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\ngpu.pl_w=160.00'* ]]
  [[ "$output" == *$'\ngpu.pl_max_w=216.00'* ]]
  [[ "$output" == *$'\ngpu.name=NVIDIA GeForce RTX 4060 Ti'* ]]
  [[ "$output" == *$'\ngpu.driver=615.71.09'* ]]
  [[ "$output" == *$'\ngpu.vbios=95.06.1A.00.01'* ]]
  [[ "$output" == *$'\ngpu.pl_default_w=160.00'* ]]
  [[ "$output" == *$'\ngpu.pl_min_w=100.00'* ]]
  [[ "$output" == *$'\ngpu.clock_max_mhz=3105'* ]]
  [[ "$output" == *$'\ngpu.mem_clock_max_mhz=9001'* ]]
  [ "$((${#lines[@]} - 1))" -eq 9 ]
}

@test "probe gpu line 1 names the nvidia-smi query, its byte count and the key count" {
  run --separate-stderr bash "$PROBE"
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" =~ ^source=[^\ ]*nvidia-smi[^\ ]*\ bytes=([0-9]+)\ items=9$ ]]
  [ "${BASH_REMATCH[1]}" -eq "$((${#FIELDS} + 1))" ]
}

@test "probe gpu makes one nvidia-smi query-gpu call" {
  run --separate-stderr bash "$PROBE"
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$BATS_TEST_TMPDIR/calls")" -eq 1 ]
  [ "$(cat "$BATS_TEST_TMPDIR/calls")" = "--query-gpu=name,driver_version,vbios_version,power.limit,power.default_limit,power.min_limit,power.max_limit,clocks.max.graphics,clocks.max.memory --format=csv,noheader,nounits" ]
}

@test "probe gpu exits 1 with pc-oc: gpu: when nvidia-smi exits 9" {
  write_stub 9 ""
  run --separate-stderr bash "$PROBE"
  [ "$status" -eq 1 ]
  [ "$output" = "" ]
  [[ "$stderr" == "pc-oc: gpu: "* ]]
  [[ "$stderr" != *"not implemented"* ]]
}

@test "probe gpu exits 1 with pc-oc: gpu: when nvidia-smi prints 8 fields" {
  write_stub 0 'NVIDIA GeForce RTX 4060 Ti, 615.71.09, 95.06.1A.00.01, 160.00, 160.00, 100.00, 216.00, 3105'
  run --separate-stderr bash "$PROBE"
  [ "$status" -eq 1 ]
  [ "$output" = "" ]
  [[ "$stderr" == "pc-oc: gpu: "* ]]
  [[ "$stderr" != *"not implemented"* ]]
}

@test "probe gpu exits 1 with pc-oc: gpu: when nvidia-smi prints two GPU rows" {
  write_stub 0 "$FIELDS"$'\n'"$FIELDS"
  run --separate-stderr bash "$PROBE"
  [ "$status" -eq 1 ]
  [ "$output" = "" ]
  [[ "$stderr" == "pc-oc: gpu: "* ]]
}

@test "probe gpu exits 1 with pc-oc: gpu: when power.limit is [N/A]" {
  write_stub 0 'NVIDIA GeForce RTX 4060 Ti, 615.71.09, 95.06.1A.00.01, [N/A], 160.00, 100.00, 216.00, 3105, 9001'
  run --separate-stderr bash "$PROBE"
  [ "$status" -eq 1 ]
  [ "$output" = "" ]
  [[ "$stderr" == "pc-oc: gpu: "* ]]
}
