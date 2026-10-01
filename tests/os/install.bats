#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031 # bats `run` sets status/stderr in the test shell; shellcheck reads each @test as a subshell

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
  SRC="$src"
  repo="$BATS_TEST_TMPDIR/repo"
  dest="$BATS_TEST_TMPDIR/dest"
  mkdir -p "$repo/os" "$repo/etc/sudoers.d" "$repo/cpu" "$repo/toolchain" "$repo/bench" "$repo/systemd" "$dest"
  # the boot unit (#124) is a fixture, committed 0755 so an installer that keeps the source mode shows
  cp "$BATS_TEST_DIRNAME/fixtures/systemd/pc-oc-gpu.service" "$repo/systemd/"
  chmod 755 "$repo/systemd/pc-oc-gpu.service"
  unit="$dest/etc/systemd/system/pc-oc-gpu.service"
  cp "$src/pc-oc" "$repo/"
  cp -r "$src/lib" "$repo/"
  cp "${INSTALL_SH:-$src/os/install.sh}" "$repo/os/install.sh"
  chmod 755 "$repo/os/install.sh"
  cp "$BATS_TEST_DIRNAME/fixtures/sudoers/good" "$repo/etc/sudoers.d/pc-oc"
  for f in cpu/apply.sh cpu/revert.sh cpu/probe.sh toolchain/probe.sh bench/probe.sh; do
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
  run --separate-stderr env DESTDIR="$dest" "$repo/os/install.sh"
  [ "$status" -eq 0 ]
  lib_entries="$(cd "$repo" && find lib -type f -printf '644 ./%p\n')"
  expected="$(printf '%s\n' '755 .' '644 ./VERSION' '755 ./cpu' '755 ./cpu/apply.sh' \
    '755 ./cpu/probe.sh' '755 ./cpu/revert.sh' '755 ./lib' "$lib_entries" '755 ./os' \
    '644 ./os/install.sh' '755 ./pc-oc' '755 ./toolchain' '755 ./toolchain/probe.sh' | sort)"
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
  [[ "$EUID" -ne 0 ]] || skip "needs a non-root user"
  run --separate-stderr env -u DESTDIR "$repo/os/install.sh"
  [ "$status" -eq 1 ]
  [[ "${stderr_lines[0]}" == "pc-oc: os: "*root* ]]
}

@test "a sudoers file that fails visudo stops install before anything is copied" {
  echo 'not sudoers' >>"$repo/etc/sudoers.d/pc-oc"
  run --separate-stderr env DESTDIR="$dest" "$repo/os/install.sh"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"pc-oc: os: "*sudoers* ]]
  [ -z "$(find "$dest" -mindepth 1)" ]
}

# Contract #47: install copies every regular file directly under a component dir.
# INSTALL_SH repoints the scratch repo at another install.sh, to watch the cases go red.
# add_real: put the real os and gpu component files in the scratch repo.
add_real() {
  mkdir -p "$repo/os" "$repo/gpu"
  cp "$SRC"/os/{apply.sh,revert.sh,probe.sh,scx_loader.toml} "$repo/os/"
  cp "$SRC"/gpu/{apply.sh,revert.sh,probe.sh,values} "$repo/gpu/"
  echo "# real component files: $(cat "$SRC/os/scx_loader.toml" "$SRC/gpu/values" | wc -c) bytes of data, 2 data files" >&3
}

@test "install copies data files at 0644, byte-identical, and verb scripts at 0755" {
  add_real
  printf 'notes\n' >"$repo/cpu/notes.txt"
  chmod 755 "$repo/cpu/notes.txt" "$repo/os/scx_loader.toml"
  chmod 644 "$repo/os/apply.sh"
  run --separate-stderr env DESTDIR="$dest" "$repo/os/install.sh"
  [ "$status" -eq 0 ]
  inst="$dest/usr/local/lib/pc-oc"
  [ "$(stat -c %a "$inst/os/scx_loader.toml")" = 644 ]
  [ "$(stat -c %a "$inst/gpu/values")" = 644 ]
  [ "$(stat -c %a "$inst/cpu/notes.txt")" = 644 ]
  [ "$(stat -c %a "$inst/os/apply.sh")" = 755 ]
  [ "$(stat -c %a "$inst/gpu/probe.sh")" = 755 ]
  [ "$(stat -c %a "$inst/os")" = 755 ]
  cmp "$repo/os/scx_loader.toml" "$inst/os/scx_loader.toml"
  cmp "$repo/gpu/values" "$inst/gpu/values"
  cmp "$repo/cpu/notes.txt" "$inst/cpu/notes.txt"
}

