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
  stock >"$file"
  cp "$file" "$orig"
  run --separate-stderr lib block_apply "$file" "$src"
  [ "$status" -eq 0 ]
  run --separate-stderr lib block_remove "$file"
  [ "$status" -eq 0 ]
  cmp "$orig" "$file"
}

@test "block_remove keeps the lines written after the block" {
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
  run --separate-stderr lib block_apply "$file" "$src"
  [ "$status" -eq 0 ]
  [ -f "$file" ]
  run --separate-stderr lib block_remove "$file"
  [ "$status" -eq 0 ]
  [ ! -e "$file" ]
}

# Check 7
@test "block_remove on a file without a block returns 0 and does not change it" {
  stock >"$file"
  cp "$file" "$orig"
  run --separate-stderr lib block_remove "$file"
  [ "$status" -eq 0 ]
  cmp "$orig" "$file"
}

@test "block_remove on a missing file returns 0 and creates nothing" {
  run --separate-stderr lib block_remove "$home/.cargo/config.toml"
  [ "$status" -eq 0 ]
  [ ! -e "$home/.cargo" ]
}

# Check 8
@test "BEGIN without END is malformed: apply and remove exit 1, bytes unchanged" {
  {
    stock
    printf '%s\n' "$BEGIN"
    cat "$src"
  } >"$file"
  malformed
}

@test "END without BEGIN is malformed: apply and remove exit 1, bytes unchanged" {
  {
    stock
    cat "$src"
    printf '%s\n' "$END"
  } >"$file"
  malformed
}

@test "END before BEGIN is malformed: apply and remove exit 1, bytes unchanged" {
  {
    stock
    printf '%s\n' "$END"
    cat "$src"
    printf '%s\n' "$BEGIN"
  } >"$file"
  malformed
}

@test "two BEGIN END pairs are malformed: apply and remove exit 1, bytes unchanged" {
  {
    stock
    block "$src"
    block "$src2"
  } >"$file"
  malformed
}

# Check 9. The link's target holds a well-formed block, so block_remove has something to do.
@test "block_apply on a symlink exits 1; the link and its target are unchanged" {
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
  stock >"$file"
  cp "$file" "$orig"
  printf 'jobs = 20\n%s\n' "$BEGIN" >"$src"
  run --separate-stderr lib block_apply "$file" "$src"
  refused
  cmp "$orig" "$file"
}

# a marker line is the marker after trailing whitespace is dropped
@test "a src holding an END line with trailing whitespace makes block_apply exit 1, file unchanged" {
  stock >"$file"
  cp "$file" "$orig"
  printf 'jobs = 20\n%s \t\njobs = 21\n' "$END" >"$src"
  run --separate-stderr lib block_apply "$file" "$src"
  refused
  cmp "$orig" "$file"
}

# Check 11
@test "block_matches is 0 after block_apply" {
  stock >"$file"
  run --separate-stderr lib block_apply "$file" "$src"
  [ "$status" -eq 0 ]
  run --separate-stderr lib block_matches "$file" "$src"
  [ "$status" -eq 0 ]
  silent
}

@test "block_matches is 1 after one byte of the body is edited" {
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
  stock >"$file"
  run --separate-stderr lib block_matches "$file" "$src"
  [ "$status" -eq 1 ]
  silent
  run --separate-stderr lib block_matches "$home/none.toml" "$src"
  [ "$status" -eq 1 ]
  silent
}

# Interface rules the Check list does not number (worker #116).

@test "block_state prints absent for a missing file and a file without markers, present after block_apply" {
  run --separate-stderr lib block_state "$home/none.toml"
  [ "$status" -eq 0 ]
  [ "$output" = absent ]
  stock >"$file"
  run --separate-stderr lib block_state "$file"
  [ "$status" -eq 0 ]
  [ "$output" = absent ]
  run --separate-stderr lib block_apply "$file" "$src"
  [ "$status" -eq 0 ]
  run --separate-stderr lib block_state "$file"
  [ "$status" -eq 0 ]
  [ "$output" = present ]
  [ -z "$stderr" ]
}

