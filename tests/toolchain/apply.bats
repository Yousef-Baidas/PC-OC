#!/usr/bin/env bats
# Contract #119: toolchain/apply.sh, cases 1, 2, 3, 5 and 6 of the ticket. Every case starts
# the script in a fake home under the bats temp dir, behind fixtures/guard.sh.
bats_require_minimum_version 1.5.0
load fixtures/helper

setup() {
  common_setup
}

# the last case takes the write permission off a directory; give it back whatever happened,
# so bats can remove its temp dir
teardown() {
  [[ ! -d "$H/.config/fish" ]] || chmod 755 "$H/.config/fish"
}

# wired_all: stdout is the one line per target of a finished apply
wired_all() {
  stdout_is "toolchain: wired $CARGO" "toolchain: wired $FISH" "toolchain: wired $MAKEPKG"
}

@test "case 1: apply on an empty home writes the three files, each exactly BEGIN, the data file, END, and probe says wired three times" {
  skip "contract #119 pending"
  local name
  apply
  status_is 0
  wired_all
  for name in "${NAMES[@]}"; do
    cmp "$(target "$name")" <(framed "$name")
  done
  home_holds .cargo .cargo/config.toml .config .config/fish .config/fish/config.fish \
    .config/pacman .config/pacman/makepkg.conf
  probe
  status_is 0
  probe_says cargo wired
  probe_says fish wired
  probe_says makepkg wired
}

@test "case 2: apply keeps the 79 lines of a fish file as a prefix, and revert gives the bytes back" {
  skip "contract #119 pending"
  [[ "$(wc -l <"$FIX/config.fish")" -eq 79 ]]
  stock fish
  apply
  status_is 0
  wired_all
  cmp <(head -c "$(stat -c %s "$FIX/config.fish")" "$FISH") "$FIX/config.fish"
  cmp <(tail -n +80 "$FISH") <(framed fish)
  revert
  status_is 0
  stdout_is "toolchain: unwired $CARGO" "toolchain: unwired $FISH" "toolchain: unwired $MAKEPKG"
  cmp "$FISH" "$FIX/config.fish"
}

@test "case 3: apply twice leaves the three files as apply once left them" {
  skip "contract #119 pending"
  local name
  apply
  status_is 0
  for name in "${NAMES[@]}"; do
    cp "$(target "$name")" "$BATS_TEST_TMPDIR/$name.once"
  done
  apply
  status_is 0
  wired_all
  for name in "${NAMES[@]}"; do
    cmp "$(target "$name")" "$BATS_TEST_TMPDIR/$name.once"
  done
  unchanged
}

@test "case 3: apply on files that hold other content twice equals once, and the other content stays a prefix" {
  skip "contract #119 pending"
  local name file
  stock "${NAMES[@]}"
  for name in "${NAMES[@]}"; do
    cp "$(target "$name")" "$BATS_TEST_TMPDIR/$name.stock"
  done
  apply
  status_is 0
  wired_all
  for name in "${NAMES[@]}"; do
    file="$BATS_TEST_TMPDIR/$name.stock"
    cmp <(head -c "$(stat -c %s "$file")" "$(target "$name")") "$file"
  done
  apply
  status_is 0
  wired_all
  unchanged
}

@test "apply accepts CARGO_HOME and XDG_CONFIG_HOME that name the default places" {
  skip "contract #119 pending"
  apply "CARGO_HOME=$H/.cargo" "XDG_CONFIG_HOME=$H/.config"
  status_is 0
  wired_all
}

@test "apply accepts a Cargo file whose block is followed by a comment and a table header" {
  skip "contract #119 pending"
  wire cargo
  printf '%s\n' '' '# the network' '[net]' 'git-fetch-with-cli = true' >>"$CARGO"
  cp "$CARGO" "$BATS_TEST_TMPDIR/cargo.before"
  apply
  status_is 0
  wired_all
  cmp "$CARGO" "$BATS_TEST_TMPDIR/cargo.before"
}

