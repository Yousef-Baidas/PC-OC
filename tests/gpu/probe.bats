#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

# gpu/probe.sh runs from a copied tree, inside in_ns (fixtures/apply/helper.bash): #127
# makes it call `/usr/bin/python3 -I gpu/nvml.py get` and systemctl, so the tree's nvml.py
# is the recording stub and mocks stand over /usr/bin/systemctl and /usr/bin/python3 in a
# private mount namespace, next to the nvidia-smi stub each case writes. apply.bats holds
# the harness cases that show the mocks are reached.
# Contract #142 adds a 17th key, offsets_source, and decides boot_unit=missing by the unit
# file the guard shows at /etc/systemd/system/pc-oc-gpu.service; systemctl cat is never
# called. The #127 cases that pinned 16 keys or a missing unit through systemctl are
# restated, each named "amended by #142".

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

# header_bytes: bytes= of line 1 of the last run, which must count 17 keys (16 before #142)
header_bytes() {
  [[ "${lines[0]}" =~ ^source=[^\ ]*nvidia-smi[^\ ]*\ bytes=([0-9]+)\ items=17$ ]] || return 1
  printf '%s\n' "${BASH_REMATCH[1]}"
}

# root_probe: pc-oc probe gpu as uid 0 in the guard (#142)
root_probe() {
  run --separate-stderr in_ns_root /usr/bin/bash "$REPO/pc-oc" probe gpu
}

# keys_17 <offsets_source>: the last run printed 17 key lines under a header that counts
# 17, the nine and the six as ever, boot_unit 16th and this offsets_source last
keys_17() {
  if [[ "$status" -eq 0 && "${#lines[@]}" -eq 18 && "${lines[0]}" == *" items=17" ]] &&
    [[ "${lines[1]}" == "gpu.name=NVIDIA GeForce RTX 4060 Ti" ]] &&
    [[ "${lines[15]}" == "gpu.offset_mem_p2=0" && "${lines[16]}" == gpu.boot_unit=* ]] &&
    [[ "${lines[17]}" == "gpu.offsets_source=$1" ]]; then
    return 0
  fi
  printf 'want offsets_source=%s last of 17 keys\nstatus %s\nstdout:\n%s\nstderr:\n%s\n' \
    "$1" "$status" "$output" "$stderr" >&2
  return 1
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

@test "#127 case 11, amended by #142: probe gpu prints the six offsets, boot_unit and offsets_source after the nine keys, 17 key lines in all, unsupported passed through" {
  skip "contract #142 pending"
  mixed_get
  run --separate-stderr in_ns bash "$PROBE"
  [ "$status" -eq 0 ]
  [ "$((${#lines[@]} - 1))" -eq 17 ]
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
  [ "${lines[17]}" = "gpu.offsets_source=values" ]
}

@test "#127 case 11, amended by #142: probe gpu prints boot_unit as enabled, disabled or missing and exits 0 for each; missing is the unit file gone, enabled and disabled are what is-enabled says" {
  skip "contract #142 pending"
  for state in enabled disabled missing; do
    tuned 150.00 0 0 "$state"
    run --separate-stderr in_ns bash "$PROBE"
    [ "$status" -eq 0 ]
    [ "${lines[10]}" = "gpu.offset_core_p0=0" ]
    [ "${lines[16]}" = "gpu.boot_unit=$state" ]
    [ "$((${#lines[@]} - 1))" -eq 17 ]
  done
  [ "$(logged "$IS_ENABLED")" -ge 2 ]
  [ "$(logged '^systemctl( .*)? cat( |$)')" -eq 0 ]
}

@test "#127 case 11: probe gpu exits 1 with its own pc-oc: gpu: line when a get line reads offset=abc" {
  mixed_get
  sed -i '1s/.*/p0.core offset=abc min=0 max=1/' "$MOCK_STATE/get"
  run --separate-stderr in_ns bash "$PROBE"
  [ "$status" -eq 1 ]
  [ "$output" = "" ]
  [ -n "$(own_messages)" ]
  [ "$(logged '^nvml get$')" -ge 1 ]
}

@test "#127: probe gpu exits 1 on each get line that is neither an integer offset nor unsupported, and on a missing line" {
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

@test "#127, amended by #142: probe gpu line 1 names nvidia-smi and one more source at least, 17 keys, and no fewer bytes than nvidia-smi and nvml.py get printed" {
  skip "contract #142 pending"
  mixed_get
  run --separate-stderr in_ns bash "$PROBE"
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" =~ ^source=([^\ ]+)\ bytes=([0-9]+)\ items=17$ ]]
  sources="${BASH_REMATCH[1]}"
  bytes="${BASH_REMATCH[2]}"
  [[ ",$sources," == *"nvidia-smi,"* ]]
  [[ "$sources" == *,* ]]
  [ "$bytes" -ge "$((${#FIELDS} + 1 + $(wc -c <"$MOCK_STATE/get")))" ]
}

@test "#127, amended by #142: probe gpu with nvidia-smi output lacking a trailing newline gives a bytes= one lower, with 17 keys counted" {
  skip "contract #142 pending"
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

@test "#127, amended by #142: probe gpu with nvidia-smi output ending in a blank line gives the 17 keys and a bytes= one higher" {
  skip "contract #142 pending"
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
  [ "$((${#lines[@]} - 1))" -eq 17 ]
  [[ "$output" == *$'\ngpu.pl_max_w=216.00'* ]]
}

# Worker cases for #127: what the contract leaves open and gpu/probe.sh settles.

@test "#127 own: probe gpu exits 1 on a repeated get line, a seventh line, a blank line and a number with a leading zero or a minus zero" {
  for bad in 'p0.core offset=120 min=-1000 max=1000' 'p3.mem offset=0 min=-2000 max=6000' '' 'p2.mem offset=007 min=-2000 max=6000' 'p2.mem offset=-0 min=-2000 max=6000'; do
    mixed_get
    # the first three are one line more with all six still there; the last two stand in
    # for line 6, which is p2.mem
    case "$bad" in
      p0.core* | p3.mem*) printf '%s\n' "$bad" >>"$MOCK_STATE/get" ;;
      '') sed -i '3G' "$MOCK_STATE/get" ;;
      *) sed -i "6s/.*/$bad/" "$MOCK_STATE/get" ;;
    esac
    [ "$(wc -l <"$MOCK_STATE/get")" -ge 6 ]
    run --separate-stderr in_ns bash "$PROBE"
    [ "$status" -eq 1 ]
    [ "$output" = "" ]
    [ -n "$(own_messages)" ]
  done
}

