#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031 # bats runs each test in a subshell; exports are per test

bats_require_minimum_version 1.5.0

# Every run of gpu/apply.sh and gpu/revert.sh here goes through in_ns or in_ns_root
# (fixtures/apply/helper.bash): a private mount namespace where recording mocks stand over
# /usr/bin/nvidia-smi, /usr/bin/systemctl and /usr/bin/python3. #127 makes these scripts
# call systemctl and `/usr/bin/python3 -I gpu/nvml.py`, which a mock on PATH alone would
# not catch. The tree's gpu/nvml.py is a recording stub; NVML is never loaded.

load fixtures/apply/helper

setup() {
  gpu_tree
  ln -s "$MOCK_DIR/nvidia-smi" "$BATS_TEST_TMPDIR/bin/nvidia-smi"
}

# #127 case 15, for every case of this file: no apply may start the unit
teardown() {
  subid_restore
  no_start "$MOCK_STATE/order"
}

# set_pl <watts>: write the gpu/values file of the fake repo, both offsets 0
set_pl() {
  set_values "$1" 0 0
}

@test "apply gpu refuses pl_w 99 below the mocked min and logs no -pl" {
  set_pl 99
  run --separate-stderr in_ns bash "$REPO/gpu/apply.sh"
  [ "$status" -eq 1 ]
  [ "$stderr" = "pc-oc: gpu: pl_w 99 outside [100, 216]" ]
  [ ! -s "$MOCK_STATE/calls" ]
}

@test "apply gpu refuses pl_w 217 above the mocked max and logs no -pl" {
  set_pl 217
  run --separate-stderr in_ns bash "$REPO/gpu/apply.sh"
  [ "$status" -eq 1 ]
  [ "$stderr" = "pc-oc: gpu: pl_w 217 outside [100, 216]" ]
  [ ! -s "$MOCK_STATE/calls" ]
}

@test "apply gpu with pl_w 216 logs -pl 216 once and exits 0" {
  set_pl 216
  run --separate-stderr in_ns bash "$REPO/gpu/apply.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$MOCK_STATE/calls")" = "-pl 216" ]
  [ "$(cat "$MOCK_STATE/pl")" = "216.00" ]
}

@test "apply gpu exits 1 when the read-back differs because -pl was ignored" {
  ln -sf "$MOCK_DIR/nvidia-smi-ignore-pl" "$BATS_TEST_TMPDIR/bin/nvidia-smi"
  set_pl 216
  run --separate-stderr in_ns bash "$REPO/gpu/apply.sh"
  [ "$status" -eq 1 ]
  [[ "$stderr" == "pc-oc: gpu: "* ]]
  [[ "$stderr" != *"not implemented"* ]]
  [ "$(cat "$MOCK_STATE/calls")" = "-pl 216" ]
}

@test "apply then revert gpu logs -pl 150 and removes the snapshot" {
  set_pl 216
  run --separate-stderr in_ns bash "$REPO/gpu/apply.sh"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^gpu.pl_w=150' "$PC_OC_STATE/gpu/stock")" -eq 1 ]
  run --separate-stderr in_ns bash "$REPO/gpu/revert.sh"
  [ "$status" -eq 0 ]
  [ "$(tail -n 1 "$MOCK_STATE/calls")" = "-pl 150" ]
  [ "$(cat "$MOCK_STATE/pl")" = "150.00" ]
  [ ! -e "$PC_OC_STATE/gpu/stock" ]
}

@test "second apply gpu keeps the first snapshot" {
  set_pl 216
  run --separate-stderr in_ns bash "$REPO/gpu/apply.sh"
  [ "$status" -eq 0 ]
  cp "$PC_OC_STATE/gpu/stock" "$BATS_TEST_TMPDIR/first"
  set_pl 200
  run --separate-stderr in_ns bash "$REPO/gpu/apply.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$MOCK_STATE/pl")" = "200.00" ]
  cmp "$PC_OC_STATE/gpu/stock" "$BATS_TEST_TMPDIR/first"
  grep -q '^gpu.pl_w=150' "$PC_OC_STATE/gpu/stock"
}

@test "revert gpu with no snapshot says nothing to revert, exits 0 and logs no -pl" {
  run --separate-stderr in_ns bash "$REPO/gpu/revert.sh"
  [ "$status" -eq 0 ]
  [ "$stderr" = "pc-oc: gpu: nothing to revert" ]
  [ ! -s "$MOCK_STATE/calls" ]
}

@test "apply gpu refuses pl_w 0250 as non-canonical and logs no -pl" {
  set_pl 0250
  run --separate-stderr in_ns bash "$REPO/gpu/apply.sh"
  [ "$status" -eq 1 ]
  [[ "$stderr" == "pc-oc: gpu: "* ]]
  [[ "$stderr" != *"not implemented"* ]]
  [ ! -s "$MOCK_STATE/calls" ]
}

@test "apply gpu refuses pl_w 08 as non-canonical and logs no -pl" {
  set_pl 08
  run --separate-stderr in_ns bash "$REPO/gpu/apply.sh"
  [ "$status" -eq 1 ]
  [[ "$stderr" == "pc-oc: gpu: "* ]]
  [[ "$stderr" != *"not implemented"* ]]
  [ ! -s "$MOCK_STATE/calls" ]
}

@test "apply gpu refuses a 64-bit wrapping pl_w and logs no -pl" {
  set_pl 18446744073709551832
  run --separate-stderr in_ns bash "$REPO/gpu/apply.sh"
  [ "$status" -eq 1 ]
  [[ "$stderr" == "pc-oc: gpu: "* ]]
  [[ "$stderr" != *"not implemented"* ]]
  [ ! -s "$MOCK_STATE/calls" ]
}

@test "first apply gpu whose -pl fails exits 1 and leaves the state dir empty" {
  ln -sf "$MOCK_DIR/nvidia-smi-fail-pl" "$BATS_TEST_TMPDIR/bin/nvidia-smi"
  set_pl 216
  run --separate-stderr in_ns bash "$REPO/gpu/apply.sh"
  [ "$status" -eq 1 ]
  [[ "$stderr" == "pc-oc: gpu: "* ]]
  [[ "$stderr" != *"not implemented"* ]]
  [ "$(cat "$MOCK_STATE/calls")" = "-pl 216" ]
  [ -z "$(find "$PC_OC_STATE" -type f 2>/dev/null)" ]
}

@test "revert gpu whose read-back differs exits 1 and keeps the snapshot" {
  set_pl 216
  run --separate-stderr in_ns bash "$REPO/gpu/apply.sh"
  [ "$status" -eq 0 ]
  ln -sf "$MOCK_DIR/nvidia-smi-ignore-pl" "$BATS_TEST_TMPDIR/bin/nvidia-smi"
  run --separate-stderr in_ns bash "$REPO/gpu/revert.sh"
  [ "$status" -eq 1 ]
  [[ "$stderr" == "pc-oc: gpu: "* ]]
  [[ "$stderr" != *"not implemented"* ]]
  [ -f "$PC_OC_STATE/gpu/stock" ]
}

@test "apply gpu exits 1 when the read-back is 1 W off the request" {
  ln -sf "$MOCK_DIR/nvidia-smi-off-by-one" "$BATS_TEST_TMPDIR/bin/nvidia-smi"
  set_pl 200
  run --separate-stderr in_ns bash "$REPO/gpu/apply.sh"
  [ "$status" -eq 1 ]
  [[ "$stderr" == "pc-oc: gpu: "* ]]
  [ "$(cat "$MOCK_STATE/calls")" = "-pl 200" ]
  [ "$(cat "$MOCK_STATE/pl")" = "201.00" ]
}

@test "revert gpu with snapshot pl_w 300.00 above the mocked max exits 1, logs no -pl, keeps the snapshot" {
  set_snapshot 300.00
  run --separate-stderr in_ns bash "$REPO/gpu/revert.sh"
  [ "$status" -eq 1 ]
  [[ "$stderr" == "pc-oc: gpu: "* ]]
  [[ "$stderr" != *"not implemented"* ]]
  [ ! -s "$MOCK_STATE/calls" ]
  [ -f "$PC_OC_STATE/gpu/stock" ]
}

@test "revert gpu with snapshot pl_w 50.00 below the mocked min exits 1, logs no -pl, keeps the snapshot" {
  set_snapshot 50.00
  run --separate-stderr in_ns bash "$REPO/gpu/revert.sh"
  [ "$status" -eq 1 ]
  [[ "$stderr" == "pc-oc: gpu: "* ]]
  [ ! -s "$MOCK_STATE/calls" ]
  [ -f "$PC_OC_STATE/gpu/stock" ]
}

@test "apply then revert gpu leaves no gpu dir under the state dir" {
  set_pl 216
  run --separate-stderr in_ns bash "$REPO/gpu/apply.sh"
  [ "$status" -eq 0 ]
  run --separate-stderr in_ns bash "$REPO/gpu/revert.sh"
  [ "$status" -eq 0 ]
  [ ! -e "$PC_OC_STATE/gpu" ]
}