@test "apply accepts a Cargo file whose other tables only hold the word build" {
  skip "contract #119 pending"
  mkdir -p "$H/.cargo"
  printf '%s\n' '[profile.release.build-override]' 'opt-level = 3' '' \
    '[net]' 'git-fetch-with-cli = true' >"$CARGO"
  apply
  status_is 0
  wired_all
}

@test "apply accepts a fish file that defines cmake-clean and names cmake in a comment" {
  skip "contract #119 pending"
  mkdir -p "$H/.config/fish"
  printf '%s\n' '# cmake: see the function below' 'function cmake-clean' \
    '    command cmake --build build --target clean' 'end' >"$FISH"
  apply
  status_is 0
  wired_all
}

@test "case 5: apply refuses when HOME is not in the environment" {
  skip "contract #119 pending"
  NO_HOME=1 apply
  refused HOME
}

@test "case 5: apply refuses a HOME that is not absolute" {
  skip "contract #119 pending"
  apply HOME=home
  refused HOME
}

@test "case 5: apply refuses an empty HOME" {
  skip "contract #119 pending"
  apply HOME=
  refused HOME
}

@test "case 5: apply refuses a HOME that does not exist" {
  skip "contract #119 pending"
  apply "HOME=$BOX/nowhere"
  refused HOME
}

@test "case 5: apply refuses a HOME that is a regular file" {
  skip "contract #119 pending"
  : >"$BOX/a-file"
  apply "HOME=$BOX/a-file"
  refused HOME
}

@test "case 5: apply refuses a CARGO_HOME that is not HOME/.cargo" {
  skip "contract #119 pending"
  mkdir "$H/cargo-elsewhere"
  apply "CARGO_HOME=$H/cargo-elsewhere"
  refused CARGO_HOME
}

@test "case 5: apply refuses an XDG_CONFIG_HOME that is not HOME/.config" {
  skip "contract #119 pending"
  mkdir "$H/config-elsewhere"
  apply "XDG_CONFIG_HOME=$H/config-elsewhere"
  refused XDG_CONFIG_HOME
}

@test "case 5: apply refuses when /usr/bin/sccache is missing" {
  skip "contract #119 pending"
  tool_absent sccache
  apply
  refused /usr/bin/sccache
}

@test "case 5: apply refuses when /usr/bin/mold is missing" {
  skip "contract #119 pending"
  tool_absent mold
  apply
  refused /usr/bin/mold
}

@test "case 5: apply refuses when /usr/lib/sccache/bin/cc is missing" {
  skip "contract #119 pending"
  tool_absent cc
  apply
  refused /usr/lib/sccache/bin/cc
}

@test "case 5: apply refuses a Cargo file that is a symlink" {
  skip "contract #119 pending"
  as_symlink cargo
  apply
  refused "$CARGO"
}

@test "case 5: apply refuses a fish file that is a symlink" {
  skip "contract #119 pending"
  as_symlink fish
  apply
  refused "$FISH"
}

@test "case 5: apply refuses a makepkg file that is a symlink, and the first two targets stay absent" {
  skip "contract #119 pending"
  as_symlink makepkg
  apply
  refused "$MAKEPKG"
  [[ ! -e "$CARGO" && ! -e "$FISH" ]]
}

@test "case 5: apply refuses a Cargo file that is a directory" {
  skip "contract #119 pending"
  as_directory cargo
  apply
  refused "$CARGO"
}

@test "case 5: apply refuses a fish file that is a directory" {
  skip "contract #119 pending"
  as_directory fish
  apply
  refused "$FISH"
}

@test "case 5: apply refuses a makepkg file that is a directory, and the first two targets stay absent" {
  skip "contract #119 pending"
  as_directory makepkg
  apply
  refused "$MAKEPKG"
  [[ ! -e "$CARGO" && ! -e "$FISH" ]]
}