@test "install copies nothing outside the component dirs, lib and pc-oc" {
  add_real
  mkdir -p "$repo/tests/os/fixtures" "$repo/docs"
  echo x >"$repo/tests/os/fixtures/f" && echo x >"$repo/docs/a.md" && echo x >"$repo/stray.txt"
  run --separate-stderr env DESTDIR="$dest" "$repo/os/install.sh"
  [ "$status" -eq 0 ]
  inst="$dest/usr/local/lib/pc-oc"
  [ -f "$inst/os/scx_loader.toml" ]
  [ ! -e "$inst/tests" ]
  [ ! -e "$inst/docs" ]
  [ ! -e "$inst/stray.txt" ]
  [ ! -e "$inst/bench" ]
  [ "$(find "$inst" -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort | tr '\n' ' ')" = "VERSION cpu gpu lib os pc-oc toolchain " ]
}

@test "the installed tree's os apply then revert round-trips to stock under the scx mocks" {
  add_real
  run --separate-stderr env DESTDIR="$dest" "$repo/os/install.sh"
  [ "$status" -eq 0 ]
  inst="$dest/usr/local/lib/pc-oc"
  fix="$BATS_TEST_DIRNAME/fixtures/scx"
  export SYSFS_ROOT="$BATS_TEST_TMPDIR/root" PC_OC_STATE="$BATS_TEST_TMPDIR/state"
  export MOCK_LOG="$BATS_TEST_TMPDIR/systemctl.log" MOCK_ENABLED="$BATS_TEST_TMPDIR/enabled"
  export PATH="$fix/bin:$PATH"
  sx="$SYSFS_ROOT/sys/kernel/sched_ext"
  mkdir -p "$sx" "$PC_OC_STATE"
  echo disabled >"$sx/state"
  echo disabled >"$MOCK_ENABLED"
  : >"$MOCK_LOG"
  run --separate-stderr bash "$inst/os/apply.sh"
  [ "$status" -eq 0 ]
  cmp "$SRC/os/scx_loader.toml" "$SYSFS_ROOT/etc/scx_loader/config.toml"
  [ "$(cat "$sx/state")" = enabled ]
  run --separate-stderr bash "$inst/os/revert.sh"
  [ "$status" -eq 0 ]
  [ ! -e "$SYSFS_ROOT/etc/scx_loader/config.toml" ]
  [ "$(cat "$MOCK_ENABLED")" = disabled ]
  [ "$(cat "$sx/state")" = disabled ]
  [ -z "$(find "$PC_OC_STATE" -type f)" ]
}

@test "a symlink in a component dir makes install exit 1 naming it, installing nothing" {
  add_real
  ln -s /etc/passwd "$repo/cpu/sneaky-link"
  run --separate-stderr env DESTDIR="$dest" "$repo/os/install.sh"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"pc-oc: os: "*sneaky-link* ]]
  [ -z "$(find "$dest" -mindepth 1)" ]
}

@test "a subdirectory in a component dir makes install exit 1 naming it, installing nothing" {
  add_real
  mkdir -p "$repo/gpu/nested-dir"
  echo x >"$repo/gpu/nested-dir/f"
  run --separate-stderr env DESTDIR="$dest" "$repo/os/install.sh"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"pc-oc: os: "*nested-dir* ]]
  [ -z "$(find "$dest" -mindepth 1)" ]
}

