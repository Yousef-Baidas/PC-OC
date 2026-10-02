#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031 # bats runs each test in a subshell; exports are per test

bats_require_minimum_version 1.5.0

# Contract #127 for gpu/revert.sh: it stops the boot unit, zeroes the clock offsets,
# disables the unit and restores the power limit, all four even when one fails (the stop
# and its place are Amendment 5). The cases written before #127
# are in apply.bats. Every run goes through in_ns (fixtures/apply/helper.bash): recording
# mocks stand over /usr/bin/nvidia-smi, /usr/bin/systemctl and /usr/bin/python3, and the
# tree's gpu/nvml.py is a recording stub. apply.bats holds the harness cases that show
# the mocks are reached.

load fixtures/apply/helper

setup() {
  gpu_tree
  ln -s "$MOCK_DIR/nvidia-smi" "$BATS_TEST_TMPDIR/bin/nvidia-smi"
}

# Amendment 5, for every case of this file: no revert may start the unit
teardown() {
  no_start "$MOCK_STATE/order"
}

# CALLS: every call a revert makes for an installed unit before the power-limit restore
CALLS=$'systemctl cat pc-oc-gpu.service\nsystemctl stop pc-oc-gpu.service\nnvml zero\nsystemctl disable pc-oc-gpu.service'

@test "#127 case 7: revert gpu with a snapshot records zero, disable and the power-limit restore, removes the snapshot and exits 0" {
  skip "contract #127 pending"
  tuned 216.00 120 500 enabled
  set_snapshot 150.00
  run --separate-stderr in_ns bash "$REPO/gpu/revert.sh"
  [ "$status" -eq 0 ]
  [ "$(logged '^nvml zero$')" -eq 1 ]
  [ "$(logged '^systemctl disable pc-oc-gpu\.service$')" -eq 1 ]
  [ "$(cat "$MOCK_STATE/calls")" = "-pl 150" ]
  [ "$(logged '^nvidia-smi --query-gpu=power\.limit ')" -ge 1 ]
  [ "$(cat "$MOCK_STATE/offsets")" = "0 0" ]
  [ "$(cat "$MOCK_STATE/unit")" = "disabled" ]
  [ "$(cat "$MOCK_STATE/pl")" = "150.00" ]
  [ ! -e "$PC_OC_STATE/gpu/stock" ]
}

@test "#127: revert gpu zeroes the offsets, then disables the unit, then restores the power limit" {
  skip "contract #127 pending"
  tuned 216.00 120 500 enabled
  set_snapshot 150.00
  run --separate-stderr in_ns bash "$REPO/gpu/revert.sh"
  [ "$status" -eq 0 ]
  zero_at="$(line_of '^nvml zero$')"
  disable_at="$(line_of "$DISABLE")"
  pl_at="$(line_of '^nvidia-smi -pl 150$')"
  [ -n "$zero_at" ]
  [ "$zero_at" -lt "$disable_at" ]
  [ "$disable_at" -lt "$pl_at" ]
}

@test "#127 case 8: revert gpu without a snapshot still records zero and disable, says nothing to revert and exits 0" {
  skip "contract #127 pending"
  tuned 150.00 120 500 enabled
  run --separate-stderr in_ns bash "$REPO/gpu/revert.sh"
  [ "$status" -eq 0 ]
  [ "$(logged '^nvml zero$')" -eq 1 ]
  [ "$(logged '^systemctl disable pc-oc-gpu\.service$')" -eq 1 ]
  [ "$(cat "$MOCK_STATE/offsets")" = "0 0" ]
  [ "$(cat "$MOCK_STATE/unit")" = "disabled" ]
  grep -qxF 'pc-oc: gpu: nothing to revert' <<<"$stderr"
  [ ! -s "$MOCK_STATE/calls" ]
}

