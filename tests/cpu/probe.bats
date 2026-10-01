#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup() {
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

# Contract #73. The root branch is reached with unshare -r: is_root reads /usr/bin/id -u, so
# a PATH stub cannot reach it. Nothing outside $SYSFS_ROOT is read; the msr is a fixture file.

# root_fixture: msr file with PERF_STATUS at offset 0x198; 0x2666 (9830) at bits 47:32, other
# bits set so a wrong shift or mask changes the value. energy_uj beside the rapl constraints.
root_fixture() {
  unshare -r true 2>/dev/null || skip "unshare -r unavailable"
  msr="$SYSFS_ROOT/dev/cpu/0/msr"
  mkdir -p "${msr%/*}"
  {
    head -c 408 /dev/zero
    printf '\x00\x1e\x07\x00\x66\x26\x01\x00'
    head -c 64 /dev/zero
  } >"$msr"
  echo 123456789 >"$rapl/energy_uj"
}

run_root_probe() {
  run --separate-stderr unshare -r bash "$PROBE"
}

@test "probe cpu as root reports vcore_mv from PERF_STATUS bits 47:32" {
  root_fixture
  run_root_probe
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\ncpu.vcore_mv=1200'* ]]
  [[ "$output" != *vcore=* ]]
}

@test "probe cpu as root reports pkg_energy_uj from energy_uj" {
  root_fixture
  run_root_probe
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\ncpu.pkg_energy_uj=123456789'* ]]
}

@test "probe cpu as root line 1 counts the new keys and names msr and energy_uj" {
  root_fixture
  run_root_probe
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" =~ ^source=/[^\ ]+\ bytes=[0-9]+\ items=([0-9]+)$ ]]
  [ "${BASH_REMATCH[1]}" -eq "$((${#lines[@]} - 1))" ]
  [[ "${lines[0]}" == *"$msr"* ]]
  [[ "${lines[0]}" == *"$rapl/energy_uj"* ]]
}

@test "probe cpu as root without an msr device prints vcore=no-msr and exits 0" {
  root_fixture
  rm "$msr"
  run_root_probe
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\ncpu.vcore=no-msr'* ]]
  [[ "$output" != *vcore_mv* ]]
}

@test "probe cpu as root exits 1 when the msr file is 4 bytes" {
  root_fixture
  head -c 4 /dev/zero >"$msr"
  run_root_probe
  [ "$status" -eq 1 ]
  [ "$output" = "" ]
  [[ "$stderr" == "pc-oc: cpu: cannot read"* ]]
}

@test "probe cpu without root prints vcore=needs-root and no energy key" {
  [ "$(id -u)" -ne 0 ] || skip "runs as root"
  echo 123456789 >"$rapl/energy_uj"
  run --separate-stderr bash "$PROBE"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\ncpu.vcore=needs-root'* ]]
  [[ "$output" != *pkg_energy_uj* ]]
  [[ "$output" != *vcore_mv* ]]
}
