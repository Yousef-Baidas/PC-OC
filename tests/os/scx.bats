#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

# The contract for #29: os/apply.sh and os/revert.sh load scx_lavd through scx_loader.
# Mock systemctl and sleep come first on PATH; SYSFS_ROOT and PC_OC_STATE are fakes.
# SCX_OS_DIR repoints the scripts at a scratch copy, to watch the cases go red.

setup_file() {
  FIX="$BATS_TEST_DIRNAME/fixtures/scx"
  printf '%s %sB %s mocks\n' "$FIX/bin" "$(cat "$FIX"/bin/* | wc -c)" "$(find "$FIX/bin" -type f | wc -l)" >&3
}

setup() {
  unset "${!GIT_@}"
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  OS="${SCX_OS_DIR:-$ROOT/os}"
  export SYSFS_ROOT="$BATS_TEST_TMPDIR/root"
  export PC_OC_STATE="$BATS_TEST_TMPDIR/state"
  export MOCK_LOG="$BATS_TEST_TMPDIR/systemctl.log"
  export MOCK_ENABLED="$BATS_TEST_TMPDIR/enabled"
  export PATH="$BATS_TEST_DIRNAME/fixtures/scx/bin:$PATH"
  CONF="$SYSFS_ROOT/etc/scx_loader/config.toml"
  SX="$SYSFS_ROOT/sys/kernel/sched_ext"
  mkdir -p "$SX" "$PC_OC_STATE"
  echo disabled >"$SX/state"
  echo disabled >"$MOCK_ENABLED"
  : >"$MOCK_LOG"
}

state_files() {
  find "$PC_OC_STATE" -type f
}

@test "apply loads the config and scx_lavd, revert puts stock back" {
  run --separate-stderr bash "$OS/apply.sh"
  [ "$status" -eq 0 ]
  cmp "$OS/scx_loader.toml" "$CONF"
  [ "$(cat "$SX/state")" = enabled ]
  [[ "$(cat "$SX/root/ops")" == lavd* ]]
  [ "$(cat "$MOCK_ENABLED")" = enabled ]
  run --separate-stderr bash "$OS/revert.sh"
  [ "$status" -eq 0 ]
  [ ! -e "$CONF" ]
  [ "$(cat "$MOCK_ENABLED")" = disabled ]
  [ "$(cat "$SX/state")" = disabled ]
  [ -z "$(state_files)" ]
}

@test "systemctl calls come in the contract order" {
  bash "$OS/apply.sh"
  bash "$OS/revert.sh"
  run cat "$MOCK_LOG"
  [ "$output" = "is-enabled scx_loader
enable scx_loader
restart scx_loader
stop scx_loader
disable scx_loader" ]
}

@test "apply records the stock enabled state" {
  bash "$OS/apply.sh"
  [ "$(cat "$PC_OC_STATE/os/scx_loader.enabled")" = disabled ]
}

@test "a loader that never loads makes apply exit 1 and undo itself" {
  MOCK_SCX_MODE=never run --separate-stderr bash "$OS/apply.sh"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"pc-oc: os: scx_lavd did not load"* ]]
  [ ! -e "$CONF" ]
  [ "$(cat "$MOCK_ENABLED")" = disabled ]
  [ -z "$(state_files)" ]
}

@test "a bpfland ops counts as a failed load" {
  MOCK_SCX_MODE=bpfland run --separate-stderr bash "$OS/apply.sh"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"pc-oc: os: scx_lavd did not load"* ]]
  [ ! -e "$CONF" ]
  [ "$(cat "$MOCK_ENABLED")" = disabled ]
  [ "$(cat "$SX/state")" = disabled ]
}

@test "revert with no apply record exits 1" {
  run --separate-stderr bash "$OS/revert.sh"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"pc-oc: os: nothing to revert"* ]]
  [ ! -s "$MOCK_LOG" ]
}

@test "a second apply keeps the first stock record" {
  bash "$OS/apply.sh"
  [ "$(cat "$MOCK_ENABLED")" = enabled ]
  bash "$OS/apply.sh"
  [ "$(cat "$PC_OC_STATE/os/scx_loader.enabled")" = disabled ]
  bash "$OS/revert.sh"
  [ "$(cat "$MOCK_ENABLED")" = disabled ]
  [ ! -e "$CONF" ]
}

