#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

# gpu/probe.sh runs from a copied tree, inside in_ns (fixtures/apply/helper.bash): #127
# makes it call `/usr/bin/python3 -I gpu/nvml.py get` and systemctl, so the tree's nvml.py
# is the recording stub and mocks stand over /usr/bin/systemctl and /usr/bin/python3 in a
# private mount namespace, next to the nvidia-smi stub each case writes. apply.bats holds
# the harness cases that show the mocks are reached.

load fixtures/apply/helper

setup() {
  gpu_tree
  PROBE="$REPO/gpu/probe.sh"
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

# set_get <line>...: what the stub's `nvml.py get` prints
set_get() {
  printf '%s\n' "$@" >"$MOCK_STATE/get"
}

# mixed_get: six get lines with a different answer per performance state
mixed_get() {
  set_get \
    'p0.core offset=120 min=-1000 max=1000' \
    'p0.mem offset=500 min=-2000 max=6000' \
    'p1.core offset=-15 min=-1000 max=1000' \
    'p1.mem unsupported' \
    'p2.core unsupported' \
    'p2.mem offset=0 min=-2000 max=6000'
}

# header_bytes: bytes= of line 1 of the last run, which must count 16 keys
header_bytes() {
  [[ "${lines[0]}" =~ ^source=[^\ ]*nvidia-smi[^\ ]*\ bytes=([0-9]+)\ items=16$ ]] || return 1
  printf '%s\n' "${BASH_REMATCH[1]}"
}

@test "probe gpu prints the power limit and its max among the nine nvidia-smi keys" {
  run --separate-stderr in_ns bash "$PROBE"
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
}

@test "probe gpu makes one nvidia-smi query-gpu call" {
  run --separate-stderr in_ns bash "$PROBE"
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$BATS_TEST_TMPDIR/calls")" -eq 1 ]
  [ "$(cat "$BATS_TEST_TMPDIR/calls")" = "--query-gpu=name,driver_version,vbios_version,power.limit,power.default_limit,power.min_limit,power.max_limit,clocks.max.graphics,clocks.max.memory --format=csv,noheader,nounits" ]
}

@test "probe gpu exits 1 with pc-oc: gpu: when nvidia-smi exits 9" {
  write_stub 9 ""
  run --separate-stderr in_ns bash "$PROBE"
  [ "$status" -eq 1 ]
  [ "$output" = "" ]
  [[ "$stderr" == "pc-oc: gpu: "* ]]
  [[ "$stderr" != *"not implemented"* ]]
}

@test "probe gpu exits 1 with pc-oc: gpu: when nvidia-smi prints 8 fields" {
  write_stub 0 'NVIDIA GeForce RTX 4060 Ti, 615.71.09, 95.06.1A.00.01, 160.00, 160.00, 100.00, 216.00, 3105'
  run --separate-stderr in_ns bash "$PROBE"
  [ "$status" -eq 1 ]
  [ "$output" = "" ]
  [[ "$stderr" == "pc-oc: gpu: "* ]]
  [[ "$stderr" != *"not implemented"* ]]
}

@test "probe gpu exits 1 with pc-oc: gpu: when nvidia-smi prints two GPU rows" {
  write_stub 0 "$FIELDS"$'\n'"$FIELDS"
  run --separate-stderr in_ns bash "$PROBE"
  [ "$status" -eq 1 ]
  [ "$output" = "" ]
  [[ "$stderr" == "pc-oc: gpu: "* ]]
}

@test "probe gpu exits 1 with pc-oc: gpu: when power.limit is [N/A]" {
  write_stub 0 'NVIDIA GeForce RTX 4060 Ti, 615.71.09, 95.06.1A.00.01, [N/A], 160.00, 100.00, 216.00, 3105, 9001'
  run --separate-stderr in_ns bash "$PROBE"
  [ "$status" -eq 1 ]
  [ "$output" = "" ]
  [[ "$stderr" == "pc-oc: gpu: "* ]]
}

