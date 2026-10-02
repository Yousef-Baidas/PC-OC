#!/usr/bin/env bash
set -euo pipefail
# revert.sh (no arguments): take the block of toolchain/apply.sh out of each of the three files.
# Prints `toolchain: unwired <path>` or `toolchain: nothing to remove <path>`. A target that
# cannot be unwired gets a `pc-oc: toolchain: ` line on stderr and keeps its bytes; the other
# targets are still done, and the exit status is 1. A file that held only the block is
# removed; directories never are. Contract #119.
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

[[ $# -eq 0 ]] || die toolchain "usage: revert.sh (no arguments)"
# before any block_* call: as uid 0 lib/block.sh would leave root-owned files in the home (#116)
! is_root || die toolchain "refusing to run as root (uid 0): the blocks are in the calling user's own files"
toolchain_home

failed=0
for name in "${TOOLCHAIN_NAMES[@]}"; do
  file="$(toolchain_target "$name")"
  if ! toolchain_state "$file"; then
    printf 'pc-oc: toolchain: cannot unwire: %s\n' "$REPLY" >&2
    failed=1
  elif [[ "$REPLY" == absent ]]; then
    printf 'toolchain: nothing to remove %s\n' "$file"
  # block_remove dies on a failed write; the subshell makes that one failed target
  elif (block_remove "$file") && toolchain_state "$file" && [[ "$REPLY" == absent ]]; then
    printf 'toolchain: unwired %s\n' "$file"
  else
    printf 'pc-oc: toolchain: cannot unwire %s\n' "$file" >&2
    failed=1
  fi
done
[[ "$failed" -eq 0 ]] || exit 1