@test "revert gpu keeps a gpu state dir that still holds another file" {
  set_pl 216
  run --separate-stderr in_ns bash "$REPO/gpu/apply.sh"
  [ "$status" -eq 0 ]
  printf 'x\n' >"$PC_OC_STATE/gpu/other"
  run --separate-stderr in_ns bash "$REPO/gpu/revert.sh"
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

# The harness cases: the positive controls behind every "never called" below. They hold
# before and after #127, so they carry no skip.

@test "harness: in the guard a PATH of /usr/bin still lands nvidia-smi, systemctl and python3 -I gpu/nvml.py on the mocks" {
  # shellcheck disable=SC2016 # $1 is for the inner shell
  run --separate-stderr in_ns /usr/bin/env PATH=/usr/bin /usr/bin/bash -c \
    '/usr/bin/nvidia-smi --query-gpu=power.limit --format=csv,noheader,nounits &&
     /usr/bin/systemctl cat pc-oc-gpu.service >/dev/null &&
     /usr/bin/python3 -I "$1" get' _ "$REPO/gpu/nvml.py"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "150.00" ]
  [ "${lines[1]}" = "p0.core offset=0 min=-1000 max=1000" ]
  [ "${lines[6]}" = "p2.mem offset=0 min=-2000 max=6000" ]
  [ "${#lines[@]}" -eq 7 ]
  [ "$(cat "$MOCK_STATE/order")" = $'nvidia-smi --query-gpu=power.limit --format=csv,noheader,nounits\nsystemctl cat pc-oc-gpu.service\nnvml get' ]
  [ "$(cat "$MOCK_STATE/python3")" = "/usr/bin/python3 -I $(realpath "$REPO/gpu/nvml.py")" ]
}

@test "harness: the python3 mock runs nothing but -I <the stub>" {
  run --separate-stderr in_ns /usr/bin/python3 "$REPO/gpu/nvml.py" get
  [ "$status" -eq 96 ]
  run --separate-stderr in_ns /usr/bin/python3 -I "$REPO/gpu/apply.sh"
  [ "$status" -eq 96 ]
  run --separate-stderr in_ns /usr/bin/python3 -c 'print(1)'
  [ "$status" -eq 96 ]
  [ ! -s "$MOCK_STATE/order" ]
  [ "$(wc -l <"$MOCK_STATE/python3")" -eq 3 ]
}

@test "harness: the guard runs nothing when a mock is missing" {
  rm "$BATS_TEST_TMPDIR/bin/python3"
  run --separate-stderr in_ns /usr/bin/touch "$BATS_TEST_TMPDIR/ran"
  [ "$status" -eq 97 ]
  [ ! -e "$BATS_TEST_TMPDIR/ran" ]
}

@test "harness: as root in the guard pc-oc apply gpu reaches the nvidia-smi mock and keeps its snapshot in the scratch /var/lib" {
  set_pl 216
  run --separate-stderr in_ns_root /usr/bin/bash "$REPO/pc-oc" apply gpu
  [ "$status" -eq 0 ]
  [ "$(cat "$MOCK_STATE/calls")" = "-pl 216" ]
  grep -q '^gpu.pl_w=150' "$BATS_TEST_TMPDIR/varlib/pc-oc/gpu/stock"
  [ ! -e "$PC_OC_STATE" ]
}

@test "harness: the stub's term, hup and int actions each reach a gpu/apply.sh that traps them, in a subshell too" {
  # a stand-in apply: the helper call sits in a command substitution, so the stub's
  # nearest ancestor with this command line is a subshell, not the script
  cat >"$REPO/gpu/apply.sh" <<'FAKE'
trap 'echo got-TERM; exit 7' TERM
trap 'echo got-HUP; exit 7' HUP
trap 'echo got-INT; exit 7' INT
rows="$(
  /usr/bin/python3 -I "$(dirname "$0")/nvml.py" set core 5
  echo after
)"
echo not-reached "$rows"
FAKE
  for sig in TERM HUP INT; do
    rm -f "$MOCK_STATE/signalled"
    export MOCK_NVML="set core=${sig,,}"
    run --separate-stderr in_ns bash "$REPO/gpu/apply.sh"
    [ "$status" -eq 7 ]
    [ "$output" = "got-$sig" ]
    [[ "$(cat "$MOCK_STATE/signalled")" =~ ^$sig\ [0-9]+$ ]]
  done
}

@test "harness: the start check of case 15 trips on start, restart and --now, and on nothing else apply may call" {
  for line in "systemctl start pc-oc-gpu.service" "systemctl enable --now pc-oc-gpu.service" "systemctl --now enable pc-oc-gpu.service" "systemctl restart pc-oc-gpu.service"; do
    printf 'systemctl cat pc-oc-gpu.service\n%s\n' "$line" >"$BATS_TEST_TMPDIR/planted"
    run no_start "$BATS_TEST_TMPDIR/planted"
    [ "$status" -eq 1 ]
  done
  printf 'systemctl cat pc-oc-gpu.service\nsystemctl is-enabled --quiet pc-oc-gpu.service\nsystemctl enable pc-oc-gpu.service\n' >"$BATS_TEST_TMPDIR/planted"
  no_start "$BATS_TEST_TMPDIR/planted"
}

@test "harness: the systemctl mock's term, hup and int actions do the enable or the is-enabled and then reach a gpu/apply.sh that traps them, but not before set mem is logged" {
  # a stand-in apply: asks is-enabled before the offsets, as the snapshot's probe does,
  # then sets one offset, then calls the verb the case passes
  cat >"$REPO/gpu/apply.sh" <<'FAKE'
trap 'echo got-TERM; exit 7' TERM
trap 'echo got-HUP; exit 7' HUP
trap 'echo got-INT; exit 7' INT
systemctl is-enabled --quiet pc-oc-gpu.service
echo "early-$?"
/usr/bin/python3 -I "$(dirname "$0")/nvml.py" set mem 5 >/dev/null
systemctl "$@" pc-oc-gpu.service
echo not-reached
FAKE
  for sig in TERM HUP INT; do
    reset_logs
    printf 'disabled\n' >"$MOCK_STATE/unit"
    export MOCK_SYSTEMCTL="enable=${sig,,}"
    run --separate-stderr in_ns bash "$REPO/gpu/apply.sh" enable
    [ "$status" -eq 7 ]
    [ "$output" = "early-1"$'\n'"got-$sig" ]
    [[ "$(cat "$MOCK_STATE/signalled")" =~ ^$sig\ [0-9]+$ ]]
    [ "$(cat "$MOCK_STATE/unit")" = "enabled" ]

    reset_logs
    printf 'disabled\n' >"$MOCK_STATE/unit"
    export MOCK_SYSTEMCTL="is-enabled=${sig,,}"
    run --separate-stderr in_ns bash "$REPO/gpu/apply.sh" is-enabled --quiet
    [ "$status" -eq 7 ]
    [ "$output" = "early-1"$'\n'"got-$sig" ]
    [[ "$(cat "$MOCK_STATE/signalled")" =~ ^$sig\ [0-9]+$ ]]
    [ "$(logged "$IS_ENABLED")" -eq 2 ]
    [ "$(cat "$MOCK_STATE/unit")" = "disabled" ]
  done
  # a refused enable signals too, and changes nothing
  reset_logs
  printf 'disabled\n' >"$MOCK_STATE/unit"
  export MOCK_SYSTEMCTL='enable=term' MOCK_FAIL_ENABLE=1
  run --separate-stderr in_ns bash "$REPO/gpu/apply.sh" enable
  [ "$status" -eq 7 ]
  [[ "$(cat "$MOCK_STATE/signalled")" =~ ^TERM\ [0-9]+$ ]]
  [ "$(cat "$MOCK_STATE/unit")" = "disabled" ]
  # an entry the mock does not know is an error of the case, not a silent no-op
  export MOCK_SYSTEMCTL='enable=quit'
  run --separate-stderr in_ns /usr/bin/systemctl enable pc-oc-gpu.service
  [ "$status" -eq 94 ]
}

@test "harness: the systemctl mock logs stop and changes nothing on it, refuses it for a unit that is not installed or with MOCK_FAIL_STOP=1, and the start check does not trip on it" {
  for state in enabled disabled; do
    printf '%s\n' "$state" >"$MOCK_STATE/unit"
    run --separate-stderr in_ns /usr/bin/systemctl stop pc-oc-gpu.service
    [ "$status" -eq 0 ]
    [ -z "$output$stderr" ]
    [ "$(cat "$MOCK_STATE/unit")" = "$state" ]
  done
  export MOCK_FAIL_STOP=1
  run --separate-stderr in_ns /usr/bin/systemctl stop pc-oc-gpu.service
  [ "$status" -eq 1 ]
  [ "$stderr" = "mock systemctl: refused" ]
  unset MOCK_FAIL_STOP
  printf 'missing\n' >"$MOCK_STATE/unit"
  run --separate-stderr in_ns /usr/bin/systemctl stop pc-oc-gpu.service
  [ "$status" -eq 1 ]
  [ "$(logged '^systemctl stop pc-oc-gpu\.service$')" -eq 4 ]
  [ "$(wc -l <"$MOCK_STATE/order")" -eq 4 ]
  no_start "$MOCK_STATE/order"
  printf 'systemctl stop --now pc-oc-gpu.service\n' >"$BATS_TEST_TMPDIR/planted"
  run no_start "$BATS_TEST_TMPDIR/planted"
  [ "$status" -eq 1 ]
}

# Contract #127: gpu/apply.sh sets the clock offsets through nvml.py and enables the boot unit.

@test "#127 case 1: apply gpu with offsets 120 and 500 writes the limit, reads it back, sets core then mem, checks then enables the unit, and exits 0" {
  set_values 216 120 500
  run --separate-stderr in_ns bash "$REPO/gpu/apply.sh"
  [ "$status" -eq 0 ]
  want=$'nvidia-smi -pl 216\nnvidia-smi --query-gpu=power.limit --format=csv,noheader,nounits\nnvml set core 120\nnvml set mem 500\nsystemctl is-enabled --quiet pc-oc-gpu.service\nsystemctl enable pc-oc-gpu.service'
  [ "$(sed -n '/^nvidia-smi -pl /,$p' "$MOCK_STATE/order")" = "$want" ]
  [ "$(cat "$MOCK_STATE/pl")" = "216.00" ]
  [ "$(cat "$MOCK_STATE/offsets")" = "120 500" ]
  [ "$(cat "$MOCK_STATE/unit")" = "enabled" ]
}