# Contract #107: VERSION is -dirty only when a path the installer copies differs from HEAD.
# Installs, prints the VERSION it read, and leaves it in $version.
install_version() {
  # an empty HOME and XDG_CONFIG_HOME: git reads ~/.config/git/ignore even with
  # GIT_CONFIG_GLOBAL=/dev/null, and the caller's ignore must not decide the stamp
  mkdir -p "$BATS_TEST_TMPDIR/home"
  run --separate-stderr env DESTDIR="$dest" HOME="$BATS_TEST_TMPDIR/home" \
    XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/home/.config" "$repo/os/install.sh"
  [ "$status" -eq 0 ]
  version="$(<"$dest/usr/local/lib/pc-oc/VERSION")"
  printf '# VERSION read: %s\n' "$version" >&3
}

@test "untracked local tool dirs at the repo root leave VERSION as the bare HEAD hash" {
  mkdir -p "$repo/.claude" "$repo/.playwright-mcp"
  echo x >"$repo/.claude/x"
  echo y >"$repo/.playwright-mcp/y"
  install_version
  [[ "$version" =~ ^[0-9a-f]{40}$ ]]
  [ "$version" = "$(git -C "$repo" rev-parse HEAD)" ]
}

@test "a modified tracked file outside the installed paths leaves VERSION as the bare HEAD hash" {
  echo '# local edit' >>"$repo/bench/probe.sh"
  [ -n "$(git -C "$repo" status --porcelain bench)" ]
  install_version
  [[ "$version" =~ ^[0-9a-f]{40}$ ]]
  [ "$version" = "$(git -C "$repo" rev-parse HEAD)" ]
}

@test "an untracked file directly in a component dir makes VERSION -dirty" {
  echo '# new' >"$repo/cpu/extra.sh"
  install_version
  [ "$version" = "$(git -C "$repo" rev-parse HEAD)-dirty" ]
}

@test "a modified tracked file under lib makes VERSION -dirty" {
  echo '# local edit' >>"$repo/lib/common.sh"
  install_version
  [ "$version" = "$(git -C "$repo" rev-parse HEAD)-dirty" ]
}

@test "a modified sudoers drop-in that still passes visudo makes VERSION -dirty" {
  echo '# local comment' >>"$repo/etc/sudoers.d/pc-oc"
  visudo -cf "$repo/etc/sudoers.d/pc-oc" >/dev/null
  install_version
  [ "$version" = "$(git -C "$repo" rev-parse HEAD)-dirty" ]
}

# Amendment 1 of #107: an ignored file inside an installed path is copied, so it counts.
@test "an untracked root .gitignore hiding cpu/extra.sh still makes VERSION -dirty" {
  echo 'cpu/extra.sh' >"$repo/.gitignore"
  echo '# new' >"$repo/cpu/extra.sh"
  install_version
  [ "$version" = "$(git -C "$repo" rev-parse HEAD)-dirty" ]
}

@test "a file hidden by .git/info/exclude inside a component dir makes VERSION -dirty" {
  echo 'cpu/extra.sh' >"$repo/.git/info/exclude"
  echo '# new' >"$repo/cpu/extra.sh"
  install_version
  [ "$version" = "$(git -C "$repo" rev-parse HEAD)-dirty" ]
}

@test "a file under lib hidden by a committed .gitignore is installed and makes VERSION -dirty" {
  echo 'lib/sub/' >"$repo/.gitignore"
  git -C "$repo" add .gitignore
  git -C "$repo" -c user.name=t -c user.email=t@t -c commit.gpgsign=false -c core.hooksPath=/dev/null \
    commit -q -m ignore
  mkdir -p "$repo/lib/sub"
  echo '# hidden' >"$repo/lib/sub/x.sh"
  install_version
  [ -f "$dest/usr/local/lib/pc-oc/lib/sub/x.sh" ]
  [ "$version" = "$(git -C "$repo" rev-parse HEAD)-dirty" ]
}

@test "status.showUntrackedFiles=no in the repo does not hide an untracked file in a component dir" {
  git -C "$repo" config status.showUntrackedFiles no
  echo '# new' >"$repo/cpu/extra.sh"
  install_version
  [ "$version" = "$(git -C "$repo" rev-parse HEAD)-dirty" ]
}