@test "case 5: apply refuses a Cargo file with a malformed block, and the other two files stay as they were" {
  skip "contract #119 pending"
  as_malformed cargo
  stock fish makepkg
  apply
  refused "$CARGO"
}

@test "case 5: apply refuses a fish file with a malformed block, and the other two files stay as they were" {
  skip "contract #119 pending"
  as_malformed fish
  stock cargo makepkg
  apply
  refused "$FISH"
}

@test "case 5: apply refuses a makepkg file with a malformed block, and the first two files stay as they were" {
  skip "contract #119 pending"
  as_malformed makepkg
  stock cargo fish
  apply
  refused "$MAKEPKG"
}

@test "case 5: apply refuses a Cargo file with a [build] table outside the block" {
  skip "contract #119 pending"
  mkdir -p "$H/.cargo"
  printf '%s\n' '[build]' 'jobs = 8' >"$CARGO"
  apply
  refused "$CARGO"
}

@test "case 5: apply refuses a Cargo file with a build. dotted key outside the block" {
  skip "contract #119 pending"
  mkdir -p "$H/.cargo"
  printf '%s\n' 'build.jobs = 8' '' '[net]' 'git-fetch-with-cli = true' >"$CARGO"
  apply
  refused "$CARGO"
}

@test "case 5: apply refuses a Cargo file whose block is followed by a key line before the next table header" {
  skip "contract #119 pending"
  wire cargo
  printf '%s\n' '' 'jobs = 8' '' '[net]' 'git-fetch-with-cli = true' >>"$CARGO"
  apply
  refused "$CARGO"
}

@test "case 5: apply refuses a fish file that defines function cmake outside the block" {
  skip "contract #119 pending"
  mkdir -p "$H/.config/fish"
  printf '%s\n' 'function cmake' '    command cmake -G Ninja' 'end' >"$FISH"
  apply
  refused "$FISH"
  [[ ! -e "$CARGO" && ! -e "$MAKEPKG" ]]
}

@test "case 5: apply refuses when the fish functions directory holds cmake.fish" {
  skip "contract #119 pending"
  mkdir -p "$H/.config/fish/functions"
  printf '%s\n' 'function cmake' '    command cmake -G Ninja' 'end' \
    >"$H/.config/fish/functions/cmake.fish"
  apply
  refused "$H/.config/fish/functions/cmake.fish"
}

@test "case 5: apply refuses a makepkg file with -fuse-ld= outside the block" {
  skip "contract #119 pending"
  mkdir -p "$H/.config/pacman"
  printf '%s\n' 'LDFLAGS+=" -fuse-ld=lld"' >"$MAKEPKG"
  apply
  refused "$MAKEPKG"
  [[ ! -e "$CARGO" && ! -e "$FISH" ]]
}

@test "case 5: apply refuses a makepkg file with sccache outside the block" {
  skip "contract #119 pending"
  mkdir -p "$H/.config/pacman"
  printf '%s\n' 'export RUSTC_WRAPPER=sccache' >"$MAKEPKG"
  apply
  refused "$MAKEPKG"
}

@test "case 5: apply refuses when HOME/.makepkg.conf exists" {
  skip "contract #119 pending"
  printf '%s\n' 'MAKEFLAGS="-j20"' >"$H/.makepkg.conf"
  apply
  refused "$H/.makepkg.conf"
}

@test "case 6: as uid 0 apply exits 1 and writes nothing" {
  skip "contract #119 pending"
  toolchain root apply
  refused
  stock "${NAMES[@]}"
  toolchain root apply
  refused
}

@test "apply exits 1 and prints no wired line for a target it cannot write" {
  skip "contract #119 pending"
  mkdir -p "$H/.config/fish"
  chmod 555 "$H/.config/fish"
  apply
  chmod 755 "$H/.config/fish"
  status_is 1
  [[ ! -e "$FISH" ]]
  [[ "$output" != *"toolchain: wired $FISH"* ]]
  [[ "$stderr" == *"pc-oc: "*"$H/.config/fish"* ]]
}
