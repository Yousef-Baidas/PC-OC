#!/usr/bin/env bats
# Contract #119: toolchain/probe.sh, case 10 of the ticket and the keys of its Interface.
# Every case starts the script in a fake home under the bats temp dir, behind
# fixtures/guard.sh; the probe never changes that home.
bats_require_minimum_version 1.5.0
load fixtures/helper

setup() {
  common_setup
}

# only_state <name> <state>: the probe says <state> for that target and wired for the other
# two, exits 0 and changed nothing
only_state() {
  local name
  probe
  status_is 0
  for name in "${NAMES[@]}"; do
    if [[ "$name" == "$1" ]]; then
      probe_says "$name" "$2"
    else
      probe_says "$name" wired
    fi
  done
  unchanged
}

@test "probe on an empty home: the header, then the seven keys, absent three times" {
  probe
  status_is 0
  [[ "${lines[0]}" =~ ^source=[^\ ]*\ bytes=[0-9]+\ items=7$ ]]
  [[ "${#lines[@]}" -eq 8 ]]
  probe_says cargo absent
  probe_says fish absent
  probe_says makepkg absent
  probe_says sccache_bin /usr/bin/sccache
  probe_says mold_bin /usr/bin/mold
  probe_says cmake_bin missing
  probe_says env clean
  unchanged
}

@test "probe says absent for files that hold no block" {
  stock "${NAMES[@]}"
  probe
  status_is 0
  probe_says cargo absent
  probe_says fish absent
  probe_says makepkg absent
  unchanged
}

@test "probe says wired for blocks equal to the data files, with other content around them" {
  stock "${NAMES[@]}"
  wire "${NAMES[@]}"
  printf '%s\n' '' '[http]' 'timeout = 30' >>"$CARGO"
  probe
  status_is 0
  [[ "${lines[0]}" =~ ^source=[^\ ]+\ bytes=[0-9]+\ items=7$ ]]
  probe_says cargo wired
  probe_says fish wired
  probe_says makepkg wired
  unchanged
}

@test "case 10: probe says differs after one byte of the Cargo block is edited" {
  wire "${NAMES[@]}"
  sed -i 's|/usr/bin/sccache|/usr/bin/sccachE|' "$CARGO"
  only_state cargo differs
}

@test "case 10: probe says differs after one byte of the fish block is edited" {
  wire "${NAMES[@]}"
  sed -i 's|-fuse-ld=mold|-fuse-ld=mole|' "$FISH"
  only_state fish differs
}

@test "case 10: probe says differs after one byte of the makepkg block is edited" {
  wire "${NAMES[@]}"
  sed -i 's|-fuse-ld=mold|-fuse-ld=mole|' "$MAKEPKG"
  only_state makepkg differs
}

@test "case 10: probe says malformed with the END line of the Cargo block deleted" {
  wire "${NAMES[@]}"
  sed -i "/^$END\$/d" "$CARGO"
  only_state cargo malformed
}

@test "case 10: probe says malformed with the END line of the fish block deleted" {
  wire "${NAMES[@]}"
  sed -i "/^$END\$/d" "$FISH"
  only_state fish malformed
}

@test "case 10: probe says malformed with the END line of the makepkg block deleted" {
  wire "${NAMES[@]}"
  sed -i "/^$END\$/d" "$MAKEPKG"
  only_state makepkg malformed
}

@test "probe says missing for a tool that is not there and the path for one that is" {
  tool_absent sccache
  tool_present cmake
  probe
  status_is 0
  probe_says sccache_bin missing
  probe_says mold_bin /usr/bin/mold
  probe_says cmake_bin /usr/bin/cmake
  tool_present sccache
  tool_absent mold cmake
  probe
  status_is 0
  probe_says sccache_bin /usr/bin/sccache
  probe_says mold_bin missing
  probe_says cmake_bin missing
}

@test "case 10: probe says env=wired:RUSTC_WRAPPER when that variable is set" {
  probe RUSTC_WRAPPER=/usr/bin/sccache
  status_is 0
  probe_says env wired:RUSTC_WRAPPER
  probe RUSTC_WRAPPER=
  status_is 0
  probe_says env clean
}

@test "probe names in env each variable of the list of bench/compile.sh" {
  local name
  for name in CC CXX LDFLAGS RUSTC_WRAPPER CMAKE_C_COMPILER_LAUNCHER \
    CMAKE_CXX_COMPILER_LAUNCHER; do
    probe "$name=x"
    status_is 0
    probe_says env "wired:$name"
  done
  probe CFLAGS=-O2 MAKEFLAGS=-j20
  status_is 0
  probe_says env clean
}

@test "probe names in env a wrapper directory on PATH" {
  probe PATH=/usr/lib/sccache/bin:/usr/bin
  status_is 0
  probe_says env wired:/usr/lib/sccache/bin
  probe PATH=/usr/bin:/usr/lib/ccache/bin/
  status_is 0
  probe_says env wired:/usr/lib/ccache/bin
}

@test "probe names in env every name that is set" {
  probe CC=gcc RUSTC_WRAPPER=sccache
  status_is 0
  [[ "$(grep -c '^toolchain\.env=' <<<"$output")" -eq 1 ]]
  grep -qE '^toolchain\.env=wired:(.*[^A-Z_])?CC([^A-Z_].*)?$' <<<"$output"
  grep -qE '^toolchain\.env=wired:(.*[^A-Z_])?RUSTC_WRAPPER([^A-Z_].*)?$' <<<"$output"
}