@test "#127 case 9: revert gpu whose zero exits 1 still disables the unit and restores the power limit, exits 1 and names the offsets" {
  skip "contract #127 pending"
  tuned 216.00 120 500 enabled
  set_snapshot 150.00
  export MOCK_NVML='zero=fail'
  run --separate-stderr in_ns bash "$REPO/gpu/revert.sh"
  [ "$status" -eq 1 ]
  [ "$(logged '^nvml zero$')" -ge 1 ]
  [ "$(logged '^systemctl disable pc-oc-gpu\.service$')" -eq 1 ]
  [ "$(cat "$MOCK_STATE/unit")" = "disabled" ]
  [ "$(cat "$MOCK_STATE/calls")" = "-pl 150" ]
  [ "$(cat "$MOCK_STATE/pl")" = "150.00" ]
  [[ "$(own_messages)" == *offset* ]]
}

@test "#127 case 9: revert gpu without a snapshot whose zero exits 1 still disables the unit, exits 1 and names the offsets" {
  skip "contract #127 pending"
  tuned 150.00 120 500 enabled
  export MOCK_NVML='zero=fail'
  run --separate-stderr in_ns bash "$REPO/gpu/revert.sh"
  [ "$status" -eq 1 ]
  [ "$(logged '^systemctl disable pc-oc-gpu\.service$')" -eq 1 ]
  [[ "$(own_messages)" == *offset* ]]
}

@test "#127 case 10: revert gpu with the unit not installed zeroes the offsets, restores the power limit and exits 0" {
  skip "contract #127 pending"
  tuned 216.00 120 500 missing
  set_snapshot 150.00
  run --separate-stderr in_ns bash "$REPO/gpu/revert.sh"
  [ "$status" -eq 0 ]
  [ "$(logged '^nvml zero$')" -eq 1 ]
  [ "$(cat "$MOCK_STATE/offsets")" = "0 0" ]
  [ "$(cat "$MOCK_STATE/pl")" = "150.00" ]
  [ ! -e "$PC_OC_STATE/gpu/stock" ]
  reset_logs
  tuned 150.00 120 500 missing
  run --separate-stderr in_ns bash "$REPO/gpu/revert.sh"
  [ "$status" -eq 0 ]
  [ "$(logged '^nvml zero$')" -eq 1 ]
}

@test "#127: revert gpu with the unit installed but not enabled calls disable once and exits 0" {
  skip "contract #127 pending"
  tuned 216.00 120 500 disabled
  set_snapshot 150.00
  run --separate-stderr in_ns bash "$REPO/gpu/revert.sh"
  [ "$status" -eq 0 ]
  [ "$(logged '^nvml zero$')" -eq 1 ]
  [ "$(logged '^systemctl disable pc-oc-gpu\.service$')" -eq 1 ]
  [ "$(logged "$DISABLE")" -eq 1 ]
  [ "$(head -n 4 "$MOCK_STATE/order")" = "$CALLS" ]
  [ "$(cat "$MOCK_STATE/unit")" = "disabled" ]
  [ "$(cat "$MOCK_STATE/calls")" = "-pl 150" ]
  [ ! -e "$PC_OC_STATE/gpu/stock" ]
}

@test "#127 amendment 5: revert gpu with the unit installed calls systemctl cat, systemctl stop, nvml zero and systemctl disable, each once and in that order, and then restores the power limit" {
  skip "contract #127 pending"
  tuned 216.00 120 500 enabled
  set_snapshot 150.00
  run --separate-stderr in_ns bash "$REPO/gpu/revert.sh"
  [ "$status" -eq 0 ]
  [ "$(head -n 4 "$MOCK_STATE/order")" = "$CALLS" ]
  # what follows is the restore and nothing else
  [ "$(grep -v '^nvidia-smi ' "$MOCK_STATE/order")" = "$CALLS" ]
  [ "$(line_of '^nvidia-smi -pl 150$')" -gt 4 ]
  [ "$(cat "$MOCK_STATE/calls")" = "-pl 150" ]
  # without a snapshot there is no restore, and the four calls are the same
  reset_logs
  tuned 216.00 120 500 enabled
  run --separate-stderr in_ns bash "$REPO/gpu/revert.sh"
  [ "$status" -eq 0 ]
  [ "$(head -n 4 "$MOCK_STATE/order")" = "$CALLS" ]
  [ "$(grep -v '^nvidia-smi ' "$MOCK_STATE/order")" = "$CALLS" ]
  [ ! -s "$MOCK_STATE/calls" ]
}

