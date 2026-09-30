#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup() {
  skip "contract #8 pending"
  export SYSFS_ROOT="$BATS_TEST_TMPDIR/root"
  PROBE="$BATS_TEST_DIRNAME/../../ram/probe.sh"
  mkdir -p "$SYSFS_ROOT/proc"
  printf 'MemTotal:       32768000 kB\nMemFree:        1000 kB\n' >"$SYSFS_ROOT/proc/meminfo"
}

@test "probe ram prints ram.total_kb from MemTotal" {
  run --separate-stderr bash "$PROBE"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\nram.total_kb=32768000'* ]]
}

@test "probe ram line 1 names the files read and counts the key lines" {
  run --separate-stderr bash "$PROBE"
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" =~ ^source=/[^\ ]+\ bytes=[0-9]+\ items=([0-9]+)$ ]]
  [ "${BASH_REMATCH[1]}" -eq "$((${#lines[@]} - 1))" ]
  [[ "${lines[0]}" == *"$SYSFS_ROOT/proc/meminfo"* ]]
}

# The root path (ram.dimm<n>.* from a dmidecode stub on PATH) cannot run here:
# bats runs unprivileged and the ticket fixes no way to fake the uid.
@test "probe ram without root prints ram.dmi=needs-root and exits 0" {
  [ "$EUID" -ne 0 ] || skip "runs as root"
  run --separate-stderr bash "$PROBE"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\nram.dmi=needs-root'* ]]
}

@test "probe ram exits 1 with pc-oc: ram: when meminfo is missing" {
  rm "$SYSFS_ROOT/proc/meminfo"
  run --separate-stderr bash "$PROBE"
  [ "$status" -eq 1 ]
  [[ "$stderr" == "pc-oc: ram: "* ]]
  [[ "$stderr" != *"not implemented"* ]]
}