@test "#127 own, amended by #142: probe gpu with no search result names the nvidia-smi it ran and /usr/bin/python3 in line 1, 17 keys, and bytes= is what the two printed, to the byte" {
  skip "contract #142 pending"
  mixed_get
  run --separate-stderr in_ns bash "$PROBE"
  [ "$status" -eq 0 ]
  printed="$(($("$STUB_DIR/nvidia-smi" | wc -c) + $(wc -c <"$MOCK_STATE/get")))"
  [ "${lines[0]}" = "source=$STUB_DIR/nvidia-smi,/usr/bin/python3 bytes=$printed items=17" ]
}

# Contract #142: offsets_source says where an apply would take the two offsets from, and
# boot_unit=missing is the unit file's absence. The result is root's file, so the search
# state is probed as uid 0 in the guard (root_probe), with the result under the scratch
# /var/lib.

@test "#142 case 7: probe gpu prints offsets_source=values as its 17th and last key when there is no search result, as the user and as root" {
  skip "contract #142 pending"
  run --separate-stderr in_ns bash "$PROBE"
  keys_17 values
  root_probe
  keys_17 values
  # a search directory with a log and no result is no result path
  mkdir -p "${RESULT%/*}"
  printf '2026-10-02T09:00:00Z phase=core core=30 mem=0 result=pass reason=ok\n' >"${RESULT%/*}/log"
  root_probe
  keys_17 values
}

@test "#142 case 7: as root probe gpu prints offsets_source=search for a result apply would use, 210 and 1300 or 0 and 0, and leaves the result as it was" {
  skip "contract #142 pending"
  set_result 210 1300
  cp "$RESULT" "$BATS_TEST_TMPDIR/before"
  root_probe
  keys_17 search
  cmp "$RESULT" "$BATS_TEST_TMPDIR/before"
  run --separate-stderr in_ns_root /usr/bin/bash "$PROBE"
  keys_17 search
  set_result 0 0
  root_probe
  keys_17 search
  [ "$(logged '^nvml ')" -eq "$(logged '^nvml get$')" ]
  [ "$(logged "$SWITCH")" -eq 0 ]
}

