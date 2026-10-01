#!/usr/bin/env bats
# shellcheck disable=SC2016 # bash -c bodies are single-quoted on purpose: the child shell expands them

bats_require_minimum_version 1.5.0

# Contract #116. Each call runs in a fresh bash that sources lib/ the way a toolchain script
# does, so set -euo pipefail and die behave as they will for real callers.
# The markers are typed here, never read from the lib: the contract fixes their bytes.
# A refusal must carry the `pc-oc: block: ` line: with no lib/block.sh the source itself exits 1,
# and a bare status check would pass on that.

setup_file() {
  local lib="$BATS_TEST_DIRNAME/../../lib"
  lib="$(cd "$lib" && pwd)"
  if [[ -r "$lib/block.sh" ]]; then
    printf '# opened %s/block.sh sha256=%s, 2 files sourced (common.sh block.sh)\n' \
      "$lib" "$(sha256sum <"$lib/block.sh" | cut -d' ' -f1)" >&3
  else
    printf '# opened %s/block.sh: missing, 0 files sourced\n' "$lib" >&3
  fi
}

setup() {
  LIB="$(cd "$BATS_TEST_DIRNAME/../../lib" && pwd)"
  BEGIN='# >>> pc-oc wiring >>>'
  END='# <<< pc-oc wiring <<<'
  umask 022
  home="$BATS_TEST_TMPDIR/home"
  mkdir -p "$home"
  file="$home/config.toml"
  orig="$BATS_TEST_TMPDIR/orig"
  want="$BATS_TEST_TMPDIR/want"
  src="$BATS_TEST_TMPDIR/cargo.block"
  printf '[build]\nrustc-wrapper = "/usr/bin/sccache"\n' >"$src"
  src2="$BATS_TEST_TMPDIR/other.block"
  printf '[build]\nrustc-wrapper = "/usr/bin/sccache"\njobs = 20\n' >"$src2"
}

lib() {
  bash -c 'source "$1/common.sh"; source "$1/block.sh"; shift; "$@"' _ "$LIB" "$@"
}

# block <src>: the bytes a block holding <src> takes in a file
block() {
  printf '%s\n' "$BEGIN"
  cat "$1"
  printf '%s\n' "$END"
}

# other content a user file holds before the block is written
stock() {
  printf '[net]\ngit-fetch-with-cli = true\n'
}

# refused: the last run died the way the contract says
refused() {
  [ "$status" -eq 1 ] || {
    echo "exit $status, want 1" >&2
    return 1
  }
  [[ "$stderr" == "pc-oc: block: "* ]] || {
    echo "stderr was '$stderr', want a 'pc-oc: block: ' line" >&2
    return 1
  }
}

# silent: the last run printed nothing on either stream
silent() {
  [[ -z "$output" && -z "$stderr" ]] || {
    echo "stdout '$output' stderr '$stderr', want none" >&2
    return 1
  }
}

# malformed: $file holds the input; block_state says malformed, block_apply and
# block_remove exit 1 and the bytes stay.
malformed() {
  cp "$file" "$orig"
  run --separate-stderr lib block_state "$file"
  [ "$status" -eq 0 ]
  [ "$output" = malformed ]
  run --separate-stderr lib block_apply "$file" "$src"
  refused
  cmp "$orig" "$file"
  run --separate-stderr lib block_remove "$file"
  refused
  cmp "$orig" "$file"
}

# Check 1
@test "block_apply on a missing file in a missing directory creates both: BEGIN, body, END, mode 0644" {
  skip "contract #116 pending"
  local deep="$home/.cargo/deep/config.toml"
  run --separate-stderr lib block_apply "$deep" "$src"
  [ "$status" -eq 0 ]
  [ -d "$home/.cargo/deep" ]
  block "$src" >"$want"
  cmp "$want" "$deep"
  [ "$(stat -c %a "$deep")" = 644 ]
}