@test "#127 amendment 5: revert gpu never asks is-enabled, and every systemctl call it makes is cat, stop or disable of pc-oc-gpu.service" {
  skip "contract #127 pending"
  for unit in enabled disabled missing; do
    for fail in "" MOCK_FAIL_STOP MOCK_FAIL_DISABLE; do
      for snapshot in yes no; do
        reset_logs
        rm -rf "$PC_OC_STATE"
        tuned 216.00 120 500 "$unit"
        [ "$snapshot" = no ] || set_snapshot 150.00
        unset MOCK_FAIL_STOP MOCK_FAIL_DISABLE
        [ -z "$fail" ] || export "$fail=1"
        run --separate-stderr in_ns bash "$REPO/gpu/revert.sh"
        [ "$(logged '^systemctl cat pc-oc-gpu\.service$')" -eq 1 ]
        [ "$(logged "$IS_ENABLED")" -eq 0 ]
        [ "$(grep '^systemctl ' "$MOCK_STATE/order" | grep -c -v -x -E 'systemctl (cat|stop|disable) pc-oc-gpu\.service' || :)" -eq 0 ]
      done
    done
  done
}

@test "#127 amendment 5: revert gpu whose stop fails still zeroes the offsets, disables the unit and restores the power limit, exits 1 and names the stop" {
  skip "contract #127 pending"
  tuned 216.00 120 500 enabled
  set_snapshot 150.00
  export MOCK_FAIL_STOP=1
  run --separate-stderr in_ns bash "$REPO/gpu/revert.sh"
  [ "$status" -eq 1 ]
  [ "$(head -n 4 "$MOCK_STATE/order")" = "$CALLS" ]
  [ "$(grep -v '^nvidia-smi ' "$MOCK_STATE/order")" = "$CALLS" ]
  [ "$(cat "$MOCK_STATE/offsets")" = "0 0" ]
  [ "$(cat "$MOCK_STATE/unit")" = "disabled" ]
  [ "$(cat "$MOCK_STATE/calls")" = "-pl 150" ]
  [ "$(cat "$MOCK_STATE/pl")" = "150.00" ]
  [[ "$(own_messages)" == *"boot unit pc-oc-gpu.service not stopped"* ]]
}

@test "#127 amendment 5: revert gpu without a snapshot whose stop fails still zeroes the offsets and disables the unit, exits 1 and names the stop" {
  skip "contract #127 pending"
  tuned 150.00 120 500 enabled
  export MOCK_FAIL_STOP=1
  run --separate-stderr in_ns bash "$REPO/gpu/revert.sh"
  [ "$status" -eq 1 ]
  [ "$(grep -v '^nvidia-smi ' "$MOCK_STATE/order")" = "$CALLS" ]
  [ "$(cat "$MOCK_STATE/offsets")" = "0 0" ]
  [ "$(cat "$MOCK_STATE/unit")" = "disabled" ]
  [ ! -s "$MOCK_STATE/calls" ]
  [[ "$(own_messages)" == *"boot unit pc-oc-gpu.service not stopped"* ]]
}

@test "#127 amendment 5: revert gpu names a failed stop and a failed disable apart, and neither when both went through" {
  skip "contract #127 pending"
  tuned 216.00 120 500 enabled
  set_snapshot 150.00
  export MOCK_FAIL_STOP=1
  run --separate-stderr in_ns bash "$REPO/gpu/revert.sh"
  [ "$status" -eq 1 ]
  [[ "$(own_messages)" == *"not stopped"* ]]
  [[ "$(own_messages)" != *disabl* ]]
  [[ "$(own_messages)" != *offset* ]]
  reset_logs
  unset MOCK_FAIL_STOP
  tuned 216.00 120 500 enabled
  set_snapshot 150.00
  export MOCK_FAIL_DISABLE=1
  run --separate-stderr in_ns bash "$REPO/gpu/revert.sh"
  [ "$status" -eq 1 ]
  [ "$(logged '^systemctl stop pc-oc-gpu\.service$')" -eq 1 ]
  [[ "$(own_messages)" =~ unit|pc-oc-gpu ]]
  [[ "$(own_messages)" != *stop* ]]
  reset_logs
  unset MOCK_FAIL_DISABLE
  tuned 216.00 120 500 enabled
  set_snapshot 150.00
  run --separate-stderr in_ns bash "$REPO/gpu/revert.sh"
  [ "$status" -eq 0 ]
  [ "$(logged '^systemctl stop pc-oc-gpu\.service$')" -eq 1 ]
  [[ "$stderr" != *stop* ]]
  [[ "$stderr" != *disabl* ]]
}

