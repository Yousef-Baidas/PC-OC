#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

# Contract #26: pc-oc root hardening. The rest of pc-oc is covered in tests/lib/pc-oc.bats.
# EUID 0 seam: `unshare -r` runs pc-oc as uid 0 in a user namespace, never real root.

setup_file() {
  local f="$BATS_TEST_DIRNAME/../../pc-oc"
  f="$(cd "$(dirname "$f")" && pwd)/pc-oc"
  printf '# opened %s sha256=%s, 1 file\n' "$f" "$(sha256sum <"$f" | cut -d' ' -f1)" >&3
}

# Each test runs a copy of pc-oc and lib/ so fake component folders stay out of the repo.
setup() {
  root="$BATS_TEST_TMPDIR/root"
  mkdir -p "$root"
  cp "$BATS_TEST_DIRNAME/../../pc-oc" "$root/"
  cp -r "$BATS_TEST_DIRNAME/../../lib" "$root/"
  export SYSFS_ROOT="$BATS_TEST_TMPDIR/sys" PC_OC_STATE="$BATS_TEST_TMPDIR/state"
}

# fake_component <component> <verb> [exit status]
fake_component() {
  mkdir -p "$root/$1"
  cat >"$root/$1/$2.sh" <<EOF
#!/usr/bin/env bash
echo "$2 $1 SYSFS_ROOT=\${SYSFS_ROOT-unset} PC_OC_STATE=\${PC_OC_STATE-unset}"
exit ${3:-0}
EOF
}

@test "as EUID 0 pc-oc unsets SYSFS_ROOT and PC_OC_STATE before running a component" {
  skip "contract #26 pending"
  fake_component cpu probe
  run --separate-stderr "$root/pc-oc" probe cpu
  [ "$status" -eq 0 ]
  [ "$output" = "probe cpu SYSFS_ROOT=$SYSFS_ROOT PC_OC_STATE=$PC_OC_STATE" ]
  run --separate-stderr unshare -r "$root/pc-oc" probe cpu
  [ "$status" -eq 0 ]
  [ "$output" = "probe cpu SYSFS_ROOT=unset PC_OC_STATE=unset" ]
}

@test "revert all runs every component in reverse order past a failure, then exits 1 naming it" {
  skip "contract #26 pending"
  for c in cpu ram os toolchain; do
    fake_component "$c" revert
  done
  fake_component gpu revert 3
  run --separate-stderr "$root/pc-oc" revert all
  [ "$status" -eq 1 ]
  [ "${#lines[@]}" -eq 5 ]
  [[ "${lines[0]}" == "revert toolchain "* ]]
  [[ "${lines[1]}" == "revert os "* ]]
  [[ "${lines[2]}" == "revert gpu "* ]]
  [[ "${lines[3]}" == "revert ram "* ]]
  [[ "${lines[4]}" == "revert cpu "* ]]
  [[ "${stderr_lines[-1]}" == "pc-oc: "*gpu* ]]
}