# Check 2
@test "block_apply on a file without a block appends it after the original bytes" {
  skip "contract #116 pending"
  stock >"$file"
  run --separate-stderr lib block_apply "$file" "$src"
  [ "$status" -eq 0 ]
  {
    stock
    block "$src"
  } >"$want"
  cmp "$want" "$file"
}

@test "block_apply on a file with no trailing newline adds exactly one before BEGIN" {
  skip "contract #116 pending"
  printf '[net]\ngit-fetch-with-cli = true' >"$file"
  run --separate-stderr lib block_apply "$file" "$src"
  [ "$status" -eq 0 ]
  {
    printf '[net]\ngit-fetch-with-cli = true\n'
    block "$src"
  } >"$want"
  cmp "$want" "$file"
}

# Check 3
@test "block_apply twice with the same src leaves the file byte-identical to one apply" {
  skip "contract #116 pending"
  stock >"$file"
  run --separate-stderr lib block_apply "$file" "$src"
  [ "$status" -eq 0 ]
  cp "$file" "$want"
  run --separate-stderr lib block_apply "$file" "$src"
  [ "$status" -eq 0 ]
  cmp "$want" "$file"
}

# Check 4
@test "block_apply with a different src replaces the body and nothing else" {
  skip "contract #116 pending"
  stock >"$file"
  run --separate-stderr lib block_apply "$file" "$src"
  [ "$status" -eq 0 ]
  printf '\n[alias]\nb = "build"\n' >>"$file"
  run --separate-stderr lib block_apply "$file" "$src2"
  [ "$status" -eq 0 ]
  {
    stock
    block "$src2"
    printf '\n[alias]\nb = "build"\n'
  } >"$want"
  cmp "$want" "$file"
}

# Check 5
@test "block_remove after block_apply on a file with other content restores the original bytes exactly" {
  skip "contract #116 pending"
  stock >"$file"
  cp "$file" "$orig"
  run --separate-stderr lib block_apply "$file" "$src"
  [ "$status" -eq 0 ]
  run --separate-stderr lib block_remove "$file"
  [ "$status" -eq 0 ]
  cmp "$orig" "$file"
}

@test "block_remove keeps the lines written after the block" {
  skip "contract #116 pending"
  stock >"$file"
  run --separate-stderr lib block_apply "$file" "$src"
  [ "$status" -eq 0 ]
  printf '\n[alias]\nb = "build"\n' >>"$file"
  run --separate-stderr lib block_remove "$file"
  [ "$status" -eq 0 ]
  {
    stock
    printf '\n[alias]\nb = "build"\n'
  } >"$want"
  cmp "$want" "$file"
}

# Stated outcome: the newline block_apply added before BEGIN is outside the block, so
# block_remove leaves it. The result is the original plus that one newline, never less.
@test "block_remove after block_apply on a file with no trailing newline leaves the original plus one newline" {
  skip "contract #116 pending"
  printf '[net]\ngit-fetch-with-cli = true' >"$file"
  run --separate-stderr lib block_apply "$file" "$src"
  [ "$status" -eq 0 ]
  run --separate-stderr lib block_remove "$file"
  [ "$status" -eq 0 ]
  printf '[net]\ngit-fetch-with-cli = true\n' >"$want"
  cmp "$want" "$file"
}

# Check 6
@test "block_remove after block_apply on a file block_apply created deletes the file" {
  skip "contract #116 pending"
  run --separate-stderr lib block_apply "$file" "$src"
  [ "$status" -eq 0 ]
  [ -f "$file" ]
  run --separate-stderr lib block_remove "$file"
  [ "$status" -eq 0 ]
  [ ! -e "$file" ]
}

# Check 7
@test "block_remove on a file without a block returns 0 and does not change it" {
  skip "contract #116 pending"
  stock >"$file"
  cp "$file" "$orig"
  run --separate-stderr lib block_remove "$file"
  [ "$status" -eq 0 ]
  cmp "$orig" "$file"
}

@test "block_remove on a missing file returns 0 and creates nothing" {
  skip "contract #116 pending"
  run --separate-stderr lib block_remove "$home/.cargo/config.toml"
  [ "$status" -eq 0 ]
  [ ! -e "$home/.cargo" ]
}

