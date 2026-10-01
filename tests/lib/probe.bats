#!/usr/bin/env bats
# shellcheck disable=SC2016 # probe bodies are single-quoted on purpose: the child shell expands them

bats_require_minimum_version 1.5.0

setup() {
  LIB="$BATS_TEST_DIRNAME/../../lib/common.sh"
  export FIX="$BATS_TEST_DIRNAME/fixtures/probe"
  export TWO="$FIX/two-lines.txt"
  export NONL="$FIX/no-newline.txt"
  # Fixture sizes: two-lines.txt is 20 bytes, no-newline.txt is 4.
  echo "probe fixtures: $FIX, $(wc -c <"$TWO") + $(wc -c <"$NONL") bytes, 2 files" >&3
}

# run_probe <body>: run <body> in a fresh shell that sourced lib/common.sh.
run_probe() {
  run --separate-stderr bash -c 'set -euo pipefail; source "$1"; PROBE_COMPONENT=demo; eval "$2"' _ "$LIB" "$1"
}

@test "probe_emit counts and sums over two fixture files" {
  run_probe 'probe_read "$TWO"; first=$REPLY; probe_read "$NONL"; probe_emit first="$first" second="$REPLY"'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "source=$TWO,$NONL bytes=24 items=2" ]
  [ "${lines[1]}" = "demo.first=alpha" ]
  [ "${lines[2]}" = "demo.second=beta" ]
  [ "${#lines[@]}" -eq 3 ]
}

@test "probe_read counts a file with no trailing newline by its real size" {
  run_probe 'probe_read "$NONL"; probe_emit v="$REPLY"'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "source=$NONL bytes=4 items=1" ]
}

@test "probe_read sets PROBE_CONTENT to every line, and bytes= is its size" {
  run_probe 'probe_read "$TWO"; want=$(printf "alpha  \nsecond line\n"; echo x); [ "${PROBE_CONTENT}x" = "$want" ] && probe_emit same=yes'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "source=$TWO bytes=20 items=1" ]
  [ "${lines[1]}" = "demo.same=yes" ]
}

@test "adding a key bumps items=" {
  run_probe 'probe_read "$NONL"; probe_emit a=1 b=2 c=3'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "source=$NONL bytes=4 items=3" ]
  run_probe 'probe_read "$NONL"; probe_emit a=1 b=2 c=3 d=4'
  [ "${lines[0]}" = "source=$NONL bytes=4 items=4" ]
}

@test "an unreadable path exits 1 naming the component" {
  run_probe 'probe_read "$FIX/missing.txt"; probe_emit v="$REPLY"'
  [ "$status" -eq 1 ]
  [ "$output" = "" ]
  [ "$stderr" = "pc-oc: demo: cannot read $FIX/missing.txt" ]
}

@test "probe_source records a non-file source" {
  run_probe 'probe_source nvidia-smi 120; probe_read "$NONL"; probe_emit v="$REPLY"'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "source=nvidia-smi,$NONL bytes=124 items=1" ]
}

# Contract #46: probe_run. PROBE_CMD_DIR holds stub commands; STUB_OUT is what stubcmd prints (printf %b).
# stub_bytes <out>: the real size of what stubcmd prints, by running it under wc -c.
stub_bytes() {
  STUB_OUT="$1" "$PROBE_CMD_DIR/stubcmd" | wc -c
}

setup_stubs() {
  export PROBE_CMD_DIR="$BATS_TEST_TMPDIR/stubs"
  mkdir -p "$PROBE_CMD_DIR"
  printf '#!/bin/bash\nprintf "%%b" "$STUB_OUT"\n' >"$PROBE_CMD_DIR/stubcmd"
  printf '#!/bin/bash\nprintf "partial\\n"\nexit 3\n' >"$PROBE_CMD_DIR/failcmd"
  chmod +x "$PROBE_CMD_DIR/stubcmd" "$PROBE_CMD_DIR/failcmd"
  export PATH="$PROBE_CMD_DIR:$PATH"
  echo "stubs: $PROBE_CMD_DIR, 2 commands" >&3
}

@test "probe_run bytes= is the real size for one newline, none, and two" {
  setup_stubs
  local out want
  for out in 'one line\n' 'no newline' 'two\n\n' 'a\nb\n\n\n'; do
    want="$(stub_bytes "$out")"
    STUB_OUT="$out" run_probe 'probe_run stubcmd; probe_emit v="$REPLY"'
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "source=$PROBE_CMD_DIR/stubcmd bytes=$want items=1" ]
  done
}

@test "probe_run source= is the stub's absolute path" {
  setup_stubs
  STUB_OUT='x\n' run_probe 'probe_run stubcmd; probe_emit v=1'
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == "source=/"* ]]
  [[ "${lines[0]}" == "source=$PROBE_CMD_DIR/stubcmd bytes="* ]]
}

@test "probe_run passes args, sets REPLY to the trimmed first line" {
  setup_stubs
  STUB_OUT='first  \nsecond\n' run_probe 'probe_run stubcmd; probe_emit v="[$REPLY]"'
  [ "$status" -eq 0 ]
  [ "${lines[1]}" = "demo.v=[first]" ]
}

@test "probe_run PROBE_CONTENT keeps trailing newlines" {
  setup_stubs
  STUB_OUT='a\n\n\n' run_probe 'probe_run stubcmd; [ "${PROBE_CONTENT}x" = "$(printf "a\n\n\n"; echo x)" ] && probe_emit same=yes'
  [ "$status" -eq 0 ]
  [ "${lines[1]}" = "demo.same=yes" ]
}

@test "probe_run on a missing command dies not found" {
  setup_stubs
  run_probe 'probe_run no-such-cmd-xyz; probe_emit v=1'
  [ "$status" -eq 1 ]
  [ "$output" = "" ]
  [ "$stderr" = "pc-oc: demo: no-such-cmd-xyz not found" ]
}

@test "probe_run on a failing command dies failed" {
  setup_stubs
  run_probe 'probe_run failcmd; probe_emit v=1'
  [ "$status" -eq 1 ]
  [ "$output" = "" ]
  [ "$stderr" = "pc-oc: demo: failcmd failed" ]
}

@test "probe_run counts bytes, not characters, under a UTF-8 locale" {
  skip "contract #46 pending"
  setup_stubs
  LC_ALL=C.UTF-8 STUB_OUT='héllo €\n' run_probe 'probe_run stubcmd; probe_emit v=1'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "source=$PROBE_CMD_DIR/stubcmd bytes=11 items=1" ]
}

@test "probe_run runs the command exactly once" {
  skip "contract #46 pending"
  setup_stubs
  export COUNTER="$BATS_TEST_TMPDIR/runs"
  printf '#!/bin/bash\necho run >>"$COUNTER"\nprintf "x\\n"\n' >"$PROBE_CMD_DIR/countcmd"
  chmod +x "$PROBE_CMD_DIR/countcmd"
  run_probe 'probe_run countcmd; probe_emit v=1'
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$COUNTER")" -eq 1 ]
}

@test "probe_run drops NUL bytes: rc 0 and bytes= counts the bytes kept" {
  skip "contract #46 pending"
  setup_stubs
  STUB_OUT='a\0b\n' run_probe 'probe_run stubcmd; probe_emit v="$REPLY"'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "source=$PROBE_CMD_DIR/stubcmd bytes=3 items=1" ]
  [ "${lines[1]}" = "demo.v=ab" ]
}
