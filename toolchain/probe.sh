#!/usr/bin/env bash
set -euo pipefail
# Print the toolchain wiring: the probe_emit header, then toolchain.<key>=<value>. Read-only.
#   cargo, fish, makepkg: wired (block present and equal to the data file) | absent | differs
#     | malformed
#   sccache_bin, mold_bin, cmake_bin: /usr/bin/<name>, or missing
#   env: clean, or wired:<names>, the list bench/compile.sh refuses to time under (#118)
# The header names the target files and data files that were read. Contract #119.
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROBE_COMPONENT=toolchain

# wiring <cargo|fish|makepkg>: set REPLY to the state of that target's block
wiring() {
  local file src state
  file="$(toolchain_target "$1")"
  src="$TOOLCHAIN_DIR/$1.block"
  if [[ ! -e "$file" && ! -L "$file" ]]; then
    REPLY=absent
    return 0
  fi
  [[ -f "$file" && -r "$file" ]] || die toolchain "cannot read $file"
  probe_source "$file" "$(wc -c <"$file")"
  # the substitution is a subshell: block_state's die ends only that
  state="$(block_state "$file" 2>/dev/null)" || die toolchain "cannot read $file"
  if [[ "$state" != present ]]; then
    REPLY="$state"
    return 0
  fi
  [[ -f "$src" && -r "$src" ]] || die toolchain "cannot read $src"
  probe_source "$src" "$(wc -c <"$src")"
  REPLY=differs
  ! block_matches "$file" "$src" || REPLY=wired
}

# tool_bin <name>: set REPLY to /usr/bin/<name>, the path the blocks and apply.sh rely on, or missing
tool_bin() {
  REPLY=missing
  [[ ! -f "/usr/bin/$1" || ! -x "/usr/bin/$1" ]] || REPLY="/usr/bin/$1"
}

toolchain_home

wiring cargo
cargo=$REPLY
wiring fish
fish=$REPLY
wiring makepkg
makepkg=$REPLY

tool_bin sccache
sccache_bin=$REPLY
tool_bin mold
mold_bin=$REPLY
tool_bin cmake
cmake_bin=$REPLY

# the same list as bench/compile.sh
wired=()
for v in CC CXX LDFLAGS RUSTC_WRAPPER CMAKE_C_COMPILER_LAUNCHER CMAKE_CXX_COMPILER_LAUNCHER; do
  [[ -z "${!v:-}" ]] || wired+=("$v")
done
IFS=: read -ra path_dirs <<<"${PATH:-}:"
for d in "${path_dirs[@]}"; do
  case "${d%/}" in
    /usr/lib/sccache/bin | /usr/lib/ccache/bin) wired+=("${d%/}") ;;
  esac
done
env=clean
if [[ "${#wired[@]}" -gt 0 ]]; then
  env="wired:$(
    IFS=,
    printf '%s' "${wired[*]}"
  )"
fi

probe_emit \
  cargo="$cargo" \
  fish="$fish" \
  makepkg="$makepkg" \
  sccache_bin="$sccache_bin" \
  mold_bin="$mold_bin" \
  cmake_bin="$cmake_bin" \
  env="$env"
