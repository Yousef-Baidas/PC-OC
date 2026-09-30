#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup() {
  # shellcheck source=lib/common.sh
  source "$BATS_TEST_DIRNAME/../../lib/common.sh"
}

@test "sysfs_path prefixes SYSFS_ROOT" {
  SYSFS_ROOT="$BATS_TEST_TMPDIR/sys"
  run sysfs_path /sys/kernel/sched_ext/state
  [ "$status" -eq 0 ]
  [ "$output" = "$BATS_TEST_TMPDIR/sys/sys/kernel/sched_ext/state" ]
}

@test "sysfs_path returns the path unchanged when SYSFS_ROOT is unset" {
  unset SYSFS_ROOT
  run sysfs_path /sys/kernel/sched_ext/state
  [ "$status" -eq 0 ]
  [ "$output" = /sys/kernel/sched_ext/state ]
}

@test "sysfs_path reads a file from a fake tree" {
  SYSFS_ROOT="$BATS_TEST_TMPDIR"
  mkdir -p "$SYSFS_ROOT/sys/kernel/sched_ext"
  echo disabled >"$SYSFS_ROOT/sys/kernel/sched_ext/state"
  [ "$(<"$(sysfs_path /sys/kernel/sched_ext/state)")" = disabled ]
}

@test "die prints pc-oc: <component>: <msg> to stderr and exits 1" {
  run --separate-stderr die cpu "PL1 read-back mismatch"
  [ "$status" -eq 1 ]
  [ "$output" = "" ]
  [ "$stderr" = "pc-oc: cpu: PL1 read-back mismatch" ]
}
