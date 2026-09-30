#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

# Each test runs a copy of pc-oc and lib/ so fake component folders stay out of the repo.
setup() {
  root="$BATS_TEST_TMPDIR/root"
  mkdir -p "$root"
  cp "$BATS_TEST_DIRNAME/../../pc-oc" "$root/"
  cp -r "$BATS_TEST_DIRNAME/../../lib" "$root/"
  export SYSFS_ROOT="$BATS_TEST_TMPDIR/sys"
}

fake_component() {
  mkdir -p "$root/$1"
  cat >"$root/$1/$2.sh" <<EOF
#!/usr/bin/env bash
echo "$2 $1 SYSFS_ROOT=\$SYSFS_ROOT"
EOF
}

@test "no arguments prints usage and exits 2" {
  run --separate-stderr "$root/pc-oc"
  [ "$status" -eq 2 ]
  [[ "$stderr" == usage:* ]]
}

@test "unknown verb prints usage and exits 2" {
  run --separate-stderr "$root/pc-oc" tune cpu
  [ "$status" -eq 2 ]
  [[ "$stderr" == usage:* ]]
}

@test "unknown component prints usage and exits 2" {
  run --separate-stderr "$root/pc-oc" probe cpu
  [ "$status" -eq 2 ]
  [[ "$stderr" == usage:* ]]
}

@test "a path outside the component list is refused" {
  mkdir -p "$BATS_TEST_TMPDIR/evil"
  echo 'echo pwned' >"$BATS_TEST_TMPDIR/evil/probe.sh"
  run --separate-stderr "$root/pc-oc" probe ../evil
  [ "$status" -eq 2 ]
  [[ "$output" != *pwned* ]]
}

@test "a known component runs its verb script with SYSFS_ROOT passed through" {
  fake_component cpu probe
  run "$root/pc-oc" probe cpu
  [ "$status" -eq 0 ]
  [ "$output" = "probe cpu SYSFS_ROOT=$SYSFS_ROOT" ]
}

@test "all with no component folders does nothing and exits 0" {
  run "$root/pc-oc" apply all
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "all runs every present component in order" {
  fake_component os apply
  fake_component cpu apply
  run "$root/pc-oc" apply all
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "apply cpu SYSFS_ROOT=$SYSFS_ROOT" ]
  [ "${lines[1]}" = "apply os SYSFS_ROOT=$SYSFS_ROOT" ]
}

@test "a failing component under all stops pc-oc and names the component" {
  fake_component os apply
  mkdir -p "$root/cpu"
  printf '#!/usr/bin/env bash\nexit 3\n' >"$root/cpu/apply.sh"
  run --separate-stderr "$root/pc-oc" apply all
  [ "$status" -eq 1 ]
  [ "$output" = "" ]
  [ "$stderr" = "pc-oc: cpu: apply.sh failed" ]
}

@test "a bash earlier on the caller's PATH never runs, for pc-oc or a component" {
  fake_component cpu probe
  fake_component cpu apply
  mkdir -p "$BATS_TEST_TMPDIR/evil"
  printf '#!/bin/sh\necho "fake bash ran: $*"\nexit 99\n' >"$BATS_TEST_TMPDIR/evil/bash"
  chmod +x "$BATS_TEST_TMPDIR/evil/bash"
  PATH="$BATS_TEST_TMPDIR/evil:$PATH" run "$root/pc-oc" probe cpu
  [ "$status" -eq 0 ]
  [ "$output" = "probe cpu SYSFS_ROOT=$SYSFS_ROOT" ]
  PATH="$BATS_TEST_TMPDIR/evil:$PATH" run "$root/pc-oc" apply all
  [ "$status" -eq 0 ]
  [ "$output" = "apply cpu SYSFS_ROOT=$SYSFS_ROOT" ]
}