# Contract #127: seven keys after the nine, from `nvml.py get` and the boot unit's state.
# The four cases that pinned 9 key lines, items=9 and bytes= equal to nvidia-smi's output
# alone are restated here for 16 keys and two more sources.

@test "#127 case 11: probe gpu prints the six offsets and boot_unit after the nine keys, 16 key lines in all, unsupported passed through" {
  skip "contract #127 pending"
  mixed_get
  run --separate-stderr in_ns bash "$PROBE"
  [ "$status" -eq 0 ]
  [ "$((${#lines[@]} - 1))" -eq 16 ]
  [ "${lines[1]}" = "gpu.name=NVIDIA GeForce RTX 4060 Ti" ]
  [ "${lines[4]}" = "gpu.pl_w=160.00" ]
  [ "${lines[9]}" = "gpu.mem_clock_max_mhz=9001" ]
  [ "${lines[10]}" = "gpu.offset_core_p0=120" ]
  [ "${lines[11]}" = "gpu.offset_core_p1=-15" ]
  [ "${lines[12]}" = "gpu.offset_core_p2=unsupported" ]
  [ "${lines[13]}" = "gpu.offset_mem_p0=500" ]
  [ "${lines[14]}" = "gpu.offset_mem_p1=unsupported" ]
  [ "${lines[15]}" = "gpu.offset_mem_p2=0" ]
  [ "${lines[16]}" = "gpu.boot_unit=disabled" ]
}

@test "#127 case 11: probe gpu prints boot_unit as enabled, disabled or missing and exits 0 for each" {
  skip "contract #127 pending"
  for state in enabled disabled missing; do
    printf '%s\n' "$state" >"$MOCK_STATE/unit"
    run --separate-stderr in_ns bash "$PROBE"
    [ "$status" -eq 0 ]
    [ "${lines[10]}" = "gpu.offset_core_p0=0" ]
    [ "${lines[16]}" = "gpu.boot_unit=$state" ]
    [ "$((${#lines[@]} - 1))" -eq 16 ]
  done
  [ "$(logged '^systemctl ')" -ge 3 ]
}

@test "#127 case 11: probe gpu exits 1 with its own pc-oc: gpu: line when a get line reads offset=abc" {
  skip "contract #127 pending"
  mixed_get
  sed -i '1s/.*/p0.core offset=abc min=0 max=1/' "$MOCK_STATE/get"
  run --separate-stderr in_ns bash "$PROBE"
  [ "$status" -eq 1 ]
  [ "$output" = "" ]
  [ -n "$(own_messages)" ]
  [ "$(logged '^nvml get$')" -ge 1 ]
}

@test "#127: probe gpu exits 1 on each get line that is neither an integer offset nor unsupported, and on a missing line" {
  skip "contract #127 pending"
  for bad in 'p1.mem offset= min=-2000 max=6000' 'p1.mem offset=1.5 min=-2000 max=6000' 'p1.mem offset=12abc min=-2000 max=6000' 'p1.mem' 'garbage'; do
    mixed_get
    sed -i "4s/.*/$bad/" "$MOCK_STATE/get"
    run --separate-stderr in_ns bash "$PROBE"
    [ "$status" -eq 1 ]
    [ "$output" = "" ]
    [ -n "$(own_messages)" ]
  done
  mixed_get
  sed -i '6d' "$MOCK_STATE/get"
  run --separate-stderr in_ns bash "$PROBE"
  [ "$status" -eq 1 ]
  [ "$output" = "" ]
  [ -n "$(own_messages)" ]
}

@test "#127: probe gpu exits 1 with its own pc-oc: gpu: line when nvml.py get exits 1" {
  skip "contract #127 pending"
  export MOCK_NVML='get=fail'
  run --separate-stderr in_ns bash "$PROBE"
  [ "$status" -eq 1 ]
  [ "$output" = "" ]
  [ -n "$(own_messages)" ]
  [ "$(logged '^nvml get$')" -ge 1 ]
  # six good lines and exit 1: the exit status alone says the read failed
  export MOCK_NVML='get=late'
  run --separate-stderr in_ns bash "$PROBE"
  [ "$status" -eq 1 ]
  [ "$output" = "" ]
  [ -n "$(own_messages)" ]
}

