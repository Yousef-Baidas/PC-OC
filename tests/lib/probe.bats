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