# Contract #124: install puts systemd/pc-oc-gpu.service at etc/systemd/system and calls no systemctl.
@test "a DESTDIR install puts the boot unit at etc/systemd/system, mode 0644, byte-identical" {
  [ "$(stat -c %a "$repo/systemd/pc-oc-gpu.service")" = 755 ]
  run --separate-stderr env DESTDIR="$dest" "$repo/os/install.sh"
  [ "$status" -eq 0 ]
  [ -f "$unit" ]
  [ ! -L "$unit" ]
  cmp "$repo/systemd/pc-oc-gpu.service" "$unit"
  [ "$(stat -c %a "$unit")" = 644 ]
}

# install.sh pins PATH=/usr/bin, so a mock put first on PATH is never the systemctl it would run.
# The install runs in a mount namespace with a recording mock bound over /usr/bin/systemctl; the
# uid stays the caller's, so this is the DESTDIR path, never root. The unit must be installed:
# an install that skips the unit calls no systemctl either.
@test "a DESTDIR install that installs the boot unit calls systemctl 0 times" {
  local log="$BATS_TEST_TMPDIR/systemctl.log" mocks="$BATS_TEST_TMPDIR/mocks"
  mkdir -p "$mocks"
  cat >"$mocks/systemctl" <<EOF
#!/usr/bin/bash
# pc-oc-test-mock
echo "systemctl \$*" >>"$log"
EOF
  chmod +x "$mocks/systemctl"
  cat >"$BATS_TEST_TMPDIR/guard.sh" <<EOF
#!/usr/bin/bash
mount --bind "$mocks/systemctl" /usr/bin/systemctl || exit 97
[[ "\$(sed -n 2p /usr/bin/systemctl)" == "# pc-oc-test-mock" ]] || exit 97
[[ "\$(/usr/bin/id -u)" != 0 ]] || exit 97
exec "\$@"
EOF
  run --separate-stderr unshare --map-user="$(id -u)" --map-group="$(id -g)" --keep-caps -m \
    bash "$BATS_TEST_TMPDIR/guard.sh" env DESTDIR="$dest" PATH="$mocks:$PATH" "$repo/os/install.sh"
  [ "$status" -eq 0 ]
  [ -f "$unit" ]
  [ ! -e "$log" ] || {
    echo "install called: $(tr '\n' ';' <"$log")" >&3
    return 1
  }
}

@test "an uncommitted edit to systemd/pc-oc-gpu.service makes VERSION -dirty" {
  echo '# local edit' >>"$repo/systemd/pc-oc-gpu.service"
  install_version
  [ "$version" = "$(git -C "$repo" rev-parse HEAD)-dirty" ]
}

@test "an untracked systemd/x makes VERSION -dirty" {
  echo x >"$repo/systemd/x"
  install_version
  [ "$version" = "$(git -C "$repo" rev-parse HEAD)-dirty" ]
}

# twice: installing the unit must not touch the checkout, or the second stamp would be -dirty
@test "a clean tree with the boot unit installed leaves VERSION as the bare HEAD hash, twice" {
  install_version
  [ -f "$unit" ]
  [ "$version" = "$(git -C "$repo" rev-parse HEAD)" ]
  install_version
  [ "$version" = "$(git -C "$repo" rev-parse HEAD)" ]
}

# every path under DESTDIR with its type, mode, inode, size, mtime and content hash
dest_snapshot() {
  (cd "$dest" && find . -printf '%p %y %m %i %s %T@\n' | LC_ALL=C sort &&
    find . -type f -exec sha256sum {} + | LC_ALL=C sort)
}

@test "with systemd/pc-oc-gpu.service deleted install exits 1 and DESTDIR holds no new or changed file" {
  run --separate-stderr env DESTDIR="$dest" "$repo/os/install.sh"
  [ "$status" -eq 0 ]
  dest_snapshot >"$BATS_TEST_TMPDIR/before"
  echo "# DESTDIR before: $(grep -c ' f ' "$BATS_TEST_TMPDIR/before") files" >&3
  rm "$repo/systemd/pc-oc-gpu.service"
  run --separate-stderr env DESTDIR="$dest" "$repo/os/install.sh"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"pc-oc: os: "* ]]
  dest_snapshot >"$BATS_TEST_TMPDIR/after"
  diff "$BATS_TEST_TMPDIR/before" "$BATS_TEST_TMPDIR/after" >&3
}

