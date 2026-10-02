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
  skip "contract #127 pending"
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
  skip "contract #127 pending"
  set_values 216 0 0
  run --separate-stderr in_ns bash "$REPO/gpu/apply.sh"
  [ "$status" -eq 0 ]
  [ "$(logged '^nvml set core 0$')" -eq 1 ]
  [ "$(logged '^nvml set mem 0$')" -eq 1 ]
  [ "$(logged '^nvml set ')" -eq 2 ]
}

@test "#127 case 3: apply gpu with the unit already enabled does not call enable" {
  skip "contract #127 pending"
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
  skip "contract #127 pending"
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
  skip "contract #127 pending"
  set_values 216 120 500
  run --separate-stderr in_ns bash "$REPO/gpu/apply.sh"
  [ "$status" -eq 0 ]
  cat_at="$(line_of '^systemctl cat pc-oc-gpu\.service$')"
  pl_at="$(line_of '^nvidia-smi -pl ')"
  [ -n "$cat_at" ]
  [ "$cat_at" -lt "$pl_at" ]
}

@test "#127 case 5: apply gpu whose set mem exits 1 exits 1, names the memory offset, zeroes the offsets once and does not enable the unit" {
  skip "contract #127 pending"
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
  skip "contract #127 pending"
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
  skip "contract #127 pending"
  set_values 216 120 500
  export MOCK_NVML='set mem=fail'
  run --separate-stderr in_ns bash "$REPO/gpu/apply.sh"
  [ "$status" -eq 1 ]
  [ "$(logged '^nvml set mem 500$')" -eq 1 ]
  [ "$(cat "$MOCK_STATE/pl")" = "216.00" ]
  grep -q '^gpu.pl_w=150' "$PC_OC_STATE/gpu/stock"
}

@test "#127: apply gpu whose power-limit read-back differs sets no offset and does not enable the unit" {
  skip "contract #127 pending"
  ln -sf "$MOCK_DIR/nvidia-smi-ignore-pl" "$BATS_TEST_TMPDIR/bin/nvidia-smi"
  set_values 216 120 500
  run --separate-stderr in_ns bash "$REPO/gpu/apply.sh"
  [ "$status" -eq 1 ]
  [ "$(cat "$MOCK_STATE/calls")" = "-pl 216" ]
  [ "$(logged '^nvml set ')" -eq 0 ]
  [ "$(logged "$ENABLE")" -eq 0 ]
}

@test "#127: apply gpu whose enable fails exits 1 with its own pc-oc: gpu: line" {
  skip "contract #127 pending"
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
  skip "contract #127 pending"
  refused_values mem_offset_mhz 'pl_w=216  # src: smi' 'core_offset_mhz=120  # src: nvml-offset-t'
  # the same harness does write once the file is whole
  set_values 216 120 500
  run --separate-stderr in_ns bash "$REPO/gpu/apply.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$MOCK_STATE/calls")" = "-pl 216" ]
}

@test "#127 case 6: apply gpu with core_offset_mhz=12a exits 1 before any write" {
  skip "contract #127 pending"
  refused_values core_offset_mhz 'pl_w=216  # src: smi' 'core_offset_mhz=12a  # src: nvml-offset-t' 'mem_offset_mhz=500  # src: nvml-offset-t'
}

@test "#127 case 6: apply gpu refuses each offset that is not 0|[1-9][0-9]{0,3}, and a missing core_offset_mhz, before any write" {
  skip "contract #127 pending"
  refused_values core_offset_mhz 'pl_w=216  # src: smi' 'mem_offset_mhz=500  # src: nvml-offset-t'
  for bad in 0500 -30 +30 12345 120.5 "" " 120" 0x10; do
    refused_values core_offset_mhz 'pl_w=216  # src: smi' "core_offset_mhz=$bad  # src: nvml-offset-t" 'mem_offset_mhz=500  # src: nvml-offset-t'
    refused_values mem_offset_mhz 'pl_w=216  # src: smi' 'core_offset_mhz=120  # src: nvml-offset-t' "mem_offset_mhz=$bad  # src: nvml-offset-t"
  done
}

@test "#127 case 13: apply gpu whose set mem is killed (137) calls zero once, exits 1 and does not enable the unit" {
  skip "contract #127 pending"
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
  skip "contract #127 pending"
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
  skip "contract #127 pending"
  signalled TERM 'set core=term'
  [ "$(logged '^nvml set mem ')" -eq 0 ]
}

@test "#127 amendment 3: apply gpu that gets HUP or INT during a set, or TERM during set mem, does the same" {
  skip "contract #127 pending"
  signalled HUP 'set core=hup'
  signalled INT 'set core=int'
  signalled TERM 'set mem=term'
  signalled HUP 'set mem=hup'
  signalled INT 'set mem=int'
}

@test "#127 amendment 3: apply gpu that gets TERM during the -pl write calls zero once, sets no offset, exits non-zero and does not enable the unit" {
  skip "contract #127 pending"
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
  skip "contract #127 pending"
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
  skip "contract #127 pending"
  committed TERM enable
}

@test "#127 amendment 5: apply gpu that gets HUP during enable exits 0 with the unit enabled, both offsets as set and no zero call" {
  skip "contract #127 pending"
  committed HUP enable
}

@test "#127 amendment 5: apply gpu that gets INT during enable exits 0 with the unit enabled, both offsets as set and no zero call" {
  skip "contract #127 pending"
  committed INT enable
}

@test "#127 amendment 5: apply gpu that gets TERM, HUP or INT after set mem returned, while it asks is-enabled, still enables the unit, exits 0 and calls no zero" {
  skip "contract #127 pending"
  committed TERM is-enabled
  committed HUP is-enabled
  committed INT is-enabled
}

@test "#127 amendment 5: apply gpu with the unit already enabled that gets TERM while it asks is-enabled exits 0 with both offsets as set, no zero and no enable" {
  skip "contract #127 pending"
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
  skip "contract #127 pending"
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
  skip "contract #127 pending"
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
  skip "contract #127 pending"
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
  skip "contract #127 pending"
  set_values 216 120 500
  run --separate-stderr in_ns bash "$REPO/gpu/apply.sh"
  [ "$status" -eq 0 ]
  [ "$(logged '^nvml set ')" -eq 2 ]
  [ "$(sort -u "$MOCK_STATE/python3")" = "/usr/bin/python3 -I $(realpath "$REPO/gpu/nvml.py")" ]
}

@test "#127: as root pc-oc apply gpu then revert gpu set and clear the offsets and the unit through the /usr/bin mocks" {
  skip "contract #127 pending"
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
  skip "contract #127 pending"
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
