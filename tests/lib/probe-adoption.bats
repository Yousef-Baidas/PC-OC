#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup() {
  ROOT="$BATS_TEST_DIRNAME/../.."
}

# fail <msg>: say what is wrong, then fail the case.
fail() {
  echo "ADOPTION FAIL: $1" >&3
  return 1
}

# assert_adopted <component>: probe.sh uses the lib helpers, not its own header.
assert_adopted() {
  local probe="$ROOT/$1/probe.sh"
  echo "adoption: $probe, $(wc -c <"$probe") bytes, $(wc -l <"$probe") lines" >&3
  grep -q 'lib/common.sh' "$probe" || fail "$1: does not source lib/common.sh"
  grep -q 'probe_emit' "$probe" || fail "$1: does not call probe_emit"
  ! grep -q "printf 'source=" "$probe" || fail "$1: hand-rolls printf 'source='"
  ! grep -Eq 'wc -c|(^|[^a-z_])bytes=' "$probe" || fail "$1: has its own byte counter"
}

@test "cpu probe uses probe_emit and no own header or byte counter" {
  skip "adopted in #37"
  assert_adopted cpu
}

@test "ram probe uses probe_emit and no own header or byte counter" {
  skip "adopted in #37"
  assert_adopted ram
}

@test "gpu probe uses probe_emit and no own header or byte counter" {
  skip "adopted in #38"
  assert_adopted gpu
}

@test "os probe uses probe_emit and no own header or byte counter" {
  skip "contract #36 pending"
  assert_adopted os
}
