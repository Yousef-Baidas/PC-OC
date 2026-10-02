#!/usr/bin/env bats
# Contract #119: toolchain/revert.sh, cases 4 and 6 of the ticket, its HOME refusals, and
# "keeps going when one fails". Every case starts the script in a fake home under the bats
# temp dir, behind fixtures/guard.sh.
bats_require_minimum_version 1.5.0
load fixtures/helper

setup() {
  common_setup
}

# goes_on_past <name>: that target cannot be unwired; revert exits 1 and names it, leaves
# its bytes alone, and still unwires the other two
goes_on_past() {
  local name
  revert
  status_is 1
  named "$(target "$1")"
  [[ "$output" != *"$(target "$1")"* ]]
  cmp "$(target "$1")" "$BATS_TEST_TMPDIR/$1.before"
  for name in "${NAMES[@]}"; do
    [[ "$name" != "$1" ]] || continue
    [[ ! -e "$(target "$name")" ]]
    grep -qxF -- "toolchain: unwired $(target "$name")" <<<"$output"
  done
}

# malformed_after_apply <name>: a wired home whose <name> target lost its END line
malformed_after_apply() {
  wire "${NAMES[@]}"
  sed -i "/^$END\$/d" "$(target "$1")"
  cp "$(target "$1")" "$BATS_TEST_TMPDIR/$1.before"
}

@test "case 4: revert after apply removes the three files and leaves their directories" {
  skip "contract #119 pending"
  apply
  status_is 0
  revert
  status_is 0
  stdout_is "toolchain: unwired $CARGO" "toolchain: unwired $FISH" "toolchain: unwired $MAKEPKG"
  home_holds .cargo .config .config/fish .config/pacman
}

@test "case 4: revert on an empty home exits 0 and creates nothing" {
  skip "contract #119 pending"
  revert
  status_is 0
  stdout_is "toolchain: nothing to remove $CARGO" "toolchain: nothing to remove $FISH" \
    "toolchain: nothing to remove $MAKEPKG"
  home_holds
}

@test "revert leaves a file without a block alone and says nothing to remove" {
  skip "contract #119 pending"
  stock cargo makepkg
  cp "$CARGO" "$BATS_TEST_TMPDIR/cargo.before"
  cp "$MAKEPKG" "$BATS_TEST_TMPDIR/makepkg.before"
  wire fish makepkg
  revert
  status_is 0
  stdout_is "toolchain: nothing to remove $CARGO" "toolchain: unwired $FISH" \
    "toolchain: unwired $MAKEPKG"
  cmp "$CARGO" "$BATS_TEST_TMPDIR/cargo.before"
  cmp "$MAKEPKG" "$BATS_TEST_TMPDIR/makepkg.before"
  [[ ! -e "$FISH" ]]
}

@test "revert goes on after the Cargo file fails, exits 1 and names it" {
  skip "contract #119 pending"
  malformed_after_apply cargo
  goes_on_past cargo
}

@test "revert goes on after the fish file fails, exits 1 and names it" {
  skip "contract #119 pending"
  malformed_after_apply fish
  goes_on_past fish
}

@test "revert goes on after the makepkg file fails, exits 1 and names it" {
  skip "contract #119 pending"
  malformed_after_apply makepkg
  goes_on_past makepkg
}

@test "revert goes on after a target that is a symlink, exits 1 and names it" {
  skip "contract #119 pending"
  wire cargo makepkg
  as_symlink fish
  revert
  status_is 1
  named "$FISH"
  [[ -L "$FISH" && ! -e "$CARGO" && ! -e "$MAKEPKG" ]]
  cmp "$H/dotfiles/fish" <(printf '%s\n' '# kept in the dotfiles directory')
}

@test "revert refuses when HOME is not in the environment" {
  skip "contract #119 pending"
  wire "${NAMES[@]}"
  NO_HOME=1 revert
  refused HOME
}

@test "revert refuses a HOME that is not absolute" {
  skip "contract #119 pending"
  wire "${NAMES[@]}"
  revert HOME=home
  refused HOME
}

@test "revert refuses a HOME that is not a directory" {
  skip "contract #119 pending"
  wire "${NAMES[@]}"
  revert "HOME=$BOX/nowhere"
  refused HOME
  : >"$BOX/a-file"
  revert "HOME=$BOX/a-file"
  refused HOME
}

@test "case 6: as uid 0 revert exits 1 and removes nothing" {
  skip "contract #119 pending"
  toolchain root revert
  refused
  wire "${NAMES[@]}"
  toolchain root revert
  refused
}