@test "#127 case 2: apply gpu with both offsets 0 still calls set core 0 and set mem 0" {
  set_values 216 0 0
  run --separate-stderr in_ns bash "$REPO/gpu/apply.sh"
  [ "$status" -eq 0 ]
  [ "$(logged '^nvml set core 0$')" -eq 1 ]
  [ "$(logged '^nvml set mem 0$')" -eq 1 ]
  [ "$(logged '^nvml set ')" -eq 2 ]
}

@test "#127 case 3: apply gpu with the unit already enabled does not call enable" {
  set_values 216 120 500
  printf 'enabled\n' >"$MOCK_STATE/unit"
  run --separate-stderr in_ns bash "$REPO/gpu/apply.sh"
  [ "$status" -eq 0 ]
  # the snapshot's probe may ask too, so at least once
  [ "$(logged '^systemctl is-enabled --quiet pc-oc-gpu\.service$')" -ge 1 ]
  [ "$(logged "$ENABLE")" -eq 0 ]
  [ "$(cat "$MOCK_STATE/offsets")" = "120 500" ]
  [ "$(cat "$MOCK_STATE/unit")" = "enabled" ]
}

@test "#127 case 4: apply gpu with the unit not installed exits 1 naming os/install.sh, with no -pl, no helper call and no snapshot" {
  set_values 216 120 500
  printf 'missing\n' >"$MOCK_STATE/unit"
  run --separate-stderr in_ns bash "$REPO/gpu/apply.sh"
  [ "$status" -eq 1 ]
  grep -qxF 'pc-oc: gpu: boot unit not installed: run sudo os/install.sh' <<<"$stderr"
  [ "$(logged '^systemctl cat pc-oc-gpu\.service$')" -eq 1 ]
  [ ! -s "$MOCK_STATE/calls" ]
  [ "$(logged '^nvml ')" -eq 0 ]
  [ ! -s "$MOCK_STATE/python3" ]
  [ "$(logged "$SWITCH")" -eq 0 ]
  [ -z "$(find "$PC_OC_STATE" -type f 2>/dev/null)" ]
}

@test "#127: apply gpu asks systemctl cat for the unit before the first -pl" {
  set_values 216 120 500
  run --separate-stderr in_ns bash "$REPO/gpu/apply.sh"
  [ "$status" -eq 0 ]
  cat_at="$(line_of '^systemctl cat pc-oc-gpu\.service$')"
  pl_at="$(line_of '^nvidia-smi -pl ')"
  [ -n "$cat_at" ]
  [ "$cat_at" -lt "$pl_at" ]
}

@test "#127 case 5: apply gpu whose set mem exits 1 exits 1, names the memory offset, zeroes the offsets once and does not enable the unit" {
  set_values 216 120 500
  export MOCK_NVML='set mem=fail'
  run --separate-stderr in_ns bash "$REPO/gpu/apply.sh"
  [ "$status" -eq 1 ]
  [ "$(logged '^nvml set mem 500$')" -eq 1 ]
  [[ "$(own_messages)" == *mem* ]]
  [ "$(logged "$ENABLE")" -eq 0 ]
  [ "$(cat "$MOCK_STATE/unit")" = "disabled" ]
  # Amendment 1: zero once, after the failed set
  [ "$(logged '^nvml zero$')" -eq 1 ]
  [ "$(tail -n 1 <(grep '^nvml ' "$MOCK_STATE/order"))" = "nvml zero" ]
  [ "$(cat "$MOCK_STATE/offsets")" = "0 0" ]
}

@test "#127: apply gpu whose set core exits 1 exits 1, names the core offset, never calls set mem, zeroes once and does not enable the unit" {
  set_values 216 120 500
  export MOCK_NVML='set core=fail'
  run --separate-stderr in_ns bash "$REPO/gpu/apply.sh"
  [ "$status" -eq 1 ]
  [ "$(logged '^nvml set core 120$')" -eq 1 ]
  [[ "$(own_messages)" == *core* ]]
  [ "$(logged '^nvml set mem ')" -eq 0 ]
  [ "$(logged '^nvml zero$')" -eq 1 ]
  [ "$(logged "$ENABLE")" -eq 0 ]
}

@test "#127: apply gpu whose set mem fails keeps the stock snapshot, since the power limit was written" {
  set_values 216 120 500
  export MOCK_NVML='set mem=fail'
  run --separate-stderr in_ns bash "$REPO/gpu/apply.sh"
  [ "$status" -eq 1 ]
  [ "$(logged '^nvml set mem 500$')" -eq 1 ]
  [ "$(cat "$MOCK_STATE/pl")" = "216.00" ]
  grep -q '^gpu.pl_w=150' "$PC_OC_STATE/gpu/stock"
}

@test "#127: apply gpu whose power-limit read-back differs sets no offset and does not enable the unit" {
  ln -sf "$MOCK_DIR/nvidia-smi-ignore-pl" "$BATS_TEST_TMPDIR/bin/nvidia-smi"
  set_values 216 120 500
  run --separate-stderr in_ns bash "$REPO/gpu/apply.sh"
  [ "$status" -eq 1 ]
  [ "$(cat "$MOCK_STATE/calls")" = "-pl 216" ]
  [ "$(logged '^nvml set ')" -eq 0 ]
  [ "$(logged "$ENABLE")" -eq 0 ]
}

@test "#127: apply gpu whose enable fails exits 1 with its own pc-oc: gpu: line" {
  set_values 216 120 500
  export MOCK_FAIL_ENABLE=1
  run --separate-stderr in_ns bash "$REPO/gpu/apply.sh"
  [ "$status" -eq 1 ]
  [ "$(logged '^systemctl enable pc-oc-gpu\.service$')" -eq 1 ]
  [ -n "$(own_messages)" ]
  [ "$(cat "$MOCK_STATE/unit")" = "disabled" ]
}

# refused_values <key> <line>...: an apply over a values file of these lines dies naming
# <key> before any write
refused_values() {
  reset_logs
  printf '%s\n' "${@:2}" >"$REPO/gpu/values"
  run --separate-stderr in_ns bash "$REPO/gpu/apply.sh"
  [ "$status" -eq 1 ]
  [[ "$(own_messages)" == *"$1"* ]]
  [ ! -s "$MOCK_STATE/calls" ]
  [ "$(logged '^nvml (set|zero)')" -eq 0 ]
  [ "$(logged "$SWITCH")" -eq 0 ]
  [ -z "$(find "$PC_OC_STATE" -type f 2>/dev/null)" ]
}

@test "#127 case 6: apply gpu with no mem_offset_mhz in values exits 1 before any write" {
  refused_values mem_offset_mhz 'pl_w=216  # src: smi' 'core_offset_mhz=120  # src: nvml-offset-t'
  # the same harness does write once the file is whole
  set_values 216 120 500
  run --separate-stderr in_ns bash "$REPO/gpu/apply.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$MOCK_STATE/calls")" = "-pl 216" ]
}

@test "#127 case 6: apply gpu with core_offset_mhz=12a exits 1 before any write" {
  refused_values core_offset_mhz 'pl_w=216  # src: smi' 'core_offset_mhz=12a  # src: nvml-offset-t' 'mem_offset_mhz=500  # src: nvml-offset-t'
}

@test "#127 case 6: apply gpu refuses each offset that is not 0|[1-9][0-9]{0,3}, and a missing core_offset_mhz, before any write" {
  refused_values core_offset_mhz 'pl_w=216  # src: smi' 'mem_offset_mhz=500  # src: nvml-offset-t'
  for bad in 0500 -30 +30 12345 120.5 "" " 120" 0x10; do
    refused_values core_offset_mhz 'pl_w=216  # src: smi' "core_offset_mhz=$bad  # src: nvml-offset-t" 'mem_offset_mhz=500  # src: nvml-offset-t'
    refused_values mem_offset_mhz 'pl_w=216  # src: smi' 'core_offset_mhz=120  # src: nvml-offset-t' "mem_offset_mhz=$bad  # src: nvml-offset-t"
  done
}

@test "#127 case 13: apply gpu whose set mem is killed (137) calls zero once, exits 1 and does not enable the unit" {
  set_values 216 120 500
  export MOCK_NVML='set mem=kill'
  run --separate-stderr in_ns bash "$REPO/gpu/apply.sh"
  [ "$status" -eq 1 ]
  [ "$(logged '^nvml set mem 500$')" -eq 1 ]
  [ "$(logged '^nvml zero$')" -eq 1 ]
  [ "$(tail -n 1 <(grep '^nvml ' "$MOCK_STATE/order"))" = "nvml zero" ]
  [ "$(cat "$MOCK_STATE/offsets")" = "0 0" ]
  [ "$(logged "$ENABLE")" -eq 0 ]
  [ "$(cat "$MOCK_STATE/unit")" = "disabled" ]
}

@test "#127 amendment 1: apply gpu's message after a failed set differs with whether nvml.py zero exited 0" {
  set_values 216 120 500
  export MOCK_NVML='set mem=fail'
  run --separate-stderr in_ns bash "$REPO/gpu/apply.sh"
  [ "$status" -eq 1 ]
  [ "$(logged '^nvml zero$')" -eq 1 ]
  zeroed="$(own_messages)"
  reset_logs
  export MOCK_NVML='set mem=fail;zero=fail'
  run --separate-stderr in_ns bash "$REPO/gpu/apply.sh"
  [ "$status" -eq 1 ]
  [ "$(logged '^nvml zero$')" -ge 1 ]
  not_zeroed="$(own_messages)"
  [ -n "$zeroed" ]
  [ -n "$not_zeroed" ]
  [ "$zeroed" != "$not_zeroed" ]
}

