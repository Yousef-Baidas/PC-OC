#!/usr/bin/env bash
set -euo pipefail
# apply.sh (no arguments): wire sccache and mold into Cargo, into cmake under fish, and into
# makepkg: one marked block in each of three files of the calling user (toolchain/lib.sh).
# Checks everything first and writes nothing unless every check passes; a refusal is the one
# line `pc-oc: toolchain: <reason>` on stderr and exit 1. Then one block_apply per target, a
# read-back, and `toolchain: wired <path>` on stdout. No state directory and no global
# environment export: stock is "no block", revert.sh takes the blocks out. Contract #119.
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# conflict <cargo|fish|makepkg> <file>: print why the lines of <file> outside its block clash
# with that block, or nothing. <file> has no block or one well-formed block.
#   cargo: a [build] table (the block opens one, TOML takes a table once); a build. dotted key,
#     or a top-level build = value, which define that table too; a key between the block and
#     the next table header, which would fall into the block's [build].
#   fish: function cmake or alias cmake (an alias is a function): one of the two would shadow
#     the other, by file order.
#   makepkg: -fuse-ld= or sccache anywhere: a second linker choice or a second wrapper.
conflict() {
  # <file> comes in on stdin: awk would read an operand holding = as an assignment
  BLOCK_BEGIN="$BLOCK_BEGIN" BLOCK_END="$BLOCK_END" LC_ALL=C awk -v kind="$1" '
    function clash(why) {
      print why
      exit
    }
    BEGIN {
      build = "(build|\"build\"|\047build\047)"
      top = 1
    }
    {
      l = $0
      sub(/[[:space:]]+$/, "", l)
    }
    l == ENVIRON["BLOCK_BEGIN"] { skip = 1; next }
    l == ENVIRON["BLOCK_END"] { skip = 0; after = 1; top = 0; next }
    skip { next }
    kind == "makepkg" && l ~ /-fuse-ld=/ { clash("sets -fuse-ld= outside the block") }
    kind == "makepkg" && l ~ /sccache/ { clash("names sccache outside the block") }
    l ~ /^[[:space:]]*(#|$)/ { next }
    kind == "fish" && l ~ /(^|;)[[:space:]]*function[[:space:]]+cmake([[:space:];]|$)/ {
      clash("defines function cmake outside the block")
    }
    kind == "fish" && l ~ /(^|;)[[:space:]]*alias[[:space:]]+cmake([[:space:]=]|$)/ {
      clash("defines alias cmake outside the block")
    }
    kind == "cargo" && l ~ /^[[:space:]]*\[/ {
      after = 0
      top = 0
      if (l ~ "^[[:space:]]*\\[\\[?[[:space:]]*" build "[[:space:]]*\\]") {
        clash("has a [build] table outside the block")
      }
      next
    }
    kind == "cargo" && after { clash("has a key after the block that would fall into its [build] table") }
    kind == "cargo" && l ~ "^[[:space:]]*" build "[[:space:]]*\\." {
      clash("has a build. dotted key outside the block")
    }
    kind == "cargo" && top && l ~ "^[[:space:]]*" build "[[:space:]]*=" {
      clash("has a top-level build key outside the block")
    }
  ' <"$2"
}

[[ $# -eq 0 ]] || die toolchain "usage: apply.sh (no arguments)"
# before any block_* call: as uid 0 lib/block.sh would leave root-owned files in the home (#116)
! is_root || die toolchain "refusing to run as root (uid 0): the blocks go into the calling user's own files"
toolchain_home

# an empty value counts as unset: Cargo, fish and makepkg all fall back to the default then
[[ -z "${CARGO_HOME:-}" || "$CARGO_HOME" == "$HOME/.cargo" ]] ||
  die toolchain "CARGO_HOME is not $HOME/.cargo: Cargo would read another config.toml"
[[ -z "${XDG_CONFIG_HOME:-}" || "$XDG_CONFIG_HOME" == "$HOME/.config" ]] ||
  die toolchain "XDG_CONFIG_HOME is not $HOME/.config: fish and makepkg would read other files"

# the paths the three blocks name: cargo.block /usr/bin/sccache, makepkg.block the wrapper
# directory /usr/lib/sccache/bin, and -fuse-ld=mold the linker
for tool in /usr/bin/sccache /usr/bin/mold /usr/lib/sccache/bin/cc; do
  [[ -f "$tool" && -x "$tool" ]] || die toolchain "$tool is missing"
done

for name in "${TOOLCHAIN_NAMES[@]}"; do
  src="$TOOLCHAIN_DIR/$name.block"
  [[ -f "$src" && -r "$src" ]] || die toolchain "cannot read $src"
  file="$(toolchain_target "$name")"
  toolchain_state "$file" || die toolchain "$REPLY"
  # the deepest directory that exists above the target: block_apply creates the rest in it
  dir="${file%/*}"
  while [[ ! -e "$dir" && ! -L "$dir" ]]; do
    dir="${dir%/*}"
  done
  [[ -d "$dir" && -w "$dir" && -x "$dir" ]] ||
    die toolchain "cannot write $file: $dir is not a directory this user can write in"
  [[ -e "$file" ]] || continue
  reason="$(conflict "$name" "$file")" || die toolchain "cannot read $file"
  [[ -z "$reason" ]] || die toolchain "$file $reason"
done

# fish loads functions/cmake.fish only while no function cmake exists: with the block it
# would never load. makepkg reads ~/.makepkg.conf only while the XDG file is missing.
for other in "$HOME/.config/fish/functions/cmake.fish" "$HOME/.makepkg.conf"; do
  [[ ! -e "$other" && ! -L "$other" ]] ||
    die toolchain "$other exists: with the block in place it would no longer be read"
done

for name in "${TOOLCHAIN_NAMES[@]}"; do
  src="$TOOLCHAIN_DIR/$name.block"
  file="$(toolchain_target "$name")"
  block_apply "$file" "$src"
  block_matches "$file" "$src" || die toolchain "readback of $file failed"
  printf 'toolchain: wired %s\n' "$file"
done
