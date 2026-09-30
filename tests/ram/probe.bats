#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup() {
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

# stub_root <uid>: put id and dmidecode stubs first on PATH.
stub_root() {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/sh\necho %s\n' "$1" >"$BATS_TEST_TMPDIR/bin/id"
  cat >"$BATS_TEST_TMPDIR/bin/dmidecode" <<'DMI'
#!/bin/sh
cat <<'OUT'
# dmidecode 3.6
Handle 0x0040, DMI type 17, 92 bytes
Memory Device
	Size: 16 GB
	Speed: 5600 MT/s
	Part Number: KF560C40-16      
	Configured Memory Speed: 5200 MT/s
	Configured Voltage: 1.100 V

Handle 0x0041, DMI type 17, 92 bytes
Memory Device
	Size: No Module Installed
	Speed: Unknown
	Part Number: Unknown

Handle 0x0042, DMI type 17, 92 bytes
Memory Device
	Size: 16 GB
	Speed: 5600 MT/s
	Part Number: KF560C40-16
	Configured Memory Speed: 5600 MT/s
	Configured Voltage: 1.250 V
OUT
DMI
  chmod +x "$BATS_TEST_TMPDIR/bin/id" "$BATS_TEST_TMPDIR/bin/dmidecode"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

@test "probe ram as root prints per-DIMM keys for populated slots only, numbered from 0" {
  stub_root 0
  run --separate-stderr bash "$PROBE"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\nram.dimm0.speed_mts=5600\nram.dimm0.configured_mts=5200\nram.dimm0.part=KF560C40-16\nram.dimm0.configured_mv=1100'* ]]
  [[ "$output" == *$'\nram.dimm1.speed_mts=5600\nram.dimm1.configured_mts=5600\nram.dimm1.part=KF560C40-16\nram.dimm1.configured_mv=1250'* ]]
  [[ "$output" != *dimm2* ]]
  [[ "$output" != *needs-root* ]]
}

@test "probe ram as root counts items and names dmidecode in line 1" {
  stub_root 0
  run --separate-stderr bash "$PROBE"
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" =~ ^source=/[^\ ]+\ bytes=[0-9]+\ items=([0-9]+)$ ]]
  [ "${BASH_REMATCH[1]}" -eq 9 ]
  [ "${BASH_REMATCH[1]}" -eq "$((${#lines[@]} - 1))" ]
  [[ "${lines[0]}" == *"$BATS_TEST_TMPDIR/bin/dmidecode"* ]]
}

@test "probe ram as non-root never calls dmidecode" {
  stub_root 1000
  printf '#!/bin/sh\nexit 9\n' >"$BATS_TEST_TMPDIR/bin/dmidecode"
  run --separate-stderr bash "$PROBE"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\nram.dmi=needs-root' ]]
}

# stub_dmi: make the dmidecode stub print stdin.
stub_dmi() {
  {
    printf '#!/bin/sh\ncat <<'"'"'OUT'"'"'\n'
    cat
    printf 'OUT\n'
  } >"$BATS_TEST_TMPDIR/bin/dmidecode"
}

@test "probe ram as root exits 1 when a populated slot has Unknown speed and voltage" {
  stub_root 0
  stub_dmi <<'DMI'
Memory Device
	Size: 16 GB
	Speed: Unknown
	Part Number: KF560C40-16
	Configured Memory Speed: Unknown
	Configured Voltage: Unknown
DMI
  run --separate-stderr bash "$PROBE"
  [ "$status" -eq 1 ]
  [ "$output" = "" ]
  [[ "$stderr" == "pc-oc: ram: "*ram.dimm0.speed_mts* ]]
}

@test "probe ram as root exits 1 when a populated slot's part number is Not Specified" {
  stub_root 0
  stub_dmi <<'DMI'
Memory Device
	Size: 16 GB
	Speed: 5600 MT/s
	Part Number: Not Specified
	Configured Memory Speed: 5600 MT/s
	Configured Voltage: 1.250 V
DMI
  run --separate-stderr bash "$PROBE"
  [ "$status" -eq 1 ]
  [ "$output" = "" ]
  [[ "$stderr" == "pc-oc: ram: "*ram.dimm0.part ]]
}

@test "probe ram as root exits 1 when a slot after a valid one has Unknown values" {
  stub_root 0
  stub_dmi <<'DMI'
Memory Device
	Size: 16 GB
	Speed: 5600 MT/s
	Part Number: KF560C40-16
	Configured Memory Speed: 5600 MT/s
	Configured Voltage: 1.250 V

Memory Device
	Size: 16 GB
	Speed: Unknown
	Part Number: KF560C40-16
	Configured Memory Speed: Unknown
	Configured Voltage: Unknown
DMI
  run --separate-stderr bash "$PROBE"
  [ "$status" -eq 1 ]
  [ "$output" = "" ]
  [[ "$stderr" == "pc-oc: ram: "*ram.dimm1.speed_mts ]]
}

@test "probe ram as root exits 1 when dmidecode lists no populated DIMM" {
  stub_root 0
  stub_dmi <<'DMI'
# dmidecode 3.6
DMI
  run --separate-stderr bash "$PROBE"
  [ "$status" -eq 1 ]
  [ "$stderr" = "pc-oc: ram: no populated DIMM in dmidecode -t 17" ]
}