# signalled <signal> <plan>: an apply that gets <signal> from the stub while <plan>'s set
# runs zeroes the offsets once, sets nothing after that, exits non-zero and leaves the
# unit alone
signalled() {
  reset_logs
  tuned 150.00 0 0 disabled
  set_values 216 120 500
  export MOCK_NVML="$2"
  run --separate-stderr in_ns bash "$REPO/gpu/apply.sh"
  [[ "$(cat "$MOCK_STATE/signalled")" =~ ^$1\ [0-9]+$ ]]
  [ "$status" -ne 0 ]
  [ "$(logged '^nvml zero$')" -eq 1 ]
  [ "$(tail -n 1 <(grep '^nvml ' "$MOCK_STATE/order"))" = "nvml zero" ]
  [ "$(cat "$MOCK_STATE/offsets")" = "0 0" ]
  [ "$(logged "$ENABLE")" -eq 0 ]
  [ "$(cat "$MOCK_STATE/unit")" = "disabled" ]
}

@test "#127 case 14: apply gpu that gets TERM during set core calls zero once, exits non-zero and does not enable the unit" {
  signalled TERM 'set core=term'
  [ "$(logged '^nvml set mem ')" -eq 0 ]
}

@test "#127 amendment 3: apply gpu that gets HUP or INT during a set, or TERM during set mem, does the same" {
  signalled HUP 'set core=hup'
  signalled INT 'set core=int'
  signalled TERM 'set mem=term'
  signalled HUP 'set mem=hup'
  signalled INT 'set mem=int'
}

@test "#127 amendment 3: apply gpu that gets TERM during the -pl write calls zero once, sets no offset, exits non-zero and does not enable the unit" {
  ln -sf "$MOCK_DIR/nvidia-smi-term-pl" "$BATS_TEST_TMPDIR/bin/nvidia-smi"
  set_values 216 120 500
  run --separate-stderr in_ns bash "$REPO/gpu/apply.sh"
  [[ "$(cat "$MOCK_STATE/signalled")" =~ ^TERM\ [0-9]+$ ]]
  [ "$status" -ne 0 ]
  [ "$(cat "$MOCK_STATE/calls")" = "-pl 216" ]
  [ "$(logged '^nvml zero$')" -eq 1 ]
  [ "$(logged '^nvml set ')" -eq 0 ]
  [ "$(logged "$ENABLE")" -eq 0 ]
}

@test "#127 amendment 3: apply gpu's message after TERM differs with whether nvml.py zero exited 0" {
  set_values 216 120 500
  export MOCK_NVML='set core=term'
  run --separate-stderr in_ns bash "$REPO/gpu/apply.sh"
  [ "$status" -ne 0 ]
  [ "$(logged '^nvml zero$')" -eq 1 ]
  zeroed="$(own_messages)"
  reset_logs
  export MOCK_NVML='set core=term;zero=fail'
  run --separate-stderr in_ns bash "$REPO/gpu/apply.sh"
  [ "$status" -ne 0 ]
  [ "$(logged '^nvml zero$')" -ge 1 ]
  not_zeroed="$(own_messages)"
  [ -n "$zeroed" ]
  [ -n "$not_zeroed" ]
  [ "$zeroed" != "$not_zeroed" ]
}

# Amendment 5: once set core and set mem have both exited 0 the apply is committed. TERM,
# HUP and INT are ignored from there to the end, and the back-out never runs after that.

# committed <signal> <verb>: an apply that gets <signal> from the systemctl mock during its
# own <verb> call, which comes after both sets, ends as an apply that got no signal: exit 0,
# the calls of case 1 and no other, both offsets as set, the unit enabled, no zero
committed() {
  reset_logs
  tuned 150.00 0 0 disabled
  set_values 216 120 500
  export MOCK_SYSTEMCTL="$2=${1,,}"
  run --separate-stderr in_ns bash "$REPO/gpu/apply.sh"
  [[ "$(cat "$MOCK_STATE/signalled")" =~ ^$1\ [0-9]+$ ]]
  [ "$status" -eq 0 ]
  [ "$(logged '^nvml zero$')" -eq 0 ]
  want=$'nvidia-smi -pl 216\nnvidia-smi --query-gpu=power.limit --format=csv,noheader,nounits\nnvml set core 120\nnvml set mem 500\nsystemctl is-enabled --quiet pc-oc-gpu.service\nsystemctl enable pc-oc-gpu.service'
  [ "$(sed -n '/^nvidia-smi -pl /,$p' "$MOCK_STATE/order")" = "$want" ]
  [ "$(cat "$MOCK_STATE/pl")" = "216.00" ]
  [ "$(cat "$MOCK_STATE/offsets")" = "120 500" ]
  [ "$(cat "$MOCK_STATE/unit")" = "enabled" ]
}

@test "#127 amendment 5: apply gpu that gets TERM during enable exits 0 with the unit enabled, both offsets as set and no zero call" {
  committed TERM enable
}

@test "#127 amendment 5: apply gpu that gets HUP during enable exits 0 with the unit enabled, both offsets as set and no zero call" {
  committed HUP enable
}

@test "#127 amendment 5: apply gpu that gets INT during enable exits 0 with the unit enabled, both offsets as set and no zero call" {
  committed INT enable
}

@test "#127 amendment 5: apply gpu that gets TERM, HUP or INT after set mem returned, while it asks is-enabled, still enables the unit, exits 0 and calls no zero" {
  committed TERM is-enabled
  committed HUP is-enabled
  committed INT is-enabled
}

@test "#127 amendment 5: apply gpu with the unit already enabled that gets TERM while it asks is-enabled exits 0 with both offsets as set, no zero and no enable" {
  tuned 150.00 0 0 enabled
  set_values 216 120 500
  export MOCK_SYSTEMCTL='is-enabled=term'
  run --separate-stderr in_ns bash "$REPO/gpu/apply.sh"
  [[ "$(cat "$MOCK_STATE/signalled")" =~ ^TERM\ [0-9]+$ ]]
  [ "$status" -eq 0 ]
  [ "$(logged '^nvml zero$')" -eq 0 ]
  [ "$(logged "$SWITCH")" -eq 0 ]
  [ "$(cat "$MOCK_STATE/offsets")" = "120 500" ]
  [ "$(cat "$MOCK_STATE/unit")" = "enabled" ]
}

@test "#127 amendment 5: apply gpu whose enable fails while TERM arrives ends as a failed enable without a signal: exit 1, the same message, both offsets left set, no zero" {
  set_values 216 120 500
  export MOCK_FAIL_ENABLE=1
  run --separate-stderr in_ns bash "$REPO/gpu/apply.sh"
  [ "$status" -eq 1 ]
  [ "$(logged '^systemctl enable pc-oc-gpu\.service$')" -eq 1 ]
  [ "$(logged '^nvml zero$')" -eq 0 ]
  [ "$(cat "$MOCK_STATE/offsets")" = "120 500" ]
  plain="$(own_messages)"
  [ -n "$plain" ]
  reset_logs
  tuned 150.00 0 0 disabled
  export MOCK_SYSTEMCTL='enable=term'
  run --separate-stderr in_ns bash "$REPO/gpu/apply.sh"
  [[ "$(cat "$MOCK_STATE/signalled")" =~ ^TERM\ [0-9]+$ ]]
  [ "$status" -eq 1 ]
  [ "$(logged '^systemctl enable pc-oc-gpu\.service$')" -eq 1 ]
  [ "$(logged '^nvml zero$')" -eq 0 ]
  [ "$(cat "$MOCK_STATE/offsets")" = "120 500" ]
  [ "$(cat "$MOCK_STATE/unit")" = "disabled" ]
  [ "$(own_messages)" = "$plain" ]
}

@test "#127 amendment 5: apply gpu with both offsets 0 and the unit disabled sets both to 0, then checks and enables the unit once, and exits 0" {
  tuned 150.00 120 500 disabled
  set_values 216 0 0
  run --separate-stderr in_ns bash "$REPO/gpu/apply.sh"
  [ "$status" -eq 0 ]
  want=$'nvidia-smi -pl 216\nnvidia-smi --query-gpu=power.limit --format=csv,noheader,nounits\nnvml set core 0\nnvml set mem 0\nsystemctl is-enabled --quiet pc-oc-gpu.service\nsystemctl enable pc-oc-gpu.service'
  [ "$(sed -n '/^nvidia-smi -pl /,$p' "$MOCK_STATE/order")" = "$want" ]
  [ "$(logged "$ENABLE")" -eq 1 ]
  [ "$(cat "$MOCK_STATE/offsets")" = "0 0" ]
  [ "$(cat "$MOCK_STATE/unit")" = "enabled" ]
}

