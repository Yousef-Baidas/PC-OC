#!/usr/bin/env bats
# Contract #119: what the wiring does, cases 7, 8, 9 and 11 of the ticket, and the bytes of
# the three block data files. apply runs in a fake home under the bats temp dir, behind
# fixtures/guard.sh; then the python3, the fish and the makepkg library of this PC read
# that home, each started with an environment that holds HOME (the fake home) and PATH only.
bats_require_minimum_version 1.5.0
load fixtures/helper

setup() {
  common_setup
}

# rustc_wrapper: what Cargo's parser of record (TOML) finds as build.rustc-wrapper
rustc_wrapper() {
  run --separate-stderr timeout -k 5 30 /usr/bin/env -i "HOME=$H" PATH=/usr/bin \
    /usr/bin/python3 -c \
    'import tomllib,sys; print(tomllib.load(open(sys.argv[1],"rb"))["build"]["rustc-wrapper"])' \
    "$CARGO"
}

# in_fish <commands>: a fish that reads the fake home's config.fish and finds the mock
# cmake (it prints arg=<argument> lines, then its environment) first on PATH
in_fish() {
  mkdir -p "$BATS_TEST_TMPDIR/first" "$BATS_TEST_TMPDIR/run"
  mock_at "$BATS_TEST_TMPDIR/first/cmake"
  run --separate-stderr timeout -k 5 30 /usr/bin/env -i "HOME=$H" \
    "XDG_RUNTIME_DIR=$BATS_TEST_TMPDIR/run" "PATH=$BATS_TEST_TMPDIR/first:/usr/bin" \
    /usr/bin/fish -c "$1"
}

# makepkg_reads [NAME=value]: LDFLAGS, then the first PATH entry, as makepkg has them after
# it read its configuration for the fake home
makepkg_reads() {
  # shellcheck disable=SC2016 # the inner bash expands LDFLAGS and PATH after the config ran
  run --separate-stderr timeout -k 5 30 /usr/bin/env -i "HOME=$H" PATH=/usr/bin "$@" \
    /usr/bin/bash -c 'source /usr/share/makepkg/util/config.sh; source_makepkg_config
      echo "$LDFLAGS"; echo "${PATH%%:*}"'
}

@test "the three block data files hold the bytes of the ticket" {
  local name
  for name in "${NAMES[@]}"; do
    cmp "$ROOT/toolchain/$name.block" "$FIX/$name.block"
  done
}

@test "case 7: after apply Cargo's TOML has build.rustc-wrapper = /usr/bin/sccache" {
  apply
  status_is 0
  rustc_wrapper
  status_is 0
  [[ "$output" == /usr/bin/sccache ]]
}

@test "case 7: the same when the Cargo file had a [net] table before" {
  stock cargo
  apply
  status_is 0
  rustc_wrapper
  status_is 0
  [[ "$output" == /usr/bin/sccache ]]
  run --separate-stderr timeout -k 5 30 /usr/bin/env -i "HOME=$H" PATH=/usr/bin \
    /usr/bin/python3 -c \
    'import tomllib,sys; print(tomllib.load(open(sys.argv[1],"rb"))["net"]["git-fetch-with-cli"])' \
    "$CARGO"
  status_is 0
  [[ "$output" == True ]]
}

# shellcheck disable=SC2016 # fish expands $status in the two scripts, this shell must not
@test "case 8: fish runs cmake with both launchers and LDFLAGS=-fuse-ld=mold, and nothing leaks into the shell" {
  local script='cmake -B "build dir" x; set -q LDFLAGS; echo $status'
  local leak='cmake x >/dev/null
    set -q CMAKE_C_COMPILER_LAUNCHER CMAKE_CXX_COMPILER_LAUNCHER LDFLAGS; echo $status'
  # without the wiring the mock cmake sees none of the three, so the case can tell
  in_fish "$script"
  status_is 0
  [[ "${lines[2]}" == arg=x && "${lines[-1]}" == 1 ]]
  [[ "$output" != *COMPILER_LAUNCHER=* && "$output" != *LDFLAGS=* ]]
  apply
  status_is 0
  in_fish "$script"
  status_is 0
  [[ "${lines[0]}" == arg=-B && "${lines[1]}" == "arg=build dir" && "${lines[2]}" == arg=x ]]
  grep -qxF 'CMAKE_C_COMPILER_LAUNCHER=sccache' <<<"$output"
  grep -qxF 'CMAKE_CXX_COMPILER_LAUNCHER=sccache' <<<"$output"
  grep -qxF 'LDFLAGS=-fuse-ld=mold' <<<"$output"
  [[ "${lines[-1]}" == 1 ]]
  in_fish "$leak"
  status_is 0
  [[ "$output" == 3 ]]
}

@test "case 8: fish --no-execute accepts toolchain/fish.block" {
  mkdir "$BATS_TEST_TMPDIR/run"
  run --separate-stderr timeout -k 5 30 /usr/bin/env -i "HOME=$H" \
    "XDG_RUNTIME_DIR=$BATS_TEST_TMPDIR/run" PATH=/usr/bin \
    /usr/bin/fish --no-execute "$ROOT/toolchain/fish.block"
  status_is 0
  [[ -s "$ROOT/toolchain/fish.block" ]]
}

@test "case 9: makepkg's configuration ends LDFLAGS in -fuse-ld=mold and starts PATH with /usr/lib/sccache/bin, and PC_OC_NO_WIRING=1 takes both out" {
  local stock_out
  makepkg_reads
  status_is 0
  stock_out="$output"
  # the case can only tell the wiring from a system configuration that has none
  [[ "$stock_out" != *-fuse-ld=mold* && "$stock_out" != *sccache* ]]
  apply
  status_is 0
  makepkg_reads
  status_is 0
  [[ "$output" == "${stock_out%$'\n'*} -fuse-ld=mold"$'\n'/usr/lib/sccache/bin ]]
  makepkg_reads PC_OC_NO_WIRING=1
  status_is 0
  [[ "$output" == "$stock_out" ]]
}

@test "case 9: the same below other lines of a makepkg file" {
  stock makepkg
  apply
  status_is 0
  makepkg_reads
  status_is 0
  [[ "${output%$'\n'*}" == *" -fuse-ld=mold" && "${output##*$'\n'}" == /usr/lib/sccache/bin ]]
  makepkg_reads PC_OC_NO_WIRING=1
  status_is 0
  [[ "$output" != *-fuse-ld=mold* && "$output" != *sccache* ]]
}

@test "case 11: every # src: id of the three data files is one row of sources/manifest.tsv" {
  local name id n
  for name in "${NAMES[@]}"; do
    n=0
    while IFS= read -r id; do
      n=$((n + 1))
      [[ "$(cut -f1 "$ROOT/sources/manifest.tsv" | grep -cxF -- "$id")" -eq 1 ]] || {
        echo "$name.block: the id $id is not exactly one row of sources/manifest.tsv" >&2
        return 1
      }
    done < <(sed -n 's/^# src: *//p' "$ROOT/toolchain/$name.block" | tr ',' '\n' |
      sed 's/^ *//; s/ *$//')
    [[ "$n" -ge 1 ]] || {
      echo "$name.block has no # src: line" >&2
      return 1
    }
  done
}