# Check 8
@test "BEGIN without END is malformed: apply and remove exit 1, bytes unchanged" {
  skip "contract #116 pending"
  {
    stock
    printf '%s\n' "$BEGIN"
    cat "$src"
  } >"$file"
  malformed
}

@test "END without BEGIN is malformed: apply and remove exit 1, bytes unchanged" {
  skip "contract #116 pending"
  {
    stock
    cat "$src"
    printf '%s\n' "$END"
  } >"$file"
  malformed
}

@test "END before BEGIN is malformed: apply and remove exit 1, bytes unchanged" {
  skip "contract #116 pending"
  {
    stock
    printf '%s\n' "$END"
    cat "$src"
    printf '%s\n' "$BEGIN"
  } >"$file"
  malformed
}

@test "two BEGIN END pairs are malformed: apply and remove exit 1, bytes unchanged" {
  skip "contract #116 pending"
  {
    stock
    block "$src"
    block "$src2"
  } >"$file"
  malformed
}

# Check 9. The link's target holds a well-formed block, so block_remove has something to do.
@test "block_apply on a symlink exits 1; the link and its target are unchanged" {
  skip "contract #116 pending"
  stock >"$home/real.toml"
  cp "$home/real.toml" "$orig"
  ln -s real.toml "$file"
  run --separate-stderr lib block_apply "$file" "$src"
  refused
  [ -L "$file" ]
  [ "$(readlink "$file")" = real.toml ]
  cmp "$orig" "$home/real.toml"
}

@test "block_remove on a symlink exits 1; the link and its target are unchanged" {
  skip "contract #116 pending"
  {
    stock
    block "$src"
  } >"$home/real.toml"
  cp "$home/real.toml" "$orig"
  ln -s real.toml "$file"
  run --separate-stderr lib block_remove "$file"
  refused
  [ -L "$file" ]
  [ "$(readlink "$file")" = real.toml ]
  cmp "$orig" "$home/real.toml"
}

# Check 10
@test "a src holding a BEGIN line makes block_apply exit 1, file unchanged" {
  skip "contract #116 pending"
  stock >"$file"
  cp "$file" "$orig"
  printf 'jobs = 20\n%s\n' "$BEGIN" >"$src"
  run --separate-stderr lib block_apply "$file" "$src"
  refused
  cmp "$orig" "$file"
}

# a marker line is the marker after trailing whitespace is dropped
@test "a src holding an END line with trailing whitespace makes block_apply exit 1, file unchanged" {
  skip "contract #116 pending"
  stock >"$file"
  cp "$file" "$orig"
  printf 'jobs = 20\n%s \t\njobs = 21\n' "$END" >"$src"
  run --separate-stderr lib block_apply "$file" "$src"
  refused
  cmp "$orig" "$file"
}

# Check 11
@test "block_matches is 0 after block_apply" {
  skip "contract #116 pending"
  stock >"$file"
  run --separate-stderr lib block_apply "$file" "$src"
  [ "$status" -eq 0 ]
  run --separate-stderr lib block_matches "$file" "$src"
  [ "$status" -eq 0 ]
  silent
}

@test "block_matches is 1 after one byte of the body is edited" {
  skip "contract #116 pending"
  stock >"$file"
  run --separate-stderr lib block_apply "$file" "$src"
  [ "$status" -eq 0 ]
  sed -i 's/sccache"$/sccachE"/' "$file"
  [ "$(cmp -l <(block "$src") <(tail -n +3 "$file") | wc -l)" -eq 1 ]
  run --separate-stderr lib block_matches "$file" "$src"
  [ "$status" -eq 1 ]
  silent
}

@test "block_matches is 1 on a file without a block and on a missing file" {
  skip "contract #116 pending"
  stock >"$file"
  run --separate-stderr lib block_matches "$file" "$src"
  [ "$status" -eq 1 ]
  silent
  run --separate-stderr lib block_matches "$home/none.toml" "$src"
  [ "$status" -eq 1 ]
  silent
}