# review round 1: failure paths
# fail_verb <verb>: write a systemctl that fails <verb>, else runs the mock; put $FAIL_BIN first on PATH
fail_verb() {
  FAIL_BIN="$BATS_TEST_TMPDIR/fail"
  mkdir -p "$FAIL_BIN"
  {
    echo '#!/usr/bin/env bash'
    echo "[[ \"\$1\" != $1 ]] || exit 5"
    echo "exec \"$BATS_TEST_DIRNAME/fixtures/scx/bin/systemctl\" \"\$@\""
  } >"$FAIL_BIN/systemctl"
  chmod +x "$FAIL_BIN/systemctl"
}

@test "a failure before the install leaves the state dir empty and the loader alone" {
  mkdir -p "$SYSFS_ROOT/etc"
  chmod 500 "$SYSFS_ROOT/etc"
  run --separate-stderr bash "$OS/apply.sh"
  chmod 700 "$SYSFS_ROOT/etc"
  [ "$status" -eq 1 ]
  [ -z "$(state_files)" ]
  [ "$(cat "$MOCK_LOG")" = "is-enabled scx_loader" ]
  run --separate-stderr bash "$OS/revert.sh"
  [[ "$stderr" == *"pc-oc: os: nothing to revert"* ]]
}

@test "a revert that fails at disable reruns to stock" {
  bash "$OS/apply.sh"
  fail_verb disable
  PATH="$FAIL_BIN:$PATH" run --separate-stderr bash "$OS/revert.sh"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"pc-oc: os: systemctl disable scx_loader failed"* ]]
  run --separate-stderr bash "$OS/revert.sh"
  [ "$status" -eq 0 ]
  [ ! -e "$CONF" ]
  [ "$(cat "$MOCK_ENABLED")" = disabled ]
  [ -z "$(state_files)" ]
}

@test "a revert that fails at stop reruns to stock" {
  bash "$OS/apply.sh"
  fail_verb stop
  PATH="$FAIL_BIN:$PATH" run --separate-stderr bash "$OS/revert.sh"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"pc-oc: os: systemctl stop scx_loader failed"* ]]
  run --separate-stderr bash "$OS/revert.sh"
  [ "$status" -eq 0 ]
  [ ! -e "$CONF" ]
  [ "$(cat "$MOCK_ENABLED")" = disabled ]
  [ -z "$(state_files)" ]
}

@test "revert keeps a stock /etc/scx_loader dir, removes one apply made" {
  mkdir -p "$SYSFS_ROOT/etc/scx_loader"
  bash "$OS/apply.sh"
  bash "$OS/revert.sh"
  [ -d "$SYSFS_ROOT/etc/scx_loader" ]
  rmdir "$SYSFS_ROOT/etc/scx_loader"
  bash "$OS/apply.sh"
  bash "$OS/revert.sh"
  [ ! -e "$SYSFS_ROOT/etc/scx_loader" ]
}

@test "an is-enabled that fails makes apply exit 1 with nothing changed" {
  fail_verb is-enabled
  PATH="$FAIL_BIN:$PATH" run --separate-stderr bash "$OS/apply.sh"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"pc-oc: os: cannot read scx_loader enabled state"* ]]
  [ -z "$(state_files)" ]
  [ "$(cat "$MOCK_ENABLED")" = disabled ]
  [ ! -e "$CONF" ]
  run --separate-stderr bash "$OS/revert.sh"
  [[ "$stderr" == *"pc-oc: os: nothing to revert"* ]]
}

@test "an enable or restart that fails makes apply exit 1 and undo itself" {
  local verb
  for verb in enable restart; do
    fail_verb "$verb"
    PATH="$FAIL_BIN:$PATH" run --separate-stderr bash "$OS/apply.sh"
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"pc-oc: os: systemctl $verb scx_loader failed"* ]]
    [ ! -e "$CONF" ]
    [ "$(cat "$MOCK_ENABLED")" = disabled ]
    [ -z "$(state_files)" ]
  done
}