@test "#127 case 15: no systemctl call of a first apply, a repeat apply, a failed apply or a signalled apply has start or --now in it" {
  set_values 216 120 500
  run --separate-stderr in_ns bash "$REPO/gpu/apply.sh"
  [ "$status" -eq 0 ]
  run --separate-stderr in_ns bash "$REPO/gpu/apply.sh"
  [ "$status" -eq 0 ]
  printf 'disabled\n' >"$MOCK_STATE/unit"
  export MOCK_NVML='set mem=fail'
  run --separate-stderr in_ns bash "$REPO/gpu/apply.sh"
  [ "$status" -eq 1 ]
  export MOCK_NVML='set core=term'
  run --separate-stderr in_ns bash "$REPO/gpu/apply.sh"
  [ "$status" -ne 0 ]
  unset MOCK_NVML
  export MOCK_FAIL_ENABLE=1
  run --separate-stderr in_ns bash "$REPO/gpu/apply.sh"
  [ "$status" -eq 1 ]
  # the mock was reached: one enable from the first apply, one refused in the last
  [ "$(logged '^systemctl enable pc-oc-gpu\.service$')" -eq 2 ]
  [ "$(logged '^systemctl cat pc-oc-gpu\.service$')" -ge 5 ]
  no_start "$MOCK_STATE/order"
}

@test "#127: apply gpu starts the helper as /usr/bin/python3 -I <its own dir>/nvml.py, every time" {
  set_values 216 120 500
  run --separate-stderr in_ns bash "$REPO/gpu/apply.sh"
  [ "$status" -eq 0 ]
  [ "$(logged '^nvml set ')" -eq 2 ]
  [ "$(sort -u "$MOCK_STATE/python3")" = "/usr/bin/python3 -I $(realpath "$REPO/gpu/nvml.py")" ]
}

@test "#127: as root pc-oc apply gpu then revert gpu set and clear the offsets and the unit through the /usr/bin mocks" {
  set_values 216 120 500
  stock="$BATS_TEST_TMPDIR/varlib/pc-oc/gpu/stock"
  run --separate-stderr in_ns_root /usr/bin/bash "$REPO/pc-oc" apply gpu
  [ "$status" -eq 0 ]
  [ "$(cat "$MOCK_STATE/pl")" = "216.00" ]
  [ "$(cat "$MOCK_STATE/offsets")" = "120 500" ]
  [ "$(cat "$MOCK_STATE/unit")" = "enabled" ]
  grep -qx 'gpu.pl_w=150.00' "$stock"
  grep -qx 'gpu.offset_core_p0=0' "$stock"
  grep -qx 'gpu.boot_unit=disabled' "$stock"
  run --separate-stderr in_ns_root /usr/bin/bash "$REPO/pc-oc" revert gpu
  [ "$status" -eq 0 ]
  [ "$(cat "$MOCK_STATE/pl")" = "150.00" ]
  [ "$(cat "$MOCK_STATE/offsets")" = "0 0" ]
  [ "$(cat "$MOCK_STATE/unit")" = "disabled" ]
  [ ! -e "$stock" ]
  [ "$(sort -u "$MOCK_STATE/python3")" = "/usr/bin/python3 -I $(realpath "$REPO/gpu/nvml.py")" ]
}

@test "#127 case 12: gpu/values has core_offset_mhz=0 and mem_offset_mhz=0, each citing an id of sources/manifest.tsv" {
  values="$BATS_TEST_DIRNAME/../../gpu/values"
  manifest="$BATS_TEST_DIRNAME/../../sources/manifest.tsv"
  for key in core_offset_mhz mem_offset_mhz; do
    [ "$(grep -c -E "^$key=" "$values")" -eq 1 ]
    line="$(grep -E "^$key=" "$values")"
    [[ "$line" =~ ^$key=0[[:space:]] ]]
    cite="$(grep -o '# src:[ a-z0-9,-]*' <<<"$line")"
    IFS=', ' read -r -a ids <<<"${cite#'# src:'}"
    [ "${#ids[@]}" -ge 1 ]
    for id in "${ids[@]}"; do
      cut -f1 "$manifest" | grep -qxF -- "$id"
    done
  done
}

# Worker cases for #127: what the contract leaves open and gpu/apply.sh settles.

@test "#127 own: apply gpu that gets TERM exits 1 with one line of its own naming TERM, and keeps the snapshot of the limit it wrote" {
  set_values 216 120 500
  export MOCK_NVML='set core=term'
  run --separate-stderr in_ns bash "$REPO/gpu/apply.sh"
  [ "$status" -eq 1 ]
  [ "$(own_messages)" = "pc-oc: gpu: got TERM; clock offsets zeroed, boot unit left as it was" ]
  [ "$(cat "$MOCK_STATE/pl")" = "216.00" ]
  grep -q '^gpu.pl_w=150' "$PC_OC_STATE/gpu/stock"
}

@test "#127 own: apply gpu whose set mem dies of the TERM that reaches apply too calls zero once, not once per reason" {
  # systemd signals every process of the unit: the helper ends with 143 and apply gets
  # the same TERM, so the trap and the failed-set branch both want the zero
  cat >"$REPO/gpu/nvml.py" <<'STUB'
#!/usr/bin/env bash
# pc-oc-test-mock
if [[ "$*" == "set mem "* ]]; then
  printf 'nvml %s\n' "$*" >>"$MOCK_STATE/order"
  source "$MOCK_DIR/signal.bash"
  signal_apply TERM
  exit 143
fi
exec /usr/bin/bash "$MOCK_DIR/nvml-stub.bash" "$@"
STUB
  set_values 216 120 500
  run --separate-stderr in_ns bash "$REPO/gpu/apply.sh"
  [[ "$(cat "$MOCK_STATE/signalled")" =~ ^TERM\ [0-9]+$ ]]
  [ "$status" -eq 1 ]
  [ "$(logged '^nvml set mem 500$')" -eq 1 ]
  [ "$(logged '^nvml zero$')" -eq 1 ]
  [ "$(tail -n 1 <(grep '^nvml ' "$MOCK_STATE/order"))" = "nvml zero" ]
  [ "$(cat "$MOCK_STATE/offsets")" = "0 0" ]
  [ "$(own_messages | wc -l)" -eq 1 ]
  [ "$(logged "$ENABLE")" -eq 0 ]
}

@test "#127 own: apply gpu whose power-limit read-back dies of the TERM that reaches apply too still calls zero once and sets no offset" {
  rm "$BATS_TEST_TMPDIR/bin/nvidia-smi"
  cat >"$BATS_TEST_TMPDIR/bin/nvidia-smi" <<'MOCK'
#!/usr/bin/env bash
if [[ "$*" == "--query-gpu=power.limit "* ]]; then
  printf 'nvidia-smi %s\n' "$*" >>"$MOCK_STATE/order"
  source "$MOCK_DIR/signal.bash"
  signal_apply TERM
  exit 143
fi
exec "$MOCK_DIR/nvidia-smi" "$@"
MOCK
  chmod +x "$BATS_TEST_TMPDIR/bin/nvidia-smi"
  set_values 216 120 500
  run --separate-stderr in_ns bash "$REPO/gpu/apply.sh"
  [[ "$(cat "$MOCK_STATE/signalled")" =~ ^TERM\ [0-9]+$ ]]
  [ "$status" -eq 1 ]
  [ "$(cat "$MOCK_STATE/calls")" = "-pl 216" ]
  [ "$(logged '^nvml zero$')" -eq 1 ]
  [ "$(logged '^nvml set ')" -eq 0 ]
  [ "$(own_messages)" = "pc-oc: gpu: got TERM; clock offsets zeroed, boot unit left as it was" ]
  [ "$(logged "$ENABLE")" -eq 0 ]
}

@test "#127 own: apply gpu whose -pl fails or reads back wrong calls no nvml zero: only a set or a signal is followed by one" {
  for mock in nvidia-smi-fail-pl nvidia-smi-ignore-pl; do
    reset_logs
    ln -sf "$MOCK_DIR/$mock" "$BATS_TEST_TMPDIR/bin/nvidia-smi"
    tuned 150.00 120 500 disabled
    set_values 216 120 500
    run --separate-stderr in_ns bash "$REPO/gpu/apply.sh"
    [ "$status" -eq 1 ]
    [ "$(cat "$MOCK_STATE/calls")" = "-pl 216" ]
    [ "$(logged '^nvml (set|zero)')" -eq 0 ]
    [ "$(cat "$MOCK_STATE/offsets")" = "120 500" ]
  done
}

@test "#127 own: apply gpu whose enable fails leaves the offsets it set and says they will not be set again at boot" {
  set_values 216 120 500
  export MOCK_FAIL_ENABLE=1
  run --separate-stderr in_ns bash "$REPO/gpu/apply.sh"
  [ "$status" -eq 1 ]
  [ "$(logged '^nvml zero$')" -eq 0 ]
  [ "$(cat "$MOCK_STATE/offsets")" = "120 500" ]
  [[ "$(own_messages)" == *"cannot enable pc-oc-gpu.service"*"boot"* ]]
}

# Contract #142: gpu/apply.sh takes the two offsets from the search result of #135 when a
# result path exists, and from gpu/values only when none does. The result is root's file
# ($(pc_oc_state)/gpu/search/result with uid 0), so the cases that use one run pc-oc apply
# gpu as uid 0 in the guard (root_apply), with the result under the scratch /var/lib.
# The #127 cases above that pin `systemctl cat` for apply stand as they are: the ticket
# changes revert and probe there, not apply.

# want_calls <core> <mem>: every call from the power-limit write on, for pl_w 216
want_calls() {
  printf '%s\n' 'nvidia-smi -pl 216' \
    'nvidia-smi --query-gpu=power.limit --format=csv,noheader,nounits' \
    "nvml set core $1" "nvml set mem $2" \
    'systemctl is-enabled --quiet pc-oc-gpu.service' 'systemctl enable pc-oc-gpu.service'
}

# root_apply: pc-oc apply gpu as uid 0 in the guard
root_apply() {
  run --separate-stderr in_ns_root /usr/bin/bash "$REPO/pc-oc" apply gpu
}

