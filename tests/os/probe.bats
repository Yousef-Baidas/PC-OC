#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup() {
  skip "contract #10 pending"
  export SYSFS_ROOT="$BATS_TEST_TMPDIR/root"
  PROBE="$BATS_TEST_DIRNAME/../../os/probe.sh"
  mkdir -p "$SYSFS_ROOT/proc/sys/kernel" "$SYSFS_ROOT/proc/sys/vm"
  echo 6.12.1-1-cachyos >"$SYSFS_ROOT/proc/sys/kernel/osrelease"
  echo 60 >"$SYSFS_ROOT/proc/sys/vm/swappiness"
  sys="$SYSFS_ROOT/sys"
  mkdir -p "$sys/devices/system/cpu/intel_pstate" "$sys/kernel/mm/transparent_hugepage" \
    "$sys/kernel/sched_ext/root"
  echo active >"$sys/devices/system/cpu/intel_pstate/status"
  echo 'always [madvise] never' >"$sys/kernel/mm/transparent_hugepage/enabled"
  echo enabled >"$sys/kernel/sched_ext/state"
  echo scx_lavd >"$sys/kernel/sched_ext/root/ops"
  for n in 0 1 2 3; do
    write_cpu "$n" performance performance
  done
}

# write_cpu <n> <governor> <epp>
write_cpu() {
  mkdir -p "$sys/devices/system/cpu/cpu$1/cpufreq"
  echo "$2" >"$sys/devices/system/cpu/cpu$1/cpufreq/scaling_governor"
  echo "$3" >"$sys/devices/system/cpu/cpu$1/cpufreq/energy_performance_preference"
}

@test "probe os prints 9 settings for a uniform performance tree" {
  run --separate-stderr bash "$PROBE"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\nos.kernel=6.12.1-1-cachyos'* ]]
  [[ "$output" == *$'\nos.pstate_status=active'* ]]
  [[ "$output" == *$'\nos.governor=performance'* ]]
  [[ "$output" == *$'\nos.epp=performance'* ]]
  [[ "$output" == *$'\nos.governors_uniform=yes'* ]]
  [[ "$output" == *$'\nos.scx_state=enabled'* ]]
  [[ "$output" == *$'\nos.scx_ops=scx_lavd'* ]]
  [[ "$output" == *$'\nos.swappiness=60'* ]]
  [[ "$output" == *$'\nos.thp=madvise'* ]]
  [ "$((${#lines[@]} - 1))" -eq 9 ]
}

@test "probe os line 1 names the files read, their bytes and the key count" {
  run --separate-stderr bash "$PROBE"
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" =~ ^source=(/[^\ ]+)\ bytes=([0-9]+)\ items=9$ ]]
  [[ "${BASH_REMATCH[1]}" == *"$sys/kernel/sched_ext/state"* ]]
  [[ "${BASH_REMATCH[1]}" == *"$SYSFS_ROOT/proc/sys/kernel/osrelease"* ]]
  total=0
  IFS=, read -ra files <<<"${BASH_REMATCH[1]}"
  for f in "${files[@]}"; do
    total=$((total + $(wc -c <"$f")))
  done
  [ "${BASH_REMATCH[2]}" -eq "$total" ]
}

@test "probe os reports governors_uniform=no when one cpu is on powersave" {
  write_cpu 2 powersave performance
  run --separate-stderr bash "$PROBE"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\nos.governor=performance'* ]]
  [[ "$output" == *$'\nos.governors_uniform=no'* ]]
}

@test "probe os reports unsupported and none without sched_ext, exit 0" {
  rm -r "$sys/kernel/sched_ext"
  run --separate-stderr bash "$PROBE"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\nos.scx_state=unsupported'* ]]
  [[ "$output" == *$'\nos.scx_ops=none'* ]]
  [[ "${lines[0]}" =~ items=9$ ]]
}

@test "probe os exits 1 with pc-oc: os: when osrelease is missing" {
  rm "$SYSFS_ROOT/proc/sys/kernel/osrelease"
  run --separate-stderr bash "$PROBE"
  [ "$status" -eq 1 ]
  [ "$output" = "" ]
  [[ "$stderr" == "pc-oc: os: "* ]]
  [[ "$stderr" != *"not implemented"* ]]
}