@test "#127 amendment 5: revert gpu whose stop, zero and disable all fail still attempts all four parts, restores the power limit, exits 1 and names the three" {
  skip "contract #127 pending"
  tuned 216.00 120 500 enabled
  set_snapshot 150.00
  export MOCK_FAIL_STOP=1 MOCK_NVML='zero=fail' MOCK_FAIL_DISABLE=1
  run --separate-stderr in_ns bash "$REPO/gpu/revert.sh"
  [ "$status" -eq 1 ]
  [ "$(logged '^systemctl stop pc-oc-gpu\.service$')" -eq 1 ]
  [ "$(logged '^nvml zero$')" -ge 1 ]
  [ "$(logged '^systemctl disable pc-oc-gpu\.service$')" -eq 1 ]
  [ "$(line_of "$STOP")" -lt "$(line_of '^nvml zero$')" ]
  [ "$(cat "$MOCK_STATE/calls")" = "-pl 150" ]
  [ "$(cat "$MOCK_STATE/pl")" = "150.00" ]
  [[ "$(own_messages)" == *"boot unit pc-oc-gpu.service not stopped"* ]]
  [[ "$(own_messages)" == *offset* ]]
  [[ "$(own_messages)" == *disabl* ]]
}

@test "#127 amendment 5: revert gpu with the unit not installed asks systemctl cat once and calls neither stop nor disable" {
  skip "contract #127 pending"
  tuned 216.00 120 500 missing
  set_snapshot 150.00
  run --separate-stderr in_ns bash "$REPO/gpu/revert.sh"
  [ "$status" -eq 0 ]
  [ "$(grep '^systemctl ' "$MOCK_STATE/order")" = "systemctl cat pc-oc-gpu.service" ]
  [ "$(logged "$STOP")" -eq 0 ]
  [ "$(logged "$SWITCH")" -eq 0 ]
  [ "$(logged '^nvml zero$')" -eq 1 ]
  [ "$(cat "$MOCK_STATE/calls")" = "-pl 150" ]
  reset_logs
  tuned 150.00 120 500 missing
  run --separate-stderr in_ns bash "$REPO/gpu/revert.sh"
  [ "$status" -eq 0 ]
  [ "$(grep '^systemctl ' "$MOCK_STATE/order")" = "systemctl cat pc-oc-gpu.service" ]
  [ "$(logged "$STOP")" -eq 0 ]
  [ "$(logged "$SWITCH")" -eq 0 ]
  [ "$(logged '^nvml zero$')" -eq 1 ]
}

@test "#127: revert gpu whose disable fails still zeroes the offsets and restores the power limit, exits 1 and names the unit" {
  skip "contract #127 pending"
  tuned 216.00 120 500 enabled
  set_snapshot 150.00
  export MOCK_FAIL_DISABLE=1
  run --separate-stderr in_ns bash "$REPO/gpu/revert.sh"
  [ "$status" -eq 1 ]
  [ "$(logged '^systemctl disable pc-oc-gpu\.service$')" -eq 1 ]
  [ "$(cat "$MOCK_STATE/offsets")" = "0 0" ]
  [ "$(cat "$MOCK_STATE/calls")" = "-pl 150" ]
  [ "$(cat "$MOCK_STATE/pl")" = "150.00" ]
  [[ "$(own_messages)" =~ unit|pc-oc-gpu ]]
}

@test "#127: revert gpu names only the parts that failed" {
  skip "contract #127 pending"
  tuned 216.00 120 500 enabled
  set_snapshot 150.00
  export MOCK_FAIL_DISABLE=1
  run --separate-stderr in_ns bash "$REPO/gpu/revert.sh"
  [ "$status" -eq 1 ]
  [[ "$(own_messages)" =~ unit|pc-oc-gpu ]]
  [[ "$(own_messages)" != *offset* ]]
  reset_logs
  unset MOCK_FAIL_DISABLE
  tuned 216.00 120 500 enabled
  set_snapshot 150.00
  export MOCK_NVML='zero=fail'
  run --separate-stderr in_ns bash "$REPO/gpu/revert.sh"
  [ "$status" -eq 1 ]
  [[ "$(own_messages)" == *offset* ]]
  [[ ! "$(own_messages)" =~ unit|pc-oc-gpu ]]
}