# refused <what>: the last run was an apply that refused the result path: exit 1 with a
# line of its own and nothing written, which is no -pl, no set, no zero, no enable and no
# snapshot. gpu/values holds 120 and 500 in these cases, so a fall-back to it would show
# as a set call.
refused() {
  if [[ "$status" -eq 1 && -n "$(own_messages)" && ! -s "$MOCK_STATE/calls" ]] &&
    [[ "$(logged '^nvml (set|zero)')" -eq 0 && "$(logged "$SWITCH")" -eq 0 ]] &&
    [[ "$(<"$MOCK_STATE/unit")" == disabled && "$(<"$MOCK_STATE/offsets")" == "0 0" ]] &&
    [[ ! -e "$BATS_TEST_TMPDIR/varlib/pc-oc/gpu/stock" && ! -e "$PC_OC_STATE/gpu/stock" ]]; then
    return 0
  fi
  printf 'not refused: %s\nstatus %s\nstdout: %s\nstderr: %s\ncalls:\n%s\n' \
    "$1" "$status" "$output" "$stderr" "$(<"$MOCK_STATE/order")" >&2
  return 1
}

@test "#142 harness: in the guard /etc/systemd/system is the test's unit directory, as the user and as root, and the host's is not touched" {
  # shellcheck disable=SC2016 # $1 is for the inner shell
  for ns in in_ns in_ns_root; do
    unit_file present
    run --separate-stderr "$ns" /usr/bin/bash -c \
      '[[ -e /etc/systemd/system/.pc-oc-test-mock && -f "$1" && ! -L "$1" ]]' _ \
      /etc/systemd/system/pc-oc-gpu.service
    [ "$status" -eq 0 ]
    unit_file absent
    run --separate-stderr "$ns" /usr/bin/bash -c '[[ ! -e "$1" && ! -L "$1" ]]' _ \
      /etc/systemd/system/pc-oc-gpu.service
    [ "$status" -eq 0 ]
    unit_file dangling
    run --separate-stderr "$ns" /usr/bin/bash -c '[[ ! -e "$1" && -L "$1" ]]' _ \
      /etc/systemd/system/pc-oc-gpu.service
    [ "$status" -eq 0 ]
  done
  [ ! -e /etc/systemd/system/.pc-oc-test-mock ]
}

@test "#142 harness: the guard runs nothing when the unit directory is not a test's, as the user and as root" {
  rm "$BATS_TEST_TMPDIR/units/.pc-oc-test-mock"
  run --separate-stderr in_ns /usr/bin/touch "$BATS_TEST_TMPDIR/ran"
  [ "$status" -eq 97 ]
  run --separate-stderr in_ns_root /usr/bin/touch "$BATS_TEST_TMPDIR/ran"
  [ "$status" -eq 97 ]
  [ ! -e "$BATS_TEST_TMPDIR/ran" ]
}

