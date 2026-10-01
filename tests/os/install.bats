#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

# Contract #26. install.sh runs from a scratch git repo built from the real pc-oc,
# lib/ and os/install.sh plus fake components, so VERSION and the tree are known.
# Ownership (root) is not checked: the tests never run as root.

setup_file() {
  local f="$BATS_TEST_DIRNAME/../../os/install.sh"
  f="$(cd "$(dirname "$f")" && pwd)/install.sh"
  printf '# opened %s sha256=%s, 1 file\n' "$f" "$(sha256sum <"$f" | cut -d' ' -f1)" >&3
}

setup() {
  local src
  src="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  repo="$BATS_TEST_TMPDIR/repo"
  dest="$BATS_TEST_TMPDIR/dest"
  mkdir -p "$repo/os" "$repo/etc/sudoers.d" "$repo/cpu" "$repo/toolchain" "$repo/bench" "$dest"
  cp "$src/pc-oc" "$repo/"
  cp -r "$src/lib" "$repo/"
  cp "$src/os/install.sh" "$repo/os/"
  cp "$BATS_TEST_DIRNAME/fixtures/sudoers/good" "$repo/etc/sudoers.d/pc-oc"
  for f in cpu/apply.sh cpu/revert.sh cpu/probe.sh toolchain/probe.sh cpu/notes.sh bench/probe.sh; do
    printf '#!/usr/bin/env bash\necho %s\n' "$f" >"$repo/$f"
  done
  # a verb script committed without the exec bit still installs 0755
  chmod 755 "$repo"/cpu/*.sh "$repo/bench/probe.sh"
  chmod 644 "$repo/cpu/probe.sh"
  # a git hook (lefthook gates) exports GIT_DIR, GIT_INDEX_FILE and friends; left set,
  # the git calls below would act on the real repo instead of the scratch one
  unset "${!GIT_@}"
  git -C "$repo" init -q
  git -C "$repo" add -A
  git -C "$repo" -c user.name=t -c user.email=t@t -c commit.gpgsign=false -c core.hooksPath=/dev/null \
    commit -q -m fixture
}

@test "a DESTDIR install produces the tree, modes, VERSION and the sudoers drop-in" {
  skip "contract #26 pending"
  run --separate-stderr env DESTDIR="$dest" "$repo/os/install.sh"
  [ "$status" -eq 0 ]
  lib_entries="$(cd "$repo" && find lib -type f -printf '644 ./%p\n')"
  expected="$(printf '%s\n' '755 .' '644 ./VERSION' '755 ./cpu' '755 ./cpu/apply.sh' \
    '755 ./cpu/probe.sh' '755 ./cpu/revert.sh' '755 ./lib' "$lib_entries" '755 ./pc-oc' \
    '755 ./toolchain' '755 ./toolchain/probe.sh' | sort)"
  [ "$(cd "$dest/usr/local/lib/pc-oc" && find . -printf '%m %p\n' | sort)" = "$expected" ]
  [ "$(<"$dest/usr/local/lib/pc-oc/VERSION")" = "$(git -C "$repo" rev-parse HEAD)" ]
  [ "$(stat -c %a "$dest/etc/sudoers.d/pc-oc")" = 440 ]
  cmp "$repo/etc/sudoers.d/pc-oc" "$dest/etc/sudoers.d/pc-oc"
  echo '# local edit' >>"$repo/cpu/apply.sh"
  run --separate-stderr env DESTDIR="$BATS_TEST_TMPDIR/dest2" "$repo/os/install.sh"
  [ "$status" -eq 0 ]
  [ "$(<"$BATS_TEST_TMPDIR/dest2/usr/local/lib/pc-oc/VERSION")" = "$(git -C "$repo" rev-parse HEAD)-dirty" ]
}

@test "install as a non-root user without DESTDIR exits 1 naming root" {
  skip "contract #26 pending"
  [[ "$EUID" -ne 0 ]] || skip "needs a non-root user"
  run --separate-stderr env -u DESTDIR "$repo/os/install.sh"
  [ "$status" -eq 1 ]
  [[ "${stderr_lines[0]}" == "pc-oc: os: "*root* ]]
}

@test "a sudoers file that fails visudo stops install before anything is copied" {
  skip "contract #26 pending"
  echo 'not sudoers' >>"$repo/etc/sudoers.d/pc-oc"
  run --separate-stderr env DESTDIR="$dest" "$repo/os/install.sh"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"pc-oc: os: "*sudoers* ]]
  [ -z "$(find "$dest" -mindepth 1)" ]
}