@test "nested markers are malformed: apply and remove exit 1, bytes unchanged" {
  {
    stock
    printf '%s\n%s\n' "$BEGIN" "$BEGIN"
    cat "$src"
    printf '%s\n%s\n' "$END" "$END"
  } >"$file"
  malformed
  run --separate-stderr lib block_matches "$file" "$src"
  [ "$status" -eq 1 ]
  silent
}

@test "a marker in the file with trailing whitespace is a marker line; one with leading whitespace is not" {
  {
    stock
    printf '%s \t\r\n' "$BEGIN"
    cat "$src"
    printf '%s  \n' "$END"
    printf ' %s\n' "$BEGIN"
  } >"$file"
  run --separate-stderr lib block_state "$file"
  [ "$status" -eq 0 ]
  [ "$output" = present ]
  run --separate-stderr lib block_remove "$file"
  [ "$status" -eq 0 ]
  {
    stock
    printf ' %s\n' "$BEGIN"
  } >"$want"
  cmp "$want" "$file"
}

@test "block_remove deletes the file when only whitespace is left around the block" {
  {
    printf '\n \t\n'
    block "$src"
    printf '\r\n\n'
  } >"$file"
  run --separate-stderr lib block_remove "$file"
  [ "$status" -eq 0 ]
  silent
  [ ! -e "$file" ]
  [ -z "$(ls -A "$home")" ]
}

@test "an unreadable src makes block_apply exit 1; nothing is created or changed" {
  run --separate-stderr lib block_apply "$home/.cargo/config.toml" "$BATS_TEST_TMPDIR/none.block"
  refused
  [ ! -e "$home/.cargo" ]
  stock >"$file"
  cp "$file" "$orig"
  run --separate-stderr lib block_apply "$file" "$BATS_TEST_TMPDIR"
  refused
  cmp "$orig" "$file"
  chmod 000 "$src"
  [ ! -r "$src" ] || skip "this user reads a mode 000 file"
  run --separate-stderr lib block_apply "$file" "$src"
  refused
  cmp "$orig" "$file"
  [ "$(ls -A "$home")" = config.toml ]
}

# BEGIN, src, END only holds an END line when src ends in a newline.
@test "a src that does not end in a newline makes block_apply exit 1, file unchanged; an empty src is a block with no body" {
  stock >"$file"
  cp "$file" "$orig"
  printf 'jobs = 20' >"$src"
  run --separate-stderr lib block_apply "$file" "$src"
  refused
  cmp "$orig" "$file"
  : >"$src"
  run --separate-stderr lib block_apply "$file" "$src"
  [ "$status" -eq 0 ]
  {
    stock
    printf '%s\n%s\n' "$BEGIN" "$END"
  } >"$want"
  cmp "$want" "$file"
  run --separate-stderr lib block_matches "$file" "$src"
  [ "$status" -eq 0 ]
  run --separate-stderr lib block_remove "$file"
  [ "$status" -eq 0 ]
  cmp "$orig" "$file"
}

@test "a directory as the file makes block_apply and block_remove exit 1 and stays as it was" {
  mkdir "$file"
  stock >"$file/keep"
  run --separate-stderr lib block_apply "$file" "$src"
  refused
  run --separate-stderr lib block_remove "$file"
  refused
  [ -d "$file" ]
  [ "$(ls -A "$file")" = keep ]
  [ "$(ls -A "$home")" = config.toml ]
}

