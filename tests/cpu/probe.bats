#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup() {
  skip "contract #8 pending"
  export SYSFS_ROOT="$BATS_TEST_TMPDIR/root"
  PROBE="$BATS_TEST_DIRNAME/../../cpu/probe.sh"
  mkdir -p "$SYSFS_ROOT/proc"
  printf 'processor\t: 0\nmodel name\t: Intel(R) Core(TM) i7-14700\nmicrocode\t: 0x137\n' \
    >"$SYSFS_ROOT/proc/cpuinfo"
  rapl="$SYSFS_ROOT/sys/class/powercap/intel-rapl:0"
  mkdir -p "$rapl"
  write_constraint 0 long_term 65000000 28000000
  write_constraint 1 short_term 219000000 2440
}

# write_constraint <n> <name> <limit_uw> <window_us>
write_constraint() {
  echo "$2" >"$rapl/constraint_$1_name"
  echo "$3" >"$rapl/constraint_$1_power_limit_uw"
  echo "$4" >"$rapl/constraint_$1_time_window_us"
}

@test "probe cpu prints model, microcode and both power limits" {
  run --separate-stderr bash "$PROBE"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\ncpu.model=Intel(R) Core(TM) i7-14700'* ]]
  [[ "$output" == *$'\ncpu.microcode=0x137'* ]]
  [[ "$output" == *$'\ncpu.pl1_uw=65000000'* ]]
  [[ "$output" == *$'\ncpu.pl1_tau_us=28000000'* ]]
  [[ "$output" == *$'\ncpu.pl2_uw=219000000'* ]]
}

@test "probe cpu line 1 names the files read and counts the key lines" {
  run --separate-stderr bash "$PROBE"
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" =~ ^source=/[^\ ]+\ bytes=[0-9]+\ items=([0-9]+)$ ]]
  [ "${BASH_REMATCH[1]}" -eq "$((${#lines[@]} - 1))" ]
  [[ "${lines[0]}" == *"$rapl/constraint_0_name"* ]]
  [[ "${lines[0]}" == *"$SYSFS_ROOT/proc/cpuinfo"* ]]
}

@test "probe cpu follows constraint names, not indexes" {
  write_constraint 0 short_term 219000000 2440
  write_constraint 1 long_term 65000000 28000000
  run --separate-stderr bash "$PROBE"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\ncpu.pl1_uw=65000000'* ]]
  [[ "$output" == *$'\ncpu.pl1_tau_us=28000000'* ]]
  [[ "$output" == *$'\ncpu.pl2_uw=219000000'* ]]
}

@test "probe cpu writes nothing under the fake root" {
  before="$(find "$SYSFS_ROOT" -type f -exec sha256sum {} + | sort)"
  run --separate-stderr bash "$PROBE"
  [ "$status" -eq 0 ]
  [ "$(find "$SYSFS_ROOT" -type f -exec sha256sum {} + | sort)" = "$before" ]
}

@test "probe cpu exits 1 with pc-oc: cpu: when intel-rapl:0 is missing" {
  rm -r "$rapl"
  run --separate-stderr bash "$PROBE"
  [ "$status" -eq 1 ]
  [ "$output" = "" ]
  [[ "$stderr" == "pc-oc: cpu: "* ]]
  [[ "$stderr" != *"not implemented"* ]]
}
