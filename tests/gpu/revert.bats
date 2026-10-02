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
# Contract #142: "installed" is the unit file at /etc/systemd/system/pc-oc-gpu.service
# (-e or -L), where the guard shows the test's unit dir; systemctl cat is never called. The
# #127 cases that pinned the cat call are restated without it, each named "amended by #142".

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
# (#142: no systemctl cat before them)
CALLS=$'systemctl stop pc-oc-gpu.service\nnvml zero\nsystemctl disable pc-oc-gpu.service'

@test "#127 case 7: revert gpu with a snapshot records zero, disable and the power-limit restore, removes the snapshot and exits 0" {
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
  tuned 150.00 120 500 enabled
  export MOCK_NVML='zero=fail'
  run --separate-stderr in_ns bash "$REPO/gpu/revert.sh"
  [ "$status" -eq 1 ]
  [ "$(logged '^systemctl disable pc-oc-gpu\.service$')" -eq 1 ]
  [[ "$(own_messages)" == *offset* ]]
}

@test "#127 case 10: revert gpu with the unit not installed zeroes the offsets, restores the power limit and exits 0" {
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

@test "#127, amended by #142: revert gpu with the unit installed but not enabled calls stop, zero and disable once each, no systemctl cat, and exits 0" {
  skip "contract #142 pending"
  tuned 216.00 120 500 disabled
  set_snapshot 150.00
  run --separate-stderr in_ns bash "$REPO/gpu/revert.sh"
  [ "$status" -eq 0 ]
  [ "$(logged '^nvml zero$')" -eq 1 ]
  [ "$(logged '^systemctl disable pc-oc-gpu\.service$')" -eq 1 ]
  [ "$(logged "$DISABLE")" -eq 1 ]
  [ "$(head -n 3 "$MOCK_STATE/order")" = "$CALLS" ]
  [ "$(cat "$MOCK_STATE/unit")" = "disabled" ]
  [ "$(cat "$MOCK_STATE/calls")" = "-pl 150" ]
  [ ! -e "$PC_OC_STATE/gpu/stock" ]
}

@test "#127 amendment 5, amended by #142: revert gpu with the unit installed calls systemctl stop, nvml zero and systemctl disable, each once and in that order with no systemctl cat before them, and then restores the power limit" {
  skip "contract #142 pending"
  tuned 216.00 120 500 enabled
  set_snapshot 150.00
  run --separate-stderr in_ns bash "$REPO/gpu/revert.sh"
  [ "$status" -eq 0 ]
  [ "$(head -n 3 "$MOCK_STATE/order")" = "$CALLS" ]
  # what follows is the restore and nothing else
  [ "$(grep -v '^nvidia-smi ' "$MOCK_STATE/order")" = "$CALLS" ]
  [ "$(line_of '^nvidia-smi -pl 150$')" -gt 3 ]
  [ "$(cat "$MOCK_STATE/calls")" = "-pl 150" ]
  # without a snapshot there is no restore, and the three calls are the same
  reset_logs
  tuned 216.00 120 500 enabled
  run --separate-stderr in_ns bash "$REPO/gpu/revert.sh"
  [ "$status" -eq 0 ]
  [ "$(head -n 3 "$MOCK_STATE/order")" = "$CALLS" ]
  [ "$(grep -v '^nvidia-smi ' "$MOCK_STATE/order")" = "$CALLS" ]
  [ ! -s "$MOCK_STATE/calls" ]
}

@test "#127 amendment 5, amended by #142: revert gpu never asks is-enabled and never calls systemctl cat, and every systemctl call it makes is stop or disable of pc-oc-gpu.service" {
  skip "contract #142 pending"
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
        [ "$(logged '^nvml zero$')" -eq 1 ]
        [ "$(logged '^systemctl( .*)? cat( |$)')" -eq 0 ]
        [ "$(logged "$IS_ENABLED")" -eq 0 ]
        [ "$(grep '^systemctl ' "$MOCK_STATE/order" | grep -c -v -x -E 'systemctl (stop|disable) pc-oc-gpu\.service' || :)" -eq 0 ]
      done
    done
  done
}

@test "#127 amendment 5, amended by #142: revert gpu whose stop fails still zeroes the offsets, disables the unit and restores the power limit, exits 1 and names the stop; its calls are stop, zero, disable with no systemctl cat" {
  skip "contract #142 pending"
  tuned 216.00 120 500 enabled
  set_snapshot 150.00
  export MOCK_FAIL_STOP=1
  run --separate-stderr in_ns bash "$REPO/gpu/revert.sh"
  [ "$status" -eq 1 ]
  [ "$(head -n 3 "$MOCK_STATE/order")" = "$CALLS" ]
  [ "$(grep -v '^nvidia-smi ' "$MOCK_STATE/order")" = "$CALLS" ]
  [ "$(cat "$MOCK_STATE/offsets")" = "0 0" ]
  [ "$(cat "$MOCK_STATE/unit")" = "disabled" ]
  [ "$(cat "$MOCK_STATE/calls")" = "-pl 150" ]
  [ "$(cat "$MOCK_STATE/pl")" = "150.00" ]
  [[ "$(own_messages)" == *"boot unit pc-oc-gpu.service not stopped"* ]]
}

@test "#127 amendment 5, amended by #142: revert gpu without a snapshot whose stop fails still zeroes the offsets and disables the unit, exits 1 and names the stop; its calls are stop, zero, disable with no systemctl cat" {
  skip "contract #142 pending"
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

@test "#127 amendment 5, amended by #142: revert gpu with the unit not installed calls neither stop nor disable, and systemctl not at all" {
  skip "contract #142 pending"
  tuned 216.00 120 500 missing
  set_snapshot 150.00
  run --separate-stderr in_ns bash "$REPO/gpu/revert.sh"
  [ "$status" -eq 0 ]
  [ "$(logged '^systemctl')" -eq 0 ]
  [ "$(logged "$STOP")" -eq 0 ]
  [ "$(logged "$SWITCH")" -eq 0 ]
  [ "$(logged '^nvml zero$')" -eq 1 ]
  [ "$(cat "$MOCK_STATE/calls")" = "-pl 150" ]
  reset_logs
  tuned 150.00 120 500 missing
  run --separate-stderr in_ns bash "$REPO/gpu/revert.sh"
  [ "$status" -eq 0 ]
  [ "$(logged '^systemctl')" -eq 0 ]
  [ "$(logged "$STOP")" -eq 0 ]
  [ "$(logged "$SWITCH")" -eq 0 ]
  [ "$(logged '^nvml zero$')" -eq 1 ]
}

@test "#127: revert gpu whose disable fails still zeroes the offsets and restores the power limit, exits 1 and names the unit" {
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
  tuned 216.00 120 500 enabled
  set_snapshot 150.00
  run --separate-stderr in_ns bash "$REPO/gpu/revert.sh"
  [ "$status" -eq 0 ]
  [ "$(sort -u "$MOCK_STATE/python3")" = "/usr/bin/python3 -I $(realpath "$REPO/gpu/nvml.py")" ]
  [ "$(logged '^nvml set ')" -eq 0 ]
  [ "$(logged "$ENABLE")" -eq 0 ]
  no_start "$MOCK_STATE/order"
}

# Worker cases for #127: what the contract leaves open and gpu/revert.sh settles.

@test "#127 own: revert gpu whose zero fails still drops the snapshot once the power limit is back, and a second revert zeroes again with nothing to restore" {
  tuned 216.00 120 500 enabled
  set_snapshot 150.00
  export MOCK_NVML='zero=fail'
  run --separate-stderr in_ns bash "$REPO/gpu/revert.sh"
  [ "$status" -eq 1 ]
  [ "$(cat "$MOCK_STATE/pl")" = "150.00" ]
  [ ! -e "$PC_OC_STATE/gpu/stock" ]
  reset_logs
  unset MOCK_NVML
  run --separate-stderr in_ns bash "$REPO/gpu/revert.sh"
  [ "$status" -eq 0 ]
  [ "$(logged '^nvml zero$')" -eq 1 ]
  [ "$(cat "$MOCK_STATE/offsets")" = "0 0" ]
  [ ! -s "$MOCK_STATE/calls" ]
  grep -qxF 'pc-oc: gpu: nothing to revert' <<<"$stderr"
}

@test "#127 own: revert gpu whose power-limit restore fails names the power limit and neither the offsets nor the unit" {
  ln -sf "$MOCK_DIR/nvidia-smi-ignore-pl" "$BATS_TEST_TMPDIR/bin/nvidia-smi"
  tuned 216.00 120 500 enabled
  set_snapshot 150.00
  run --separate-stderr in_ns bash "$REPO/gpu/revert.sh"
  [ "$status" -eq 1 ]
  [ "$(own_messages | tail -n 1)" = "pc-oc: gpu: revert incomplete: power limit not restored, snapshot kept" ]
  [[ "$(own_messages)" != *offset* ]]
  [[ ! "$(own_messages)" =~ unit|pc-oc-gpu ]]
}

@test "#127 own: revert gpu whose four parts all fail names all four in its last line, in the order it ran them" {
  ln -sf "$MOCK_DIR/nvidia-smi-fail-pl" "$BATS_TEST_TMPDIR/bin/nvidia-smi"
  tuned 216.00 120 500 enabled
  set_snapshot 150.00
  export MOCK_FAIL_STOP=1 MOCK_NVML='zero=fail' MOCK_FAIL_DISABLE=1
  run --separate-stderr in_ns bash "$REPO/gpu/revert.sh"
  [ "$status" -eq 1 ]
  [ "$(logged '^systemctl stop pc-oc-gpu\.service$')" -eq 1 ]
  [ "$(logged '^nvml zero$')" -eq 1 ]
  [ "$(logged '^systemctl disable pc-oc-gpu\.service$')" -eq 1 ]
  [ "$(cat "$MOCK_STATE/calls")" = "-pl 150" ]
  [ "$(own_messages | tail -n 1)" = "pc-oc: gpu: revert incomplete: boot unit pc-oc-gpu.service not stopped, clock offsets not zeroed, boot unit pc-oc-gpu.service not disabled, power limit not restored, snapshot kept" ]
  [ -f "$PC_OC_STATE/gpu/stock" ]
}

@test "#127 own, amended by #142: revert gpu with the unit not installed says nothing of its own about the unit, and no line of systemctl is in its output since it asks none" {
  skip "contract #142 pending"
  tuned 216.00 120 500 missing
  set_snapshot 150.00
  run --separate-stderr in_ns bash "$REPO/gpu/revert.sh"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(grep -c -F 'No files found' <<<"$stderr" || :)" -eq 0 ]
  [ -z "$(own_messages)" ]
}

# Contract #142: revert leaves the search result alone, and decides "installed" by the
# unit file. root_revert is pc-oc revert gpu as uid 0 in the guard, where the result of
# the search is root's file under the scratch /var/lib.

root_revert() {
  run --separate-stderr in_ns_root /usr/bin/bash "$REPO/pc-oc" revert gpu
}

# set_root_snapshot <pl_w>: the stock snapshot where uid 0 in the guard keeps it
set_root_snapshot() {
  mkdir -p "$BATS_TEST_TMPDIR/varlib/pc-oc/gpu"
  printf 'source=/x bytes=1 items=1\ngpu.pl_w=%s\n' "$1" >"$BATS_TEST_TMPDIR/varlib/pc-oc/gpu/stock"
}

# SYSTEMCTL_CAT: any systemctl call with the verb cat
SYSTEMCTL_CAT='^systemctl( .*)? cat( |$)'

@test "#142 case 5: as root revert gpu with a search result present leaves it byte for byte as it was, with a snapshot and without" {
  skip "contract #142 pending"
  tuned 216.00 210 1300 enabled
  set_result 210 1300
  cp "$RESULT" "$BATS_TEST_TMPDIR/before"
  set_root_snapshot 150.00
  root_revert
  [ "$status" -eq 0 ]
  [ "$(cat "$MOCK_STATE/offsets")" = "0 0" ]
  [ "$(cat "$MOCK_STATE/unit")" = "disabled" ]
  [ "$(cat "$MOCK_STATE/pl")" = "150.00" ]
  [ ! -e "$BATS_TEST_TMPDIR/varlib/pc-oc/gpu/stock" ]
  cmp "$RESULT" "$BATS_TEST_TMPDIR/before"
  [ "$(stat -c '%F %a' "$RESULT")" = "regular file 644" ]
  reset_logs
  tuned 150.00 210 1300 enabled
  root_revert
  [ "$status" -eq 0 ]
  [ "$(cat "$MOCK_STATE/offsets")" = "0 0" ]
  cmp "$RESULT" "$BATS_TEST_TMPDIR/before"
  [ "$(stat -c '%F %a' "$RESULT")" = "regular file 644" ]
}

@test "#142 case 5: as root apply gpu from a search result and then revert gpu: offsets zeroed, unit disabled, limit back, snapshot gone, the result as it was" {
  skip "contract #142 pending"
  set_values 216 120 500
  set_result 210 1300
  cp "$RESULT" "$BATS_TEST_TMPDIR/before"
  run --separate-stderr in_ns_root /usr/bin/bash "$REPO/pc-oc" apply gpu
  [ "$status" -eq 0 ]
  [ "$(cat "$MOCK_STATE/offsets")" = "210 1300" ]
  [ "$(cat "$MOCK_STATE/unit")" = "enabled" ]
  root_revert
  [ "$status" -eq 0 ]
  [ "$(cat "$MOCK_STATE/offsets")" = "0 0" ]
  [ "$(cat "$MOCK_STATE/unit")" = "disabled" ]
  [ "$(cat "$MOCK_STATE/pl")" = "150.00" ]
  [ ! -e "$BATS_TEST_TMPDIR/varlib/pc-oc/gpu/stock" ]
  cmp "$RESULT" "$BATS_TEST_TMPDIR/before"
}

@test "#142 case 5: revert gpu does not judge the result: one that apply would refuse is left as it was and revert still exits 0" {
  skip "contract #142 pending"
  tuned 216.00 210 1300 enabled
  result_lines 'core_offset_mhz=-30' 'garbage'
  chmod 0666 "$RESULT"
  cp "$RESULT" "$BATS_TEST_TMPDIR/before"
  set_root_snapshot 150.00
  root_revert
  [ "$status" -eq 0 ]
  [ "$(cat "$MOCK_STATE/offsets")" = "0 0" ]
  [ "$(cat "$MOCK_STATE/unit")" = "disabled" ]
  cmp "$RESULT" "$BATS_TEST_TMPDIR/before"
  [ "$(stat -c '%F %a' "$RESULT")" = "regular file 666" ]
  # and a symlink at the path stays that symlink
  reset_logs
  tuned 216.00 210 1300 enabled
  rm "$RESULT"
  ln -s "$BATS_TEST_TMPDIR/before" "$RESULT"
  root_revert
  [ "$status" -eq 0 ]
  [ "$(readlink "$RESULT")" = "$BATS_TEST_TMPDIR/before" ]
  [ "$(cat "$BATS_TEST_TMPDIR/before")" = $'core_offset_mhz=-30\ngarbage' ]
}

@test "#142 case 6: revert gpu with the unit file present and every systemctl call failing still attempts stop and disable, zeroes the offsets, restores the limit, names both as failed and exits 1" {
  skip "contract #142 pending"
  tuned 216.00 120 500 missing
  unit_file present
  set_snapshot 150.00
  run --separate-stderr in_ns bash "$REPO/gpu/revert.sh"
  [ "$status" -eq 1 ]
  [ "$(grep -v '^nvidia-smi ' "$MOCK_STATE/order")" = "$CALLS" ]
  [ "$(logged "$SYSTEMCTL_CAT")" -eq 0 ]
  [ "$(cat "$MOCK_STATE/offsets")" = "0 0" ]
  [ "$(cat "$MOCK_STATE/calls")" = "-pl 150" ]
  [ "$(cat "$MOCK_STATE/pl")" = "150.00" ]
  [ "$(own_messages | tail -n 1)" = "pc-oc: gpu: revert incomplete: boot unit pc-oc-gpu.service not stopped, boot unit pc-oc-gpu.service not disabled" ]
}

@test "#142 case 6: the same without a snapshot: stop and disable attempted and named as failed, offsets zeroed, exit 1" {
  skip "contract #142 pending"
  tuned 150.00 120 500 missing
  unit_file present
  run --separate-stderr in_ns bash "$REPO/gpu/revert.sh"
  [ "$status" -eq 1 ]
  [ "$(grep -v '^nvidia-smi ' "$MOCK_STATE/order")" = "$CALLS" ]
  [ "$(cat "$MOCK_STATE/offsets")" = "0 0" ]
  [ ! -s "$MOCK_STATE/calls" ]
  [[ "$(own_messages)" == *"boot unit pc-oc-gpu.service not stopped"* ]]
  [[ "$(own_messages)" == *"boot unit pc-oc-gpu.service not disabled"* ]]
}

@test "#142 case 6: revert gpu with no unit file makes no systemctl call at all, zeroes the offsets, restores the limit and exits 0, even when systemctl would answer for an enabled unit" {
  skip "contract #142 pending"
  tuned 216.00 120 500 enabled
  unit_file absent
  set_snapshot 150.00
  run --separate-stderr in_ns bash "$REPO/gpu/revert.sh"
  [ "$status" -eq 0 ]
  [ "$(logged '^systemctl')" -eq 0 ]
  [ "$(logged '^nvml zero$')" -eq 1 ]
  [ "$(cat "$MOCK_STATE/offsets")" = "0 0" ]
  [ "$(cat "$MOCK_STATE/calls")" = "-pl 150" ]
  [ "$(cat "$MOCK_STATE/pl")" = "150.00" ]
  [ "$(cat "$MOCK_STATE/unit")" = "enabled" ]
  [ ! -e "$PC_OC_STATE/gpu/stock" ]
  [ -z "$(own_messages)" ]
  # without a snapshot too
  reset_logs
  tuned 150.00 120 500 enabled
  unit_file absent
  run --separate-stderr in_ns bash "$REPO/gpu/revert.sh"
  [ "$status" -eq 0 ]
  [ "$(logged '^systemctl')" -eq 0 ]
  [ "$(logged '^nvml zero$')" -eq 1 ]
}

@test "#142 case 6: revert gpu counts a dangling symlink at the unit path as installed: stop, zero, disable" {
  skip "contract #142 pending"
  tuned 216.00 120 500 enabled
  unit_file dangling
  set_snapshot 150.00
  run --separate-stderr in_ns bash "$REPO/gpu/revert.sh"
  [ "$status" -eq 0 ]
  [ "$(grep -v '^nvidia-smi ' "$MOCK_STATE/order")" = "$CALLS" ]
  [ "$(cat "$MOCK_STATE/unit")" = "disabled" ]
  [ "$(cat "$MOCK_STATE/calls")" = "-pl 150" ]
}

@test "#142 case 6: as root pc-oc revert gpu decides by the unit file the same way: none, no systemctl call; present with systemctl failing, stop and disable named and exit 1" {
  skip "contract #142 pending"
  tuned 216.00 120 500 enabled
  unit_file absent
  set_root_snapshot 150.00
  root_revert
  [ "$status" -eq 0 ]
  [ "$(logged '^systemctl')" -eq 0 ]
  [ "$(cat "$MOCK_STATE/offsets")" = "0 0" ]
  [ "$(cat "$MOCK_STATE/pl")" = "150.00" ]
  reset_logs
  tuned 216.00 120 500 missing
  unit_file present
  set_root_snapshot 150.00
  root_revert
  [ "$status" -eq 1 ]
  [ "$(grep -v '^nvidia-smi ' "$MOCK_STATE/order")" = "$CALLS" ]
  own_messages | grep -qxF "pc-oc: gpu: revert incomplete: boot unit pc-oc-gpu.service not stopped, boot unit pc-oc-gpu.service not disabled"
}

@test "#142 case 6: revert gpu never calls systemctl cat: unit file present, absent or dangling, systemctl answering enabled, disabled or failing, with a snapshot and without" {
  skip "contract #142 pending"
  for file in present absent dangling; do
    for unit in enabled disabled missing; do
      for snapshot in yes no; do
        reset_logs
        rm -rf "$PC_OC_STATE"
        tuned 216.00 120 500 "$unit"
        unit_file "$file"
        [ "$snapshot" = no ] || set_snapshot 150.00
        run --separate-stderr in_ns bash "$REPO/gpu/revert.sh"
        [ "$(logged '^nvml zero$')" -eq 1 ]
        [ "$(logged "$SYSTEMCTL_CAT")" -eq 0 ]
        if [ "$file" = absent ]; then
          [ "$(logged '^systemctl')" -eq 0 ]
        else
          [ "$(logged '^systemctl stop pc-oc-gpu\.service$')" -eq 1 ]
          [ "$(logged '^systemctl disable pc-oc-gpu\.service$')" -eq 1 ]
        fi
      done
    done
  done
}

@test "#142 case 8: gpu/revert.sh names the unit file by the one path os/install.sh installs it to, with no variable in front" {
  skip "contract #142 pending"
  want="$(installed_unit_path)"
  [ "$want" = /etc/systemd/system/pc-oc-gpu.service ]
  [ "$(named_unit_paths "$BATS_TEST_DIRNAME/../../gpu/revert.sh")" = "$want" ]
}