# 640 and 664: neither is the 600 mktemp gives nor the 644 a new file gets.
@test "an existing file keeps its mode through append, replace and remove" {
  stock >"$file"
  chmod 640 "$file"
  run --separate-stderr lib block_apply "$file" "$src"
  [ "$status" -eq 0 ]
  [ "$(stat -c %a "$file")" = 640 ]
  run --separate-stderr lib block_apply "$file" "$src2"
  [ "$status" -eq 0 ]
  [ "$(stat -c %a "$file")" = 640 ]
  run --separate-stderr lib block_remove "$file"
  [ "$status" -eq 0 ]
  [ "$(stat -c %a "$file")" = 640 ]
  chmod 664 "$file"
  run --separate-stderr lib block_apply "$file" "$src"
  [ "$status" -eq 0 ]
  [ "$(stat -c %a "$file")" = 664 ]
}

@test "block_apply creates the file with mode 0644 under umask 077" {
  umask 077
  run --separate-stderr lib block_apply "$home/.cargo/config.toml" "$src"
  [ "$status" -eq 0 ]
  [ "$(stat -c %a "$home/.cargo/config.toml")" = 644 ]
}

@test "NUL, CRLF and non-UTF-8 bytes outside the block survive apply, replace and remove" {
  printf 'a\0b\r\n\377\376 tail\n' >"$file"
  cp "$file" "$orig"
  run --separate-stderr lib block_apply "$file" "$src"
  [ "$status" -eq 0 ]
  silent
  printf 'after\0\r\n' >>"$file"
  run --separate-stderr lib block_apply "$file" "$src2"
  [ "$status" -eq 0 ]
  silent
  {
    cat "$orig"
    block "$src2"
    printf 'after\0\r\n'
  } >"$want"
  cmp "$want" "$file"
  run --separate-stderr lib block_remove "$file"
  [ "$status" -eq 0 ]
  silent
  {
    cat "$orig"
    printf 'after\0\r\n'
  } >"$want"
  cmp "$want" "$file"
}

@test "apply, replace, remove and a refusal leave no other file in the directory, also for a relative name holding =" {
  # relative on purpose: awk reads an operand of the form name=value as an assignment
  local named='a=b.toml'
  cd "$home"
  stock >"$named"
  cp "$named" "$orig"
  run --separate-stderr lib block_apply "$named" "$src"
  [ "$status" -eq 0 ]
  [ "$(ls -A "$home")" = 'a=b.toml' ]
  run --separate-stderr lib block_apply "$named" "$src2"
  [ "$status" -eq 0 ]
  [ "$(ls -A "$home")" = 'a=b.toml' ]
  printf '%s\n' "$BEGIN" >"$src"
  run --separate-stderr lib block_apply "$named" "$src"
  refused
  [ "$(ls -A "$home")" = 'a=b.toml' ]
  run --separate-stderr lib block_remove "$named"
  [ "$status" -eq 0 ]
  [ "$(ls -A "$home")" = 'a=b.toml' ]
  cmp "$orig" "$named"
}

@test "block_apply with the src the block already holds does not rewrite the file" {
  stock >"$file"
  run --separate-stderr lib block_apply "$file" "$src"
  [ "$status" -eq 0 ]
  local inode
  inode="$(stat -c %i "$file")"
  run --separate-stderr lib block_apply "$file" "$src"
  [ "$status" -eq 0 ]
  [ "$(stat -c %i "$file")" = "$inode" ]
}

# Review of PR #132 (worker #116).

# lib_ifs <global|local> <fn> [args...]: like lib, from a caller that set IFS=$'\n\t' for the
# whole script (global) or calls from a function holding `local IFS=,` (local).
lib_ifs() {
  bash -c 'source "$1/common.sh"; source "$1/block.sh"; mode="$2"; shift 2
    if [[ "$mode" == global ]]; then
      IFS="$(printf "\n\t")"
      "$@"
    else
      caller() {
        local IFS=,
        "$@"
      }
      caller "$@"
    fi' _ "$LIB" "$@"
}

# lib_env <NAME=value> <fn> [args...]: like lib, with one environment variable set for the call.
lib_env() {
  env "$1" bash -c 'source "$1/common.sh"; source "$1/block.sh"; shift; "$@"' _ "$LIB" "${@:2}"
}

