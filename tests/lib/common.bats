#!/usr/bin/env bats
# shellcheck disable=SC2016 # bash -c bodies are single-quoted on purpose: the child shell expands them

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

# Contract #60. is_root is called only through sourced lib; no case runs os/*, gpu/* or pc-oc
# with a forged EUID, because on the unfixed code that reaches the real systemctl.
is_root_as() {
  env "EUID=$1" bash -c 'source "$1/lib/common.sh"; is_root' _ "$BATS_TEST_DIRNAME/../.."
}

@test "is_root returns 1 for a non-root caller whose environment forges EUID=0" {
  skip "contract #60 pending"
  [ "$(id -u)" -ne 0 ] || skip "needs a non-root user"
  run --separate-stderr is_root_as 0
  [ "$status" -eq 1 ]
  [ "$stderr" = "" ]
}

@test "is_root returns 0 under unshare -r even when EUID=1000 is forged" {
  skip "contract #60 pending"
  unshare -r true 2>/dev/null || skip "unshare -r unavailable"
  run --separate-stderr unshare -r env EUID=1000 bash -c 'source "$1/lib/common.sh"; is_root' _ "$BATS_TEST_DIRNAME/../.."
  [ "$status" -eq 0 ]
  [ "$stderr" = "" ]
}

@test "is_root does not evaluate a forged EUID: the marker is never created" {
  skip "contract #60 pending"
  [ "$(id -u)" -ne 0 ] || skip "needs a non-root user"
  marker="$BATS_TEST_TMPDIR/marker"
  run --separate-stderr is_root_as "a[\$(touch $marker)]"
  [ "$status" -eq 1 ]
  [ "$stderr" = "" ]
  [ ! -e "$marker" ]
}
