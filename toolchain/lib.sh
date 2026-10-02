#!/usr/bin/env bash
set -euo pipefail
# Shared by toolchain/apply.sh, revert.sh and probe.sh. Source it; do not execute it.
# The wiring is one marked block (lib/block.sh, #116) in each of three files of the calling
# user; the block bodies are the <name>.block files beside this one. Contract #119.

# absolute: lib/block.sh takes a relative operand named - as stdin
TOOLCHAIN_DIR="$(unset CDPATH && cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$TOOLCHAIN_DIR/../lib/common.sh"
# shellcheck source=../lib/block.sh
source "$TOOLCHAIN_DIR/../lib/block.sh"

# shellcheck disable=SC2034 # read by the sourcing scripts
TOOLCHAIN_NAMES=(cargo fish makepkg)

# toolchain_home: die unless HOME is set, absolute, one line and a directory. ${HOME:-} and never
# ~: without HOME in the environment bash takes ~ from passwd, which may be another home.
toolchain_home() {
  [[ -n "${HOME:-}" ]] || die toolchain "HOME is not set"
  [[ "$HOME" == /* ]] || die toolchain "HOME is not an absolute path"
  [[ "$HOME" != *$'\n'* ]] || die toolchain "HOME holds a newline"
  [[ -d "$HOME" ]] || die toolchain "HOME is not a directory: $HOME"
}

# toolchain_target <cargo|fish|makepkg>: print the file that block goes into. The default
# places only: Cargo's, fish's and makepkg's own, with CARGO_HOME and XDG_CONFIG_HOME unset.
toolchain_target() {
  case "$1" in
    cargo) printf '%s\n' "$HOME/.cargo/config.toml" ;;
    fish) printf '%s\n' "$HOME/.config/fish/config.fish" ;;
    makepkg) printf '%s\n' "$HOME/.config/pacman/makepkg.conf" ;;
    *) die toolchain "no target named $1" ;;
  esac
}

# toolchain_state <file>: set REPLY to absent | present and return 0, or set REPLY to why <file>
# can neither take nor lose a block and return 1: a symlink, not a regular file, unreadable, or
# a malformed block. Asked here, before any block_apply or block_remove, so the reason is a
# toolchain line and not the library's.
toolchain_state() {
  if [[ -L "$1" ]]; then
    REPLY="$1 is a symlink"
    return 1
  fi
  if [[ ! -e "$1" ]]; then
    REPLY=absent
    return 0
  fi
  if [[ ! -f "$1" ]]; then
    REPLY="$1 is not a regular file"
    return 1
  fi
  # the substitution is a subshell: block_state's die ends only that
  if ! REPLY="$(block_state "$1" 2>/dev/null)"; then
    REPLY="cannot read $1"
    return 1
  fi
  case "$REPLY" in
    absent | present) ;;
    *)
      REPLY="malformed block in $1"
      return 1
      ;;
  esac
}