@test "#127: probe gpu only reads: the helper as /usr/bin/python3 -I <its own dir>/nvml.py get, no set, no zero, no enable, no disable" {
  skip "contract #127 pending"
  printf 'enabled\n' >"$MOCK_STATE/unit"
  printf '120 500\n' >"$MOCK_STATE/offsets"
  run --separate-stderr in_ns bash "$PROBE"
  [ "$status" -eq 0 ]
  [ "${lines[10]}" = "gpu.offset_core_p0=120" ]
  [ "${lines[13]}" = "gpu.offset_mem_p0=500" ]
  [ "$(logged '^nvml get$')" -ge 1 ]
  [ "$(logged '^nvml ')" -eq "$(logged '^nvml get$')" ]
  [ "$(logged '^systemctl ')" -ge 1 ]
  [ "$(logged "$SWITCH")" -eq 0 ]
  no_start "$MOCK_STATE/order"
  [ "$(sort -u "$MOCK_STATE/python3")" = "/usr/bin/python3 -I $(realpath "$REPO/gpu/nvml.py")" ]
  [ "$(cat "$MOCK_STATE/offsets")" = "120 500" ]
  [ "$(cat "$MOCK_STATE/unit")" = "enabled" ]
}

@test "#127: probe gpu line 1 names nvidia-smi and one more source at least, 16 keys, and no fewer bytes than nvidia-smi and nvml.py get printed" {
  skip "contract #127 pending"
  mixed_get
  run --separate-stderr in_ns bash "$PROBE"
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" =~ ^source=([^\ ]+)\ bytes=([0-9]+)\ items=16$ ]]
  sources="${BASH_REMATCH[1]}"
  bytes="${BASH_REMATCH[2]}"
  [[ ",$sources," == *"nvidia-smi,"* ]]
  [[ "$sources" == *,* ]]
  [ "$bytes" -ge "$((${#FIELDS} + 1 + $(wc -c <"$MOCK_STATE/get")))" ]
}

@test "#127: probe gpu with nvidia-smi output lacking a trailing newline gives a bytes= one lower" {
  skip "contract #127 pending"
  run --separate-stderr in_ns bash "$PROBE"
  [ "$status" -eq 0 ]
  with_newline="$(header_bytes)"
  cat >"$STUB_DIR/nvidia-smi" <<STUB
#!/usr/bin/env bash
printf '%s' '$FIELDS'
STUB
  real=$("$STUB_DIR/nvidia-smi" | wc -c)
  [ "$real" -eq "${#FIELDS}" ]
  run --separate-stderr in_ns bash "$PROBE"
  [ "$status" -eq 0 ]
  [ "$(header_bytes)" -eq "$((with_newline - 1))" ]
}

@test "#127: probe gpu with nvidia-smi output ending in a blank line gives the 16 keys and a bytes= one higher" {
  skip "contract #127 pending"
  run --separate-stderr in_ns bash "$PROBE"
  [ "$status" -eq 0 ]
  with_newline="$(header_bytes)"
  cat >"$STUB_DIR/nvidia-smi" <<STUB
#!/usr/bin/env bash
printf '%s\n\n' '$FIELDS'
STUB
  real=$("$STUB_DIR/nvidia-smi" | wc -c)
  [ "$real" -eq "$((${#FIELDS} + 2))" ]
  run --separate-stderr in_ns bash "$PROBE"
  [ "$status" -eq 0 ]
  [ "$(header_bytes)" -eq "$((with_newline + 1))" ]
  [ "$((${#lines[@]} - 1))" -eq 16 ]
  [[ "$output" == *$'\ngpu.pl_max_w=216.00'* ]]
}