@test "an existing unit at the destination is replaced and no temporary name is left beside it" {
  mkdir -p "$dest/etc/systemd/system"
  printf '[Unit]\nDescription=stale\n' >"$unit"
  run --separate-stderr env DESTDIR="$dest" "$repo/os/install.sh"
  [ "$status" -eq 0 ]
  cmp "$repo/systemd/pc-oc-gpu.service" "$unit"
  [ "$(ls -A "$dest/etc/systemd/system")" = pc-oc-gpu.service ]
}

# #124 Amendment 1: interface rules the contract has no case for. Added with the installer
# change, not by the contracts worker.
@test "a missing etc/systemd/system is created 0755 under a caller umask of 077" {
  umask 077
  run --separate-stderr env DESTDIR="$dest" "$repo/os/install.sh"
  [ "$status" -eq 0 ]
  [ -f "$unit" ]
  [ "$(stat -c %a "$dest/etc/systemd")" = 755 ]
  [ "$(stat -c %a "$dest/etc/systemd/system")" = 755 ]
}

@test "a file under systemd hidden by .git/info/exclude makes VERSION -dirty" {
  echo 'systemd/x' >"$repo/.git/info/exclude"
  echo x >"$repo/systemd/x"
  [ -z "$(git -C "$repo" status --porcelain)" ]
  install_version
  [ "$version" = "$(git -C "$repo" rev-parse HEAD)-dirty" ]
}

@test "an unreadable systemd/pc-oc-gpu.service makes install exit 1 naming it, installing nothing" {
  [[ "$EUID" -ne 0 ]] || skip "needs a non-root user: root reads a mode 000 file"
  chmod 000 "$repo/systemd/pc-oc-gpu.service"
  run --separate-stderr env DESTDIR="$dest" "$repo/os/install.sh"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"pc-oc: os: "*pc-oc-gpu.service* ]]
  [ -z "$(find "$dest" -mindepth 1)" ]
}

@test "a symlink at systemd/pc-oc-gpu.service makes install exit 1 naming it, installing nothing" {
  cp "$repo/systemd/pc-oc-gpu.service" "$BATS_TEST_TMPDIR/elsewhere.service"
  ln -sf "$BATS_TEST_TMPDIR/elsewhere.service" "$repo/systemd/pc-oc-gpu.service"
  run --separate-stderr env DESTDIR="$dest" "$repo/os/install.sh"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"pc-oc: os: "*pc-oc-gpu.service* ]]
  [ -z "$(find "$dest" -mindepth 1)" ]
}

@test "a directory at systemd/pc-oc-gpu.service makes install exit 1 naming it, installing nothing" {
  rm "$repo/systemd/pc-oc-gpu.service"
  mkdir "$repo/systemd/pc-oc-gpu.service"
  echo x >"$repo/systemd/pc-oc-gpu.service/f"
  run --separate-stderr env DESTDIR="$dest" "$repo/os/install.sh"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"pc-oc: os: "*pc-oc-gpu.service* ]]
  [ -z "$(find "$dest" -mindepth 1)" ]
}

# the temporary name is the installer's: .pc-oc-gpu.service.new
@test "a world-writable temporary name left by an earlier run still gives a 0644 unit" {
  mkdir -p "$dest/etc/systemd/system"
  echo stale >"$dest/etc/systemd/system/.pc-oc-gpu.service.new"
  chmod 666 "$dest/etc/systemd/system/.pc-oc-gpu.service.new"
  run --separate-stderr env DESTDIR="$dest" "$repo/os/install.sh"
  [ "$status" -eq 0 ]
  cmp "$repo/systemd/pc-oc-gpu.service" "$unit"
  [ "$(stat -c %a "$unit")" = 644 ]
  [ "$(ls -A "$dest/etc/systemd/system")" = pc-oc-gpu.service ]
}