@test "state, matches, replace and remove give the same result under a caller's IFS" {
  local mode
  for mode in global local; do
    {
      stock
      block "$src"
      printf '\n[alias]\nb = "build"\n'
    } >"$file"
    run --separate-stderr lib_ifs "$mode" block_state "$file"
    [ "$status" -eq 0 ]
    [ "$output" = present ]
    [ -z "$stderr" ]
    run --separate-stderr lib_ifs "$mode" block_matches "$file" "$src"
    [ "$status" -eq 0 ]
    silent
    run --separate-stderr lib_ifs "$mode" block_apply "$file" "$src2"
    [ "$status" -eq 0 ]
    silent
    {
      stock
      block "$src2"
      printf '\n[alias]\nb = "build"\n'
    } >"$want"
    cmp "$want" "$file"
    run --separate-stderr lib_ifs "$mode" block_remove "$file"
    [ "$status" -eq 0 ]
    silent
    {
      stock
      printf '\n[alias]\nb = "build"\n'
    } >"$want"
    cmp "$want" "$file"
    run --separate-stderr lib_ifs "$mode" block_state "$file"
    [ "$status" -eq 0 ]
    [ "$output" = absent ]
  done
}

# A temp file made anywhere but next to the file would go to TMPDIR.
@test "block_apply and block_remove work with TMPDIR pointing at a missing directory" {
  local tmpdir="TMPDIR=$BATS_TEST_TMPDIR/none"
  local new="$home/.cargo/config.toml"
  run --separate-stderr lib_env "$tmpdir" block_apply "$new" "$src"
  [ "$status" -eq 0 ]
  block "$src" >"$want"
  cmp "$want" "$new"
  run --separate-stderr lib_env "$tmpdir" block_remove "$new"
  [ "$status" -eq 0 ]
  [ ! -e "$new" ]
  stock >"$file"
  cp "$file" "$orig"
  run --separate-stderr lib_env "$tmpdir" block_apply "$file" "$src"
  [ "$status" -eq 0 ]
  run --separate-stderr lib_env "$tmpdir" block_apply "$file" "$src2"
  [ "$status" -eq 0 ]
  {
    stock
    block "$src2"
  } >"$want"
  cmp "$want" "$file"
  run --separate-stderr lib_env "$tmpdir" block_remove "$file"
  [ "$status" -eq 0 ]
  cmp "$orig" "$file"
  [ ! -e "$BATS_TEST_TMPDIR/none" ]
}

# The read-back: a mv that says 0 and moves nothing must not pass for a write.
@test "a mv that exits 0 without moving makes block_apply and block_remove exit 1, file unchanged" {
  local stub="$BATS_TEST_TMPDIR/stub"
  mkdir "$stub"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"%s/mv.log"\nexit 0\n' "$stub" >"$stub/mv"
  chmod +x "$stub/mv"
  stock >"$file"
  cp "$file" "$orig"
  run --separate-stderr lib_env "PATH=$stub:$PATH" block_apply "$file" "$src"
  refused
  cmp "$orig" "$file"
  run --separate-stderr lib_env "PATH=$stub:$PATH" block_apply "$home/new.toml" "$src"
  refused
  [ ! -e "$home/new.toml" ]
  {
    stock
    block "$src"
  } >"$file"
  cp "$file" "$orig"
  run --separate-stderr lib_env "PATH=$stub:$PATH" block_apply "$file" "$src2"
  refused
  cmp "$orig" "$file"
  run --separate-stderr lib_env "PATH=$stub:$PATH" block_remove "$file"
  refused
  cmp "$orig" "$file"
  # the stub was the mv each call reached, and no temp file stays behind
  [ "$(wc -l <"$stub/mv.log")" -eq 4 ]
  [ "$(ls -A "$home")" = config.toml ]
}
