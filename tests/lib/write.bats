#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

# Contract #25. Each call runs in a fresh bash that sources lib/ the way a component
# script does, so set -euo pipefail behaves as it will for real callers.

setup_file() {
  local lib="$BATS_TEST_DIRNAME/../../lib"
  lib="$(cd "$lib" && pwd)"
  printf '# opened %s/write.sh sha256=%s, 2 files sourced (common.sh write.sh)\n' \
    "$lib" "$(sha256sum <"$lib/write.sh" | cut -d' ' -f1)" >&3
}

setup() {
  LIB="$(cd "$BATS_TEST_DIRNAME/../../lib" && pwd)"
  export SYSFS_ROOT="$BATS_TEST_TMPDIR/sys" PC_OC_STATE="$BATS_TEST_TMPDIR/state"
  epp=/sys/devices/system/cpu/cpufreq/policy0/energy_performance_preference
  mkdir -p "$(dirname "$SYSFS_ROOT$epp")" "$SYSFS_ROOT/etc/scx_loader" "$BATS_TEST_TMPDIR/src"
  printf 'balance_performance\n' >"$SYSFS_ROOT$epp"
  src="$BATS_TEST_TMPDIR/src/config.toml"
  printf 'default_sched = "scx_lavd"\ndefault_mode = "Gaming"\n' >"$src"
}

lib() {
  bash -c 'source "$1/common.sh"; source "$1/write.sh"; shift; "$@"' _ "$LIB" "$@"
}

sha() {
  sha256sum <"$1" | cut -d' ' -f1
}

# every file the helper left under the state dir; empty when no backup is pending
leftovers() {
  find "$PC_OC_STATE" -type f 2>/dev/null || :
}

@test "sys_write then sys_restore gives byte-identical stock and no backup left" {
  stock="$(sha "$SYSFS_ROOT$epp")"
  run --separate-stderr lib sys_write "$epp" performance
  [ "$status" -eq 0 ]
  [ "$(<"$SYSFS_ROOT$epp")" = performance ]
  run --separate-stderr lib sys_restore "$epp"
  [ "$status" -eq 0 ]
  [ "$(sha "$SYSFS_ROOT$epp")" = "$stock" ]
  [ -z "$(leftovers)" ]
}

@test "a second sys_write keeps the first backup, so restore gives stock" {
  stock="$(sha "$SYSFS_ROOT$epp")"
  run --separate-stderr lib sys_write "$epp" performance
  [ "$status" -eq 0 ]
  run --separate-stderr lib sys_write "$epp" power
  [ "$status" -eq 0 ]
  [ "$(<"$SYSFS_ROOT$epp")" = power ]
  run --separate-stderr lib sys_restore "$epp"
  [ "$status" -eq 0 ]
  [ "$(sha "$SYSFS_ROOT$epp")" = "$stock" ]
}

@test "sys_write exits 1 naming want and got when the target ignores writes" {
  # a symlink to /dev/null accepts every write and always reads back empty
  mkdir -p "$SYSFS_ROOT/sys/fake"
  ln -s /dev/null "$SYSFS_ROOT/sys/fake/ignores_writes"
  run --separate-stderr lib sys_write /sys/fake/ignores_writes 7
  [ "$status" -eq 1 ]
  [[ "${stderr_lines[-1]}" == "pc-oc: lib: readback /sys/fake/ignores_writes: want 7 got"* ]]
}

@test "sys_restore with no backup exits 1 and leaves the target alone" {
  stock="$(sha "$SYSFS_ROOT$epp")"
  run --separate-stderr lib sys_restore "$epp"
  [ "$status" -eq 1 ]
  [ "$stderr" = "pc-oc: lib: no backup for $epp" ]
  [ "$(sha "$SYSFS_ROOT$epp")" = "$stock" ]
}

@test "file_install then file_restore on an absent dest removes it again" {
  dest=/etc/scx_loader/config.toml
  run --separate-stderr lib file_install "$src" "$dest"
  [ "$status" -eq 0 ]
  cmp "$src" "$SYSFS_ROOT$dest"
  run --separate-stderr lib file_restore "$dest"
  [ "$status" -eq 0 ]
  [ ! -e "$SYSFS_ROOT$dest" ]
  [ -z "$(leftovers)" ]
}

@test "file_install then file_restore on an existing dest gives the original bytes" {
  dest=/etc/scx_loader/config.toml
  printf 'default_sched = "scx_bpfland"\n' >"$SYSFS_ROOT$dest"
  stock="$(sha "$SYSFS_ROOT$dest")"
  run --separate-stderr lib file_install "$src" "$dest"
  [ "$status" -eq 0 ]
  cmp "$src" "$SYSFS_ROOT$dest"
  run --separate-stderr lib file_restore "$dest"
  [ "$status" -eq 0 ]
  [ "$(sha "$SYSFS_ROOT$dest")" = "$stock" ]
  [ -z "$(leftovers)" ]
}

@test "paths with spaces work for sys_write, sys_restore, file_install, file_restore" {
  knob="/sys/fake dir/a knob"
  dest="/etc/fake dir/a file.conf"
  mkdir -p "$SYSFS_ROOT/sys/fake dir" "$SYSFS_ROOT/etc/fake dir"
  printf '0\n' >"$SYSFS_ROOT$knob"
  printf 'stock\n' >"$SYSFS_ROOT$dest"
  knob_stock="$(sha "$SYSFS_ROOT$knob")"
  dest_stock="$(sha "$SYSFS_ROOT$dest")"
  run --separate-stderr lib sys_write "$knob" 1
  [ "$status" -eq 0 ]
  [ "$(<"$SYSFS_ROOT$knob")" = 1 ]
  run --separate-stderr lib file_install "$src" "$dest"
  [ "$status" -eq 0 ]
  cmp "$src" "$SYSFS_ROOT$dest"
  run --separate-stderr lib sys_restore "$knob"
  [ "$status" -eq 0 ]
  run --separate-stderr lib file_restore "$dest"
  [ "$status" -eq 0 ]
  [ "$(sha "$SYSFS_ROOT$knob")" = "$knob_stock" ]
  [ "$(sha "$SYSFS_ROOT$dest")" = "$dest_stock" ]
  [ -z "$(leftovers)" ]
}

@test "sys_write to a read-only target exits 1 and leaves no backup behind" {
  [[ "$EUID" -ne 0 ]] || skip "root ignores file modes"
  chmod 444 "$SYSFS_ROOT$epp"
  stock="$(sha "$SYSFS_ROOT$epp")"
  run --separate-stderr lib sys_write "$epp" performance
  [ "$status" -eq 1 ]
  [[ "${stderr_lines[-1]}" == "pc-oc: lib: "* ]]
  [ "$(sha "$SYSFS_ROOT$epp")" = "$stock" ]
  [ -z "$(leftovers)" ]
  # the failed call recorded nothing, so once writable the stock backup is the real one
  chmod 644 "$SYSFS_ROOT$epp"
  run --separate-stderr lib sys_write "$epp" performance
  [ "$status" -eq 0 ]
  run --separate-stderr lib sys_restore "$epp"
  [ "$status" -eq 0 ]
  [ "$(sha "$SYSFS_ROOT$epp")" = "$stock" ]
}
