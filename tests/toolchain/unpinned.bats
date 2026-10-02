#!/usr/bin/env bats
# Own cases of the #119 worker: what toolchain/apply.sh, revert.sh and probe.sh do where the
# contract (apply.bats, outcome.bats, probe.bats, revert.bats) left them unpinned. Every case
# starts the script in a fake home under the bats temp dir, behind fixtures/guard.sh. This file
# sorts last, so the positions of the 70 contract cases stay as the contract report names them.
bats_require_minimum_version 1.5.0
load fixtures/helper

setup() {
  common_setup
}

# one case takes the write permission off a directory; give it back whatever happened, so
# bats can remove its temp dir
teardown() {
  [[ ! -d "$H/.config/fish" ]] || chmod 755 "$H/.config/fish"
}

# wired_all: stdout is the one line per target of a finished apply
wired_all() {
  stdout_is "toolchain: wired $CARGO" "toolchain: wired $FISH" "toolchain: wired $MAKEPKG"
}

@test "apply refuses a fish file that defines function cmake indented or after a semicolon" {
  mkdir -p "$H/.config/fish"
  printf '%s\n' 'if status is-interactive' '    function cmake' \
    '        command cmake -G Ninja' '    end' 'end' >"$FISH"
  apply
  refused "$FISH"
  printf '%s\n' 'status is-interactive; and begin; function cmake; command cmake -G Ninja; end; end' \
    >"$FISH"
  apply
  refused "$FISH"
}

@test "apply refuses a fish file with alias cmake outside the block, and accepts alias cmake-clean" {
  mkdir -p "$H/.config/fish"
  printf '%s\n' "alias cmake 'command cmake -G Ninja'" >"$FISH"
  apply
  refused "$FISH"
  printf '%s\n' 'alias cmake="command cmake -G Ninja"' >"$FISH"
  apply
  refused "$FISH"
  printf '%s\n' "alias cmake-clean 'command cmake --build build --target clean'" \
    '# alias cmake is not set in this file' >"$FISH"
  apply
  status_is 0
  wired_all
}

@test "apply refuses a Cargo file with a spaced, quoted or array [build] header, or a top-level build key" {
  local text
  mkdir -p "$H/.cargo"
  for text in '[ build ]' '["build"]' "['build']" '[[build]]' '"build".jobs = 8' \
    'build = { jobs = 8 }'; do
    printf '%s\n' "$text" >"$CARGO"
    apply
    refused "$CARGO"
  done
}

@test "apply accepts a Cargo file with a build key inside another table" {
  mkdir -p "$H/.cargo"
  printf '%s\n' '[alias]' 'build = "build --release"' >"$CARGO"
  apply
  status_is 0
  wired_all
}

@test "apply takes an empty CARGO_HOME and XDG_CONFIG_HOME as unset, and refuses a trailing slash" {
  apply CARGO_HOME= XDG_CONFIG_HOME=
  status_is 0
  wired_all
  apply "CARGO_HOME=$H/.cargo/"
  refused CARGO_HOME
  apply "XDG_CONFIG_HOME=$H/.config/"
  refused XDG_CONFIG_HOME
}

@test "apply refuses a HOME that holds a newline, in one line" {
  mkdir "$BOX/two"$'\n'"lines"
  apply "HOME=$BOX/two"$'\n'"lines"
  refused HOME
}

@test "apply refuses a dangling symlink at HOME/.makepkg.conf and at functions/cmake.fish" {
  ln -s "$H/nowhere" "$H/.makepkg.conf"
  apply
  refused "$H/.makepkg.conf"
  rm "$H/.makepkg.conf"
  mkdir -p "$H/.config/fish/functions"
  ln -s "$H/nowhere" "$H/.config/fish/functions/cmake.fish"
  apply
  refused "$H/.config/fish/functions/cmake.fish"
}

@test "apply writes no target when a directory above one of them cannot be written" {
  mkdir -p "$H/.config/fish"
  chmod 555 "$H/.config/fish"
  apply
  refused "$FISH"
  [[ ! -e "$CARGO" && ! -e "$MAKEPKG" ]]
  chmod 755 "$H/.config/fish"
  : >"$H/.cargo"
  apply
  refused "$CARGO"
  [[ ! -e "$FISH" && ! -e "$MAKEPKG" ]]
}

@test "apply and revert refuse an argument" {
  local verb
  wire "${NAMES[@]}"
  # shellcheck disable=SC2034 # read by refused, through unchanged, in fixtures/helper.bash
  HOME_BEFORE="$(listing home)"
  for verb in apply revert; do
    run --separate-stderr in_ns user /usr/bin/env -i PATH=/usr/bin "HOME=$H" \
      /usr/bin/bash "$ROOT/toolchain/$verb.sh" all
    refused usage
  done
}

@test "revert goes on after a target that is a directory, exits 1 and names it in one line" {
  wire cargo makepkg
  as_directory fish
  revert
  status_is 1
  named "$FISH"
  [[ "${#stderr_lines[@]}" -eq 1 ]]
  [[ -d "$FISH" && ! -e "$CARGO" && ! -e "$MAKEPKG" ]]
  stdout_is "toolchain: unwired $CARGO" "toolchain: unwired $MAKEPKG"
}

@test "revert prints one stderr line for each target it cannot unwire" {
  wire makepkg
  as_malformed cargo
  as_symlink fish
  revert
  status_is 1
  named "$CARGO"
  named "$FISH"
  [[ "${#stderr_lines[@]}" -eq 2 ]]
  stdout_is "toolchain: unwired $MAKEPKG"
}

@test "probe names in its header each file it read and the sum of their bytes" {
  local bytes
  probe
  status_is 0
  [[ "${lines[0]}" == "source= bytes=0 items=7" ]]
  wire cargo
  stock fish
  bytes=$(($(stat -c %s "$CARGO") + $(stat -c %s "$ROOT/toolchain/cargo.block") + $(stat -c %s "$FISH")))
  probe
  status_is 0
  [[ "${lines[0]}" == "source=$CARGO,$ROOT/toolchain/cargo.block,$FISH bytes=$bytes items=7" ]]
}

@test "probe refuses a HOME that is not in the environment or not a directory" {
  NO_HOME=1 probe
  refused HOME
  probe "HOME=$BOX/nowhere"
  refused HOME
}

@test "probe exits 1 and names a target it cannot read as a file" {
  wire cargo makepkg
  as_directory fish
  probe
  refused "$FISH"
  rmdir "$FISH"
  ln -s "$H/nowhere" "$FISH"
  probe
  refused "$FISH"
}

@test "probe reads a target through a symlink" {
  as_symlink cargo
  framed cargo >>"$H/dotfiles/cargo"
  probe
  status_is 0
  probe_says cargo wired
}

@test "probe joins the names in env with commas, in the order of bench/compile.sh" {
  probe RUSTC_WRAPPER=sccache CC=gcc PATH=/usr/bin:/usr/lib/sccache/bin
  status_is 0
  probe_says env wired:CC,RUSTC_WRAPPER,/usr/lib/sccache/bin
}