@test "#127: revert gpu whose zero and disable both fail still restores the power limit, exits 1 and names both" {
  skip "contract #127 pending"
  tuned 216.00 120 500 enabled
  set_snapshot 150.00
  export MOCK_NVML='zero=fail' MOCK_FAIL_DISABLE=1
  run --separate-stderr in_ns bash "$REPO/gpu/revert.sh"
  [ "$status" -eq 1 ]
  [ "$(cat "$MOCK_STATE/calls")" = "-pl 150" ]
  [ "$(cat "$MOCK_STATE/pl")" = "150.00" ]
  [[ "$(own_messages)" == *offset* ]]
  [[ "$(own_messages)" =~ unit|pc-oc-gpu ]]
}

@test "#127: revert gpu whose power-limit restore fails has still zeroed the offsets and disabled the unit, exits 1 and keeps the snapshot" {
  skip "contract #127 pending"
  ln -sf "$MOCK_DIR/nvidia-smi-ignore-pl" "$BATS_TEST_TMPDIR/bin/nvidia-smi"
  tuned 216.00 120 500 enabled
  set_snapshot 150.00
  run --separate-stderr in_ns bash "$REPO/gpu/revert.sh"
  [ "$status" -eq 1 ]
  [ "$(cat "$MOCK_STATE/calls")" = "-pl 150" ]
  [ "$(cat "$MOCK_STATE/offsets")" = "0 0" ]
  [ "$(cat "$MOCK_STATE/unit")" = "disabled" ]
  [ -n "$(own_messages)" ]
  [ -f "$PC_OC_STATE/gpu/stock" ]
}

@test "#127: revert gpu with a snapshot whose pl_w is out of range still zeroes the offsets and disables the unit, exits 1 and logs no -pl" {
  skip "contract #127 pending"
  tuned 216.00 120 500 enabled
  set_snapshot 300.00
  run --separate-stderr in_ns bash "$REPO/gpu/revert.sh"
  [ "$status" -eq 1 ]
  [ "$(cat "$MOCK_STATE/offsets")" = "0 0" ]
  [ "$(cat "$MOCK_STATE/unit")" = "disabled" ]
  [ ! -s "$MOCK_STATE/calls" ]
  [ -f "$PC_OC_STATE/gpu/stock" ]
}

@test "#127: revert gpu accepts a snapshot written before #127 (nine keys, no offsets, no boot_unit)" {
  skip "contract #127 pending"
  tuned 216.00 120 500 enabled
  mkdir -p "$PC_OC_STATE/gpu"
  cp "$FIX/stock-pre-127" "$PC_OC_STATE/gpu/stock"
  run --separate-stderr in_ns bash "$REPO/gpu/revert.sh"
  [ "$status" -eq 0 ]
  [ "$(logged '^nvml zero$')" -eq 1 ]
  [ "$(cat "$MOCK_STATE/calls")" = "-pl 150" ]
  [ "$(cat "$MOCK_STATE/pl")" = "150.00" ]
  [ ! -e "$PC_OC_STATE/gpu/stock" ]
}

@test "#127: revert gpu starts the helper as /usr/bin/python3 -I <its own dir>/nvml.py and never sets an offset or enables the unit" {
  skip "contract #127 pending"
  tuned 216.00 120 500 enabled
  set_snapshot 150.00
  run --separate-stderr in_ns bash "$REPO/gpu/revert.sh"
  [ "$status" -eq 0 ]
  [ "$(sort -u "$MOCK_STATE/python3")" = "/usr/bin/python3 -I $(realpath "$REPO/gpu/nvml.py")" ]
  [ "$(logged '^nvml set ')" -eq 0 ]
  [ "$(logged "$ENABLE")" -eq 0 ]
  no_start "$MOCK_STATE/order"
}
