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
  skip "contract #29 pending"
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
  skip "contract #29 pending"
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
  skip "contract #29 pending"
  bash "$OS/apply.sh"
  [ "$(cat "$PC_OC_STATE/os/scx_loader.enabled")" = disabled ]
}

@test "a loader that never loads makes apply exit 1 and undo itself" {
  skip "contract #29 pending"
  MOCK_SCX_MODE=never run --separate-stderr bash "$OS/apply.sh"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"pc-oc: os: scx_lavd did not load"* ]]
  [ ! -e "$CONF" ]
  [ "$(cat "$MOCK_ENABLED")" = disabled ]
  [ -z "$(state_files)" ]
}

@test "a bpfland ops counts as a failed load" {
  skip "contract #29 pending"
  MOCK_SCX_MODE=bpfland run --separate-stderr bash "$OS/apply.sh"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"pc-oc: os: scx_lavd did not load"* ]]
  [ ! -e "$CONF" ]
  [ "$(cat "$MOCK_ENABLED")" = disabled ]
  [ "$(cat "$SX/state")" = disabled ]
}

@test "revert with no apply record exits 1" {
  skip "contract #29 pending"
  run --separate-stderr bash "$OS/revert.sh"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"pc-oc: os: nothing to revert"* ]]
  [ ! -s "$MOCK_LOG" ]
}

@test "a second apply keeps the first stock record" {
  skip "contract #29 pending"
  bash "$OS/apply.sh"
  [ "$(cat "$MOCK_ENABLED")" = enabled ]
  bash "$OS/apply.sh"
  [ "$(cat "$PC_OC_STATE/os/scx_loader.enabled")" = disabled ]
  bash "$OS/revert.sh"
  [ "$(cat "$MOCK_ENABLED")" = disabled ]
  [ ! -e "$CONF" ]
}