@test "#142 harness: to uid 0 in the guard a result of set_result is uid 0's file, mode 644 in a 755 directory of uid 0; after subid_chown its owner is another uid, and subid_restore gives it back" {
  set_result 210 1300
  run --separate-stderr in_ns_root /usr/bin/stat -c '%F %u %a' "$RESULT" "${RESULT%/*}"
  [ "$status" -eq 0 ]
  [ "$output" = $'regular file 0 644\ndirectory 0 755' ]
  subid_chown "$RESULT"
  subid_chown "${RESULT%/*}"
  run --separate-stderr in_ns_root /usr/bin/stat -c '%u' "$RESULT" "${RESULT%/*}"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" != 0 ]
  [ "${lines[1]}" != 0 ]
  [ "$(stat -c '%u' "$RESULT")" != "$(id -u)" ]
  # root of the guard can still read it, so a refusal is the owner check and not a failed read
  run --separate-stderr in_ns_root /usr/bin/cat "$RESULT"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "core_offset_mhz=210" ]
  subid_restore
  [ "$(stat -c '%u' "$RESULT" "${RESULT%/*}" | sort -u)" = "$(id -u)" ]
}

@test "#142 case 1: as root apply gpu with a search result of 210 and 1300 writes the limit of gpu/values, sets core 210 then mem 1300, never the 120 and 500 of gpu/values, enables the unit and prints the source line" {
  set_values 216 120 500
  set_result 210 1300
  root_apply
  [ "$status" -eq 0 ]
  [ "$(sed -n '/^nvidia-smi -pl /,$p' "$MOCK_STATE/order")" = "$(want_calls 210 1300)" ]
  [ "$(logged '^nvml set ')" -eq 2 ]
  [ "$(cat "$MOCK_STATE/pl")" = "216.00" ]
  [ "$(cat "$MOCK_STATE/offsets")" = "210 1300" ]
  [ "$(cat "$MOCK_STATE/unit")" = "enabled" ]
  [ "$output" = "gpu: offsets core=210 mem=1300 from search result" ]
}

@test "#142 case 1: gpu/apply.sh started as uid 0 without pc-oc adopts the result the same way" {
  set_values 216 120 500
  set_result 210 1300
  run --separate-stderr in_ns_root /usr/bin/bash "$REPO/gpu/apply.sh"
  [ "$status" -eq 0 ]
  [ "$(sed -n '/^nvidia-smi -pl /,$p' "$MOCK_STATE/order")" = "$(want_calls 210 1300)" ]
  [ "$output" = "gpu: offsets core=210 mem=1300 from search result" ]
}

@test "#142 case 1: a second apply with the result still there sets 210 and 1300 again, prints the same line and does not call enable" {
  set_values 216 120 500
  set_result 210 1300
  root_apply
  [ "$status" -eq 0 ]
  reset_logs
  root_apply
  [ "$status" -eq 0 ]
  [ "$(logged '^nvml set core 210$')" -eq 1 ]
  [ "$(logged '^nvml set mem 1300$')" -eq 1 ]
  [ "$(logged '^nvml set ')" -eq 2 ]
  [ "$(logged "$ENABLE")" -eq 0 ]
  [ "$(cat "$MOCK_STATE/unit")" = "enabled" ]
  [ "$output" = "gpu: offsets core=210 mem=1300 from search result" ]
}

@test "#142 case 1: apply gpu leaves the result it adopted byte for byte as it was" {
  set_values 216 120 500
  set_result 210 1300
  cp "$RESULT" "$BATS_TEST_TMPDIR/before"
  root_apply
  [ "$status" -eq 0 ]
  [ "$(cat "$MOCK_STATE/offsets")" = "210 1300" ]
  cmp "$RESULT" "$BATS_TEST_TMPDIR/before"
  [ "$(stat -c '%F %a' "$RESULT")" = "regular file 644" ]
}

@test "#142 case 2: apply gpu with no search result makes the calls of #127 for the 0 and 0 of gpu/values and names gpu/values as the source" {
  set_values 216 0 0
  run --separate-stderr in_ns bash "$REPO/gpu/apply.sh"
  [ "$status" -eq 0 ]
  [ "$(sed -n '/^nvidia-smi -pl /,$p' "$MOCK_STATE/order")" = "$(want_calls 0 0)" ]
  [ "$(cat "$MOCK_STATE/offsets")" = "0 0" ]
  [ "$(cat "$MOCK_STATE/unit")" = "enabled" ]
  [ "$output" = "gpu: offsets core=0 mem=0 from gpu/values" ]
}

@test "#142 case 2: as root apply gpu with no search result does the same" {
  set_values 216 0 0
  root_apply
  [ "$status" -eq 0 ]
  [ "$(sed -n '/^nvidia-smi -pl /,$p' "$MOCK_STATE/order")" = "$(want_calls 0 0)" ]
  [ "$(cat "$MOCK_STATE/unit")" = "enabled" ]
  [ "$output" = "gpu: offsets core=0 mem=0 from gpu/values" ]
}

@test "#142 case 2: the source line carries the numbers gpu/values gave: core=120 mem=500 from gpu/values" {
  set_values 216 120 500
  run --separate-stderr in_ns bash "$REPO/gpu/apply.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$MOCK_STATE/offsets")" = "120 500" ]
  [ "$output" = "gpu: offsets core=120 mem=500 from gpu/values" ]
}

@test "#142 case 2: as root a search directory that holds a log and no result is no result path: gpu/values is used" {
  set_values 216 120 500
  mkdir -p "${RESULT%/*}"
  printf '2026-10-02T09:00:00Z phase=core core=30 mem=0 result=pass reason=ok\n' >"${RESULT%/*}/log"
  root_apply
  [ "$status" -eq 0 ]
  [ "$(sed -n '/^nvidia-smi -pl /,$p' "$MOCK_STATE/order")" = "$(want_calls 120 500)" ]
  [ "$output" = "gpu: offsets core=120 mem=500 from gpu/values" ]
}

@test "#142 case 3: as root apply gpu refuses a result path that is a symlink, to a result root owns or to nothing" {
  set_values 216 120 500
  set_result 210 1300
  mv "$RESULT" "${RESULT%/*}/real"
  ln -s "${RESULT%/*}/real" "$RESULT"
  root_apply
  refused "symlink to a good result"
  ln -sfn "${RESULT%/*}/gone" "$RESULT"
  root_apply
  refused "dangling symlink"
}

@test "#142 case 3: as root apply gpu refuses a result whose owner is not uid 0" {
  set_values 216 120 500
  set_result 210 1300
  subid_chown "$RESULT"
  root_apply
  refused "result of another uid"
}

@test "#142 case 3: apply gpu as the calling user refuses the result in its own state dir, which that user owns" {
  set_values 216 120 500
  RESULT="$USER_RESULT"
  set_result 210 1300
  [ "$(stat -c '%u' "$RESULT")" = "$(id -u)" ]
  run --separate-stderr in_ns bash "$REPO/gpu/apply.sh"
  refused "result of the calling user"
}

@test "#142 case 3: as root apply gpu refuses a result of mode 0666, 0664 or 0646" {
  set_values 216 120 500
  for mode in 0666 0664 0646; do
    set_result 210 1300
    chmod "$mode" "$RESULT"
    root_apply
    refused "result of mode $mode"
  done
}

@test "#142 case 3: as root apply gpu refuses a result whose directory is writable by others or by the group: 0777, 1777, 0775, 0757" {
  set_values 216 120 500
  for mode in 0777 1777 0775 0757; do
    set_result 210 1300
    chmod "$mode" "${RESULT%/*}"
    root_apply
    refused "directory of mode $mode"
  done
}

@test "#142 case 3: as root apply gpu refuses a result whose directory is not uid 0's" {
  set_values 216 120 500
  set_result 210 1300
  subid_chown "${RESULT%/*}"
  root_apply
  refused "directory of another uid"
}

@test "#142 case 3: as root apply gpu refuses a result without core_offset_mhz, and one without mem_offset_mhz" {
  set_values 216 120 500
  result_lines 'mem_offset_mhz=1300' 'finished=2026-10-02T09:14:07Z'
  root_apply
  refused "no core_offset_mhz"
  result_lines 'core_offset_mhz=210' 'finished=2026-10-02T09:14:07Z'
  root_apply
  refused "no mem_offset_mhz"
}

@test "#142 case 3: as root apply gpu refuses a result that has a key twice, with the same number or another" {
  set_values 216 120 500
  result_lines 'core_offset_mhz=210' 'core_offset_mhz=210' 'mem_offset_mhz=1300' 'finished=2026-10-02T09:14:07Z'
  root_apply
  refused "core_offset_mhz=210 twice"
  result_lines 'core_offset_mhz=210' 'mem_offset_mhz=1300' 'core_offset_mhz=30' 'finished=2026-10-02T09:14:07Z'
  root_apply
  refused "core_offset_mhz twice, 210 and 30"
  result_lines 'core_offset_mhz=210' 'mem_offset_mhz=1300' 'mem_offset_mhz=1300' 'finished=2026-10-02T09:14:07Z'
  root_apply
  refused "mem_offset_mhz twice"
}

@test "#142 case 3: as root apply gpu refuses a result whose core or mem number is -30, 030, 12345 or anything else that is not 0|[1-9][0-9]{0,3}" {
  set_values 216 120 500
  for bad in -30 030 12345 +30 12a 1.5 ''; do
    result_lines "core_offset_mhz=$bad" 'mem_offset_mhz=1300' 'finished=2026-10-02T09:14:07Z'
    root_apply
    refused "core_offset_mhz=$bad"
    result_lines 'core_offset_mhz=210' "mem_offset_mhz=$bad" 'finished=2026-10-02T09:14:07Z'
    root_apply
    refused "mem_offset_mhz=$bad"
  done
}

@test "#142 case 3: as root apply gpu refuses a result without a finished= line" {
  set_values 216 120 500
  result_lines 'core_offset_mhz=210' 'mem_offset_mhz=1300'
  root_apply
  refused "no finished="
}

@test "#142 case 3: as root apply gpu refuses an empty result" {
  set_values 216 120 500
  set_result 210 1300
  : >"$RESULT"
  root_apply
  refused "empty file"
}

@test "#142 case 3: as root apply gpu refuses a directory at the result path" {
  set_values 216 120 500
  mkdir -p "$RESULT"
  root_apply
  refused "directory at the path"
}

@test "#142 case 3: a refused result does not turn an enabled unit off or zero offsets that are set" {
  set_values 216 120 500
  tuned 216.00 210 1300 enabled
  result_lines 'core_offset_mhz=-30' 'mem_offset_mhz=1300' 'finished=2026-10-02T09:14:07Z'
  root_apply
  [ "$status" -eq 1 ]
  [ -n "$(own_messages)" ]
  [ ! -s "$MOCK_STATE/calls" ]
  [ "$(logged '^nvml (set|zero)')" -eq 0 ]
  [ "$(logged "$SWITCH")" -eq 0 ]
  [ "$(cat "$MOCK_STATE/offsets")" = "210 1300" ]
  [ "$(cat "$MOCK_STATE/unit")" = "enabled" ]
}

@test "#142 case 4: as root apply gpu with a search result of 0 and 0 sets both to 0, enables the unit and names the search result, with 120 and 500 in gpu/values" {
  set_values 216 120 500
  tuned 150.00 120 500 disabled
  set_result 0 0
  root_apply
  [ "$status" -eq 0 ]
  [ "$(sed -n '/^nvidia-smi -pl /,$p' "$MOCK_STATE/order")" = "$(want_calls 0 0)" ]
  [ "$(cat "$MOCK_STATE/offsets")" = "0 0" ]
  [ "$(cat "$MOCK_STATE/unit")" = "enabled" ]
  [ "$output" = "gpu: offsets core=0 mem=0 from search result" ]
}

@test "#142 case 10: gpu/offsets.md puts pc-oc apply gpu after pc-oc search gpu, names offsets_source=search and has no follow-up ticket left in it" {
  doc="$BATS_TEST_DIRNAME/../../gpu/offsets.md"
  [ -e "$doc" ] || skip "gpu/offsets.md is not on this branch: #135 writes it"
  search_at="$(grep -n -F 'pc-oc search gpu' "$doc" | tail -n 1 | cut -d: -f1)"
  apply_at="$(grep -n -F 'pc-oc apply gpu' "$doc" | tail -n 1 | cut -d: -f1)"
  [ -n "$search_at" ]
  [ -n "$apply_at" ]
  [ "$search_at" -lt "$apply_at" ]
  grep -qF 'offsets_source=search' "$doc"
  [ "$(grep -c -i -F 'follow-up ticket' "$doc" || :)" -eq 0 ]
}

# Worker cases for #142: what the contract leaves open and gpu/apply.sh settles. One case
# per rule of its own that refuses. pc-oc adds a line of its own when apply.sh fails, so
# these cases name the words of the refusal and do not rely on own_messages being non-empty.

# why <words>: the last run's stderr holds one pc-oc: gpu: line with these words
why() {
  [[ "$(own_messages | grep -c -F -- "$1")" -ne 1 ]] || return 0
  printf 'no line with: %s\nstderr: %s\n' "$1" "$stderr" >&2
  return 1
}

# fresh: the card at stock, the unit disabled, no snapshot and empty logs, for a case that
# applies more than once
fresh() {
  tuned 150.00 0 0 disabled
  rm -rf "$BATS_TEST_TMPDIR/varlib/pc-oc/gpu/stock" "$PC_OC_STATE"
  reset_logs
}

# CALLER_ENVS: what a caller may leave in the environment, one env(1) argument each; none
# of it may change what apply does
CALLER_ENVS=('IFS=0123456789=_ms' 'POSIXLY_CORRECT=1' 'TMPDIR=/nonexistent/pc-oc-142'
  'SHELLOPTS=noglob:posix:physical' 'CDPATH=/etc' 'GLOBIGNORE=*')

@test "#142 own: search_result is the same text in gpu/apply.sh and gpu/probe.sh, comment and shellcheck directive included, and each calls it once on the result under its state dir" {
  for name in apply probe; do
    sed -n '/^# search_result <path>:/,/^}$/p' "$BATS_TEST_DIRNAME/../../gpu/$name.sh" >"$BATS_TEST_TMPDIR/$name.fn"
    [ "$(grep -c -x 'search_result() {' "$BATS_TEST_TMPDIR/$name.fn")" -eq 1 ]
    [ "$(tail -n 1 "$BATS_TEST_TMPDIR/$name.fn")" = "}" ]
    # shellcheck disable=SC2016 # the text of the script, not an expansion
    [ "$(grep -c -x 'search_result "$state/gpu/search/result"' "$BATS_TEST_DIRNAME/../../gpu/$name.sh")" -eq 1 ]
  done
  [ "$(wc -l <"$BATS_TEST_TMPDIR/apply.fn")" -ge 60 ]
  cmp "$BATS_TEST_TMPDIR/apply.fn" "$BATS_TEST_TMPDIR/probe.fn"
}

@test "#142 own: as root apply gpu refuses a result whose directory is a symlink, to a directory of uid 0 with mode 755" {
  set_values 216 120 500
  set_result 210 1300
  mv "${RESULT%/*}" "${RESULT%/*}.real"
  ln -s "${RESULT%/*}.real" "${RESULT%/*}"
  run --separate-stderr in_ns_root /usr/bin/stat -L -c '%F %u %a' "${RESULT%/*}" "$RESULT"
  [ "$output" = $'directory 0 755\nregular file 0 644' ]
  root_apply
  refused "directory is a symlink"
  why "search/result refused: /var/lib/pc-oc/gpu/search is not a directory"
}

@test "#142 own: as root apply gpu refuses a named pipe at the result path without opening it" {
  set_values 216 120 500
  mkdir -p "${RESULT%/*}"
  mkfifo -m 0644 "$RESULT"
  # an open of the pipe for reading would block for ever: timeout ends that with 124
  run --separate-stderr in_ns_root /usr/bin/timeout 30 /usr/bin/bash "$REPO/pc-oc" apply gpu
  refused "named pipe"
  why "search/result refused: it is not a regular file"
}

@test "#142 own: as root apply gpu refuses a result that is not exactly the three lines gpu/search.sh writes: other order, a fourth line, a blank line, a comment, spaces, CR, finished= twice or without a UTC stamp, no final newline" {
  set_values 216 120 500
  core='core_offset_mhz=210' mem='mem_offset_mhz=1300' fin='finished=2026-10-02T09:14:07Z'
  n=0
  while IFS= read -r bad; do
    result_lines x
    printf '%b' "$bad" >"$RESULT"
    root_apply
    refused "$bad"
    why "search/result refused: it is not the three lines gpu/search.sh writes"
    n="$((n + 1))"
  done <<EOF
$mem\n$core\n$fin\n
$fin\n$core\n$mem\n
$core\n$mem\n$fin\nnote=x\n
$core\n$mem\n$fin\n\n
\n$core\n$mem\n$fin\n
# found by the search\n$core\n$mem\n$fin\n
$core  # src: search\n$mem\n$fin\n
$core \n$mem\n$fin\n
 $core\n$mem\n$fin\n
$core\r\n$mem\r\n$fin\r\n
CORE_OFFSET_MHZ=210\n$mem\n$fin\n
$core\n$mem\n$fin\n$fin\n
$core\n$mem\nfinished=\n
$core\n$mem\nfinished=yesterday\n
$core\n$mem\nfinished=2026-10-02T09:14:07\n
$core\n$mem\nfinished=2026-10-02 09:14:07Z\n
$core\n$mem\n$fin
$core\n$mem\n$fin\n$core\n$mem\n$fin\n
EOF
  [ "$n" -eq 18 ]
  # the control: the same way of writing the file, with nothing wrong in it
  printf '%b' "$core\n$mem\n$fin\n" >"$RESULT"
  root_apply
  [ "$status" -eq 0 ]
  [ "$output" = "gpu: offsets core=210 mem=1300 from search result" ]
}

@test "#142 own: as root apply gpu refuses a result with a NUL byte, after the three lines or inside a number" {
  set_values 216 120 500
  result_lines x
  printf 'core_offset_mhz=210\nmem_offset_mhz=1300\nfinished=2026-10-02T09:14:07Z\n\x00core_offset_mhz=30\n' >"$RESULT"
  root_apply
  refused "NUL after the three lines"
  why "search/result refused: it holds a NUL byte"
  printf 'core_offset_mhz=2\x0010\nmem_offset_mhz=1300\nfinished=2026-10-02T09:14:07Z\n' >"$RESULT"
  root_apply
  refused "NUL inside a number"
  why "search/result refused: it holds a NUL byte"
}

@test "#142 own: as root apply gpu refuses a number with a digit that is not one of 0 to 9, in a caller's locale where [0-9] matches such a digit" {
  loc="$(locale -a | grep -i -m 1 -x -E 'en_US\.utf-?8' || :)"
  # the control: in this locale the shell does take the digit for one of [0-9]
  if [[ -z "$loc" ]] || ! LC_ALL="$loc" /usr/bin/bash -c '[[ "٣" =~ ^[0-9]$ ]]'; then
    skip "no locale here in which [0-9] matches an Arabic-Indic digit"
  fi
  set_values 216 120 500
  result_lines 'core_offset_mhz=1٣0' 'mem_offset_mhz=1300' 'finished=2026-10-02T09:14:07Z'
  run --separate-stderr in_ns_root /usr/bin/env "LC_ALL=$loc" /usr/bin/bash "$REPO/pc-oc" apply gpu
  refused "digit outside 0 to 9"
  why "search/result refused: it is not the three lines gpu/search.sh writes"
}

@test "#142 own: as root apply gpu refuses a result it has no permission to read: uid 0 without the capabilities that pass file modes, mode 0000" {
  set_values 216 120 500
  set_result 210 1300
  chmod 0000 "$RESULT"
  run --separate-stderr in_ns_root /usr/bin/setpriv --bounding-set=-dac_override,-dac_read_search \
    /usr/bin/bash "$REPO/pc-oc" apply gpu
  refused "unreadable result"
  why "search/result refused: no permission to read it"
  # the control: the same call reads a result of mode 0600
  chmod 0600 "$RESULT"
  run --separate-stderr in_ns_root /usr/bin/setpriv --bounding-set=-dac_override,-dac_read_search \
    /usr/bin/bash "$REPO/pc-oc" apply gpu
  [ "$status" -eq 0 ]
  [ "$output" = "gpu: offsets core=210 mem=1300 from search result" ]
}

@test "#142 own: as root apply gpu refuses when a directory above the result path cannot be searched, where no result cannot be told from a result" {
  set_values 216 120 500
  set_result 210 1300
  chmod 0700 "${RESULT%/search/result}"
  subid_chown "${RESULT%/search/result}"
  # shellcheck disable=SC2016 # $1 is for the inner shell
  run --separate-stderr in_ns_root /usr/bin/bash -c '[[ ! -e "$1" && ! -L "$1" ]]' _ /var/lib/pc-oc/gpu/search/result
  [ "$status" -eq 0 ]
  root_apply
  subid_restore
  refused "directory above cannot be searched"
  why "cannot tell whether there is a search result at /var/lib/pc-oc/gpu/search/result: no permission to look into /var/lib/pc-oc/gpu"
}

@test "#142 own: as root apply gpu with a good result still refuses a gpu/values without core_offset_mhz or without mem_offset_mhz" {
  set_result 210 1300
  printf 'pl_w=216  # src: smi\nmem_offset_mhz=500  # src: nvml-offset-t\n' >"$REPO/gpu/values"
  root_apply
  refused "gpu/values without core_offset_mhz"
  why "no core_offset_mhz in"
  printf 'pl_w=216  # src: smi\ncore_offset_mhz=120  # src: nvml-offset-t\n' >"$REPO/gpu/values"
  root_apply
  refused "gpu/values without mem_offset_mhz"
  why "no mem_offset_mhz in"
}

@test "#142 own: as root apply gpu that cannot write its source line writes nothing else either: stdout full, stdout closed" {
  set_values 216 120 500
  set_result 210 1300
  # shellcheck disable=SC2016 # $@ is for the inner shell
  for out in '"$@" >/dev/full' '"$@" >&-'; do
    run --separate-stderr in_ns_root /usr/bin/bash -c "$out" _ /usr/bin/bash "$REPO/pc-oc" apply gpu
    refused "stdout: $out"
    why "cannot write to stdout, nothing was written"
  done
}

@test "#142 own: the source line comes once every refusal is past and before the first write: stdout is empty for a refused result, a power limit out of range and a missing unit, and holds the one line when a set fails after it" {
  set_values 216 120 500
  result_lines 'core_offset_mhz=-30' 'mem_offset_mhz=1300' 'finished=2026-10-02T09:14:07Z'
  root_apply
  refused "bad number"
  [ "$output" = "" ]
  set_result 210 1300
  set_values 217 120 500
  root_apply
  refused "pl_w 217"
  [ "$output" = "" ]
  set_values 216 120 500
  tuned 150.00 0 0 missing
  root_apply
  [ "$status" -eq 1 ]
  [ ! -s "$MOCK_STATE/calls" ]
  [ "$output" = "" ]
  fresh
  export MOCK_NVML='set mem=fail'
  root_apply
  [ "$status" -eq 1 ]
  [ "$output" = "gpu: offsets core=210 mem=1300 from search result" ]
  [ "$(logged '^nvml set core 210$')" -eq 1 ]
  [ "$(cat "$MOCK_STATE/offsets")" = "0 0" ]
  [ "$(cat "$MOCK_STATE/unit")" = "disabled" ]
}

@test "#142 own: as root apply gpu adopts a good result and refuses a bad one the same way whatever IFS, POSIXLY_CORRECT, TMPDIR, SHELLOPTS, CDPATH or GLOBIGNORE the caller left in the environment" {
  set_values 216 120 500
  for env in "${CALLER_ENVS[@]}" all; do
    args=("$env")
    [ "$env" != all ] || args=("${CALLER_ENVS[@]}")
    fresh
    set_result 210 1300
    run --separate-stderr in_ns_root /usr/bin/env "${args[@]}" /usr/bin/bash "$REPO/pc-oc" apply gpu
    [ "$status" -eq 0 ] || printf 'env %s: status %s\n%s\n' "$env" "$status" "$stderr" >&2
    [ "$status" -eq 0 ]
    [ "$(sed -n '/^nvidia-smi -pl /,$p' "$MOCK_STATE/order")" = "$(want_calls 210 1300)" ]
    [ "$output" = "gpu: offsets core=210 mem=1300 from search result" ]
    [ "$stderr" = "" ]
    [ -s "$BATS_TEST_TMPDIR/varlib/pc-oc/gpu/stock" ]
    fresh
    chmod 0664 "$RESULT"
    run --separate-stderr in_ns_root /usr/bin/env "${args[@]}" /usr/bin/bash "$REPO/pc-oc" apply gpu
    refused "mode 0664 under $env"
    why "search/result refused: it is writable by group or others"
  done
}

@test "#142 own: a finished= stamp in the format gpu/search.sh hands to date is one apply gpu accepts" {
  sh="$BATS_TEST_DIRNAME/../../gpu/search.sh"
  [ -e "$sh" ] || skip "gpu/search.sh is not on this branch: #135 writes it"
  fmt="$(grep -o -E 'finished=\$\(date -u \+[^)]+\)' "$sh" | sed -e 's/.*date -u //' -e 's/)$//')"
  [[ "$fmt" == +%* && "$fmt" != *$'\n'* ]]
  set_values 216 120 500
  result_lines 'core_offset_mhz=210' 'mem_offset_mhz=1300' "finished=$(date -u "$fmt")"
  root_apply
  [ "$status" -eq 0 ]
  [ "$output" = "gpu: offsets core=210 mem=1300 from search result" ]
}