@test "#142 case 7: as root probe gpu prints offsets_source=invalid and exits 0 for a result path apply would refuse: symlink, mode 0666, directory writable by others, missing key, key twice, bad number, no finished=, empty file, directory" {
  skip "contract #142 pending"
  set_result 210 1300
  mv "$RESULT" "${RESULT%/*}/real"
  ln -s "${RESULT%/*}/real" "$RESULT"
  root_probe
  keys_17 invalid
  ln -sfn "${RESULT%/*}/gone" "$RESULT"
  root_probe
  keys_17 invalid
  set_result 210 1300
  chmod 0666 "$RESULT"
  root_probe
  keys_17 invalid
  set_result 210 1300
  chmod 0777 "${RESULT%/*}"
  root_probe
  keys_17 invalid
  result_lines 'mem_offset_mhz=1300' 'finished=2026-10-02T09:14:07Z'
  root_probe
  keys_17 invalid
  result_lines 'core_offset_mhz=210' 'core_offset_mhz=210' 'mem_offset_mhz=1300' 'finished=2026-10-02T09:14:07Z'
  root_probe
  keys_17 invalid
  for bad in -30 030 12345; do
    result_lines 'core_offset_mhz=210' "mem_offset_mhz=$bad" 'finished=2026-10-02T09:14:07Z'
    root_probe
    keys_17 invalid
  done
  result_lines 'core_offset_mhz=210' 'mem_offset_mhz=1300'
  root_probe
  keys_17 invalid
  : >"$RESULT"
  root_probe
  keys_17 invalid
  rm "$RESULT"
  mkdir "$RESULT"
  root_probe
  keys_17 invalid
}

@test "#142 case 7: probe gpu as the calling user prints offsets_source=invalid for the result in its own state dir, which uid 0 does not own" {
  skip "contract #142 pending"
  RESULT="$USER_RESULT"
  set_result 210 1300
  run --separate-stderr in_ns bash "$PROBE"
  keys_17 invalid
}

@test "#142 case 7: probe gpu prints boot_unit=missing without a unit file even when systemctl answers for an enabled or a disabled unit, and never calls systemctl cat" {
  skip "contract #142 pending"
  for state in enabled disabled; do
    reset_logs
    tuned 150.00 0 0 "$state"
    unit_file absent
    run --separate-stderr in_ns bash "$PROBE"
    [ "$status" -eq 0 ]
    [ "${lines[16]}" = "gpu.boot_unit=missing" ]
    [ "$(logged '^systemctl( .*)? cat( |$)')" -eq 0 ]
    [ "$(logged '^nvml get$')" -eq 1 ]
  done
  root_probe
  [ "$status" -eq 0 ]
  [ "${lines[16]}" = "gpu.boot_unit=missing" ]
}

@test "#142 case 7: probe gpu with the unit file present, or a dangling symlink in its place, takes enabled or disabled from is-enabled alone: a systemctl that fails every call gives disabled, not missing" {
  skip "contract #142 pending"
  for file in present dangling; do
    reset_logs
    tuned 150.00 0 0 missing
    unit_file "$file"
    run --separate-stderr in_ns bash "$PROBE"
    [ "$status" -eq 0 ]
    [ "${lines[16]}" = "gpu.boot_unit=disabled" ]
    [ "$(logged "$IS_ENABLED")" -ge 1 ]
    [ "$(logged '^systemctl( .*)? cat( |$)')" -eq 0 ]
    tuned 150.00 0 0 enabled
    unit_file "$file"
    run --separate-stderr in_ns bash "$PROBE"
    [ "$status" -eq 0 ]
    [ "${lines[16]}" = "gpu.boot_unit=enabled" ]
  done
}

@test "#142 case 8: gpu/probe.sh names the unit file by the one path os/install.sh installs it to, with no variable in front" {
  skip "contract #142 pending"
  want="$(installed_unit_path)"
  [ "$want" = /etc/systemd/system/pc-oc-gpu.service ]
  [ "$(named_unit_paths "$BATS_TEST_DIRNAME/../../gpu/probe.sh")" = "$want" ]
}
