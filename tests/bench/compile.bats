#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

load helper

setup() {
  FIX="$BATS_TEST_DIRNAME/fixtures/compile"
  TARBALL="$FIX/linux-6.12.1.tar.xz"
  SHA=a946d1c9838a530316717e3827dc1fc4f8d8a6b202316ae570c1282ee9574cfc
  # compile.sh reads bench/kernel.pin next to itself: run a copy in a fake repo
  REPO="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$REPO/bench" "$REPO/lib"
  cp "$BATS_TEST_DIRNAME/../../bench/compile.sh" "$BATS_TEST_DIRNAME/../../bench/lib.sh" "$REPO/bench/"
  cp "$BATS_TEST_DIRNAME/../../lib/common.sh" "$REPO/lib/"
  cp "$FIX/kernel.pin" "$REPO/bench/"
  SCRIPT="$REPO/bench/compile.sh"
  export XDG_CACHE_HOME="$BATS_TEST_TMPDIR/cache"
  CACHE="$XDG_CACHE_HOME/pc-oc"
  export TMPDIR="$BATS_TEST_TMPDIR/tmp"
  mkdir -p "$TMPDIR"
  STUB_DIR="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB_DIR"
  write_stubs
  # build tools the script only checks for: stubbed ahead of the real PATH so
  # the suite is the same with or without them (the bc-missing case replaces PATH)
  TOOLS_DIR="$BATS_TEST_TMPDIR/tools"
  mkdir -p "$TOOLS_DIR"
  for t in bc flex bison perl cpio openssl; do
    printf '#!/usr/bin/env bash\nexit 0\n' >"$TOOLS_DIR/$t"
  done
  chmod +x "$TOOLS_DIR"/*
  export PATH="$STUB_DIR:$TOOLS_DIR:$PATH"
  BASE_PATH="$PATH"
}

# write_stubs: curl copies the fixture tarball; make logs args and cwd, sleeps
# 0.2 s per clean and 0.30, 0.05, 0.10 s on builds 1-3; nproc says 7
write_stubs() {
  cat >"$STUB_DIR/curl" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$BATS_TEST_TMPDIR/calls-curl"
out=""
prev=""
for a in "\$@"; do
  case "\$prev" in -o | --output | -[a-zA-Z]*o) out="\$a" ;; esac
  case "\$a" in --output=*) out="\${a#--output=}" ;; esac
  prev="\$a"
done
if [ -n "\$out" ]; then cp "$TARBALL" "\$out"; else cat "$TARBALL"; fi
STUB
  cat >"$STUB_DIR/make" <<STUB
#!/usr/bin/env bash
if [ "\$1" = --version ]; then echo 'GNU Make 4.4.1'; exit 0; fi
printf '%s\t%s\n' "\$*" "\$PWD" >>"$BATS_TEST_TMPDIR/calls-make"
dir=.
prev=""
for a in "\$@"; do [ "\$prev" = -C ] && dir="\$a"; prev="\$a"; done
[ -f "\$dir/Makefile" ] || { echo "stub make: no Makefile in \$dir" >&2; exit 2; }
case " \$* " in
  *" clean "*) sleep 0.2 ;;
  *" -j"*)
    n=\$(grep -c -- '-j' "$BATS_TEST_TMPDIR/calls-make")
    sleep "\$(echo 0.30 0.05 0.10 | cut -d' ' -f"\$n")"
    ;;
esac
exit 0
STUB
  printf '#!/usr/bin/env bash\necho 7\n' >"$STUB_DIR/nproc"
  printf '#!/usr/bin/env bash\necho "gcc (GCC) 15.2.1 20250813"\n' >"$STUB_DIR/gcc"
  chmod +x "$STUB_DIR"/*
}

# wired_refused: status 1, one stderr line naming what was wired, and no
# download or build step ran (#118); callers set the environment first
wired_refused() {
  [ "$status" -eq 1 ]
  [ "${#stderr_lines[@]}" -eq 1 ]
  [[ "$stderr" == "pc-oc: bench: wired build environment: "* ]]
  [ ! -e "$BATS_TEST_TMPDIR/calls-curl" ]
  [ ! -e "$BATS_TEST_TMPDIR/calls-make" ]
}

# in_range <x> <lo> <hi>: lo <= x < hi
in_range() {
  awk -v x="$1" -v lo="$2" -v hi="$3" 'BEGIN { exit !(x >= lo && x < hi) }'
}

@test "compile times 3 builds by default and prints each run and the median" {
  run --separate-stderr bash "$SCRIPT"
  [ "$status" -eq 0 ]
  contract_order
  [ "$(value input.kernel_version)" = 6.12.1 ]
  [ "$(value input.sha256)" = "$SHA" ]
  [[ "$(value input.gcc)" == *15.2.1* ]]
  [[ "$(value input.make)" == *4.4.1* ]]
  [ "$(value input.nproc)" = 7 ]
  [ "$(value input.runs)" = 3 ]
  r1="$(value result.compile.run1_s)"
  r2="$(value result.compile.run2_s)"
  r3="$(value result.compile.run3_s)"
  [ -z "$(value result.compile.run4_s)" ]
  # each run times its own build: not the clean before it, not earlier runs
  in_range "$r1" 0.30 0.45
  in_range "$r2" 0.05 0.20
  in_range "$r3" 0.10 0.25
  mid="$(printf '%s\n' "$r1" "$r2" "$r3" | sort -g | sed -n 2p)"
  median="$(value result.compile.median_s)"
  awk -v a="$median" -v b="$mid" 'BEGIN { exit !(a - b < 0.001 && b - a < 0.001) }'
}

@test "compile runs defconfig once, clean and make -j\$(nproc) per run, in a temp dir it removes" {
  run --separate-stderr bash "$SCRIPT" 3
  [ "$status" -eq 0 ]
  cut -f1 "$BATS_TEST_TMPDIR/calls-make" >"$BATS_TEST_TMPDIR/args"
  [ "$(head -1 "$BATS_TEST_TMPDIR/args")" = defconfig ]
  [ "$(grep -cw defconfig "$BATS_TEST_TMPDIR/args")" -eq 1 ]
  [ "$(grep -cw clean "$BATS_TEST_TMPDIR/args")" -eq 3 ]
  [ "$(grep -c -- '-j7' "$BATS_TEST_TMPDIR/args")" -eq 3 ]
  [[ "$(head -1 "$BATS_TEST_TMPDIR/calls-make" | cut -f2)" == "$TMPDIR/"* ]]
  [ -z "$(find "$TMPDIR" -mindepth 1)" ]
}

@test "compile line 1 names the cached tarball, its bytes and its entry count" {
  run --separate-stderr bash "$SCRIPT" 1
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" =~ ^input\.source=(/[^\ ]+)\ bytes=([0-9]+)\ items=([0-9]+)$ ]]
  [[ "${BASH_REMATCH[1]}" == "$XDG_CACHE_HOME/pc-oc/"* ]]
  [ "$(sha256sum <"${BASH_REMATCH[1]}" | cut -d' ' -f1)" = "$SHA" ]
  [ "${BASH_REMATCH[2]}" -eq "$(wc -c <"$TARBALL")" ]
  [ "${BASH_REMATCH[3]}" -eq "$(tar -tf "$TARBALL" | wc -l)" ]
}

@test "compile downloads the pinned url once and reuses the cache" {
  run --separate-stderr bash "$SCRIPT" 1
  [ "$status" -eq 0 ]
  run --separate-stderr bash "$SCRIPT" 1
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$BATS_TEST_TMPDIR/calls-curl")" -eq 1 ]
  grep -qF 'https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.12.1.tar.xz' "$BATS_TEST_TMPDIR/calls-curl"
}

@test "compile exits 1 on a sha256 mismatch, deletes the download, never builds" {
  sed -i "s/^sha256=.*/sha256=$(printf '0%.0s' {1..64})/" "$REPO/bench/kernel.pin"
  run --separate-stderr bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$stderr" == "pc-oc: bench: sha256 mismatch"* ]]
  [ -s "$BATS_TEST_TMPDIR/calls-curl" ]
  [ ! -e "$BATS_TEST_TMPDIR/calls-make" ]
  [ -z "$(find "$XDG_CACHE_HOME" -type f)" ]
  [ -z "$(find "$TMPDIR" -mindepth 1)" ]
}

@test "compile exits 2 on runs=0 without downloading" {
  run --separate-stderr bash "$SCRIPT" 0
  [ "$status" -eq 2 ]
  [ ! -e "$BATS_TEST_TMPDIR/calls-curl" ]
}

@test "compile exits 1 with pc-oc: bench: make defconfig/clean/build failed when make fails" {
  for t in bc flex bison perl cpio openssl; do
    printf '#!/usr/bin/env bash\nexit 0\n' >"$STUB_DIR/$t"
  done
  cat >"$STUB_DIR/make" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = --version ]; then echo 'GNU Make 4.4.1'; exit 0; fi
case " $* " in *" -j"*) exit 2 ;; esac
exit 0
STUB
  chmod +x "$STUB_DIR"/*
  run --separate-stderr bash "$SCRIPT" 1
  [ "$status" -eq 1 ]
  [[ "$stderr" == "pc-oc: bench: make"* ]]
  [[ "$output" != *result.compile.* ]]
}

@test "compile exits 1 naming bc when bc is missing, before any download" {
  mkdir -p "$BATS_TEST_TMPDIR/nobc"
  for f in /usr/bin/*; do
    [ "${f##*/}" = bc ] || ln -s "$f" "$BATS_TEST_TMPDIR/nobc/"
  done
  export PATH="$STUB_DIR:$BATS_TEST_TMPDIR/nobc"
  run --separate-stderr bash "$SCRIPT" 1
  [ "$status" -eq 1 ]
  [ "$stderr" = "pc-oc: bench: bc not found; install: pacman -S bc" ]
  [ ! -e "$BATS_TEST_TMPDIR/calls-curl" ]
}

@test "compile names the failing make target for defconfig and clean too" {
  for t in defconfig clean; do
    cat >"$STUB_DIR/make" <<STUB
#!/usr/bin/env bash
if [ "\$1" = --version ]; then echo 'GNU Make 4.4.1'; exit 0; fi
[ "\$1" = $t ] && exit 2
exit 0
STUB
    run --separate-stderr bash "$SCRIPT" 1
    [ "$status" -eq 1 ]
    [[ "$stderr" == "pc-oc: bench: make $t failed"* ]]
    [[ "$output" != *result.compile.* ]]
  done
}

# stub_tar <fail-flag>: tar that exits 2 when its first argument is -<flag>f, else real tar
stub_tar() {
  cat >"$STUB_DIR/tar" <<STUB
#!/usr/bin/env bash
[ "\$1" = -$1f ] && exit 2
exec /usr/bin/tar "\$@"
STUB
  chmod +x "$STUB_DIR/tar"
}

@test "compile exits 1 with pc-oc: bench: tar when extraction fails" {
  stub_tar x
  run --separate-stderr bash "$SCRIPT" 1
  [ "$status" -eq 1 ]
  [[ "$stderr" == "pc-oc: bench: tar"* ]]
  [[ "$output" != *result.compile.* ]]
  [ -z "$(find "$TMPDIR" -mindepth 1)" ]
}

@test "compile exits 1 with pc-oc: bench: tar when listing fails" {
  stub_tar t
  run --separate-stderr bash "$SCRIPT" 1
  [ "$status" -eq 1 ]
  [[ "$stderr" == "pc-oc: bench: tar"* ]]
  [[ "$output" != *result.compile.* ]]
}

@test "compile exits 1 with pc-oc: bench: when the cache dir cannot be created" {
  : >"$BATS_TEST_TMPDIR/file"
  export XDG_CACHE_HOME="$BATS_TEST_TMPDIR/file"
  run --separate-stderr bash "$SCRIPT" 1
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"pc-oc: bench: cannot create"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/calls-curl" ]
}

@test "compile exits 1 with pc-oc: bench: mktemp when TMPDIR is missing" {
  export TMPDIR="$BATS_TEST_TMPDIR/nonexistent"
  run --separate-stderr bash "$SCRIPT" 1
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"pc-oc: bench: mktemp"* ]]
  [[ "$output" != *result.compile.* ]]
}

@test "compile exits 1 with pc-oc: bench: when kernel.pin is missing" {
  rm "$REPO/bench/kernel.pin"
  run --separate-stderr bash "$SCRIPT" 1
  [ "$status" -eq 1 ]
  [ "${stderr_lines[-1]}" = "pc-oc: bench: kernel.pin: unreadable" ]
}

# the cases below chmod dirs read-only; hand them back so bats can clean up
teardown() {
  chmod -R u+rwX "$BATS_TEST_TMPDIR" 2>/dev/null || :
}

# need_non_root: root ignores the dir permissions these cases rely on
need_non_root() {
  [ "$(id -u)" -ne 0 ] || skip "root ignores dir permissions"
}

# seed_tarball <dir> <entry> [tar-opt...]: cache a tarball of <dir>/<entry>
# under the pinned name and pin its sha256
seed_tarball() {
  local cached="$CACHE/linux-6.12.1.tar.xz"
  mkdir -p "${cached%/*}"
  tar -C "$1" "${@:3}" -cJf "$cached" "$2"
  sed -i "s/^sha256=.*/sha256=$(sha256sum <"$cached" | cut -d' ' -f1)/" "$REPO/bench/kernel.pin"
}

@test "compile exits 1 naming the key when kernel.pin lacks one, before any download" {
  sed -i '/^sha256=/d' "$REPO/bench/kernel.pin"
  run --separate-stderr bash "$SCRIPT" 1
  [ "$status" -eq 1 ]
  [ "$stderr" = "pc-oc: bench: kernel.pin: missing sha256" ]
  [ ! -e "$BATS_TEST_TMPDIR/calls-curl" ]
}

@test "compile exits 1 with pc-oc: bench: make build failed when the build fails" {
  cat >"$STUB_DIR/make" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = --version ]; then echo 'GNU Make 4.4.1'; exit 0; fi
case "$1" in -j*) exit 2 ;; esac
exit 0
STUB
  run --separate-stderr bash "$SCRIPT" 1
  [ "$status" -eq 1 ]
  [[ "$stderr" == "pc-oc: bench: make build failed"* ]]
  [[ "$output" != *result.compile.* ]]
}

@test "compile exits 1 with pc-oc: bench: download failed when the partial file cannot be removed" {
  need_non_root
  cat >"$STUB_DIR/curl" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$BATS_TEST_TMPDIR/calls-curl"
echo partial >"$CACHE/linux-6.12.1.tar.xz"
chmod 555 "$CACHE"
exit 22
STUB
  run --separate-stderr bash "$SCRIPT" 1
  [ "$status" -eq 1 ]
  [ "${stderr_lines[-1]}" = "pc-oc: bench: download failed: https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.12.1.tar.xz" ]
  [ ! -e "$BATS_TEST_TMPDIR/calls-make" ]
}

@test "compile exits 1 with pc-oc: bench: sha256 mismatch when the cache dir is read-only" {
  need_non_root
  mkdir -p "$CACHE"
  echo wrong >"$CACHE/linux-6.12.1.tar.xz"
  chmod 555 "$CACHE"
  run --separate-stderr bash "$SCRIPT" 1
  [ "$status" -eq 1 ]
  [[ "${stderr_lines[-1]}" == "pc-oc: bench: sha256 mismatch"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/calls-curl" ]
  [ ! -e "$BATS_TEST_TMPDIR/calls-make" ]
}

@test "compile exits 1 with pc-oc: bench: sha256sum failed when the cached tarball is unreadable" {
  need_non_root
  mkdir -p "$CACHE"
  cp "$TARBALL" "$CACHE/"
  chmod 000 "$CACHE/linux-6.12.1.tar.xz"
  run --separate-stderr bash "$SCRIPT" 1
  [ "$status" -eq 1 ]
  [[ "${stderr_lines[-1]}" == "pc-oc: bench: sha256sum failed"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/calls-make" ]
}

@test "compile exits 1 with pc-oc: bench: cannot read when the tarball size fails" {
  cat >"$STUB_DIR/wc" <<'STUB'
#!/usr/bin/env bash
[ "$1" = -c ] && exit 1
exec /usr/bin/wc "$@"
STUB
  chmod +x "$STUB_DIR/wc"
  run --separate-stderr bash "$SCRIPT" 1
  [ "$status" -eq 1 ]
  [[ "$stderr" == "pc-oc: bench: cannot read"* ]]
  [[ "$output" != *result.compile.* ]]
}

@test "compile exits 1 with pc-oc: bench: when the tarball has no top directory" {
  mkdir -p "$BATS_TEST_TMPDIR/flat"
  : >"$BATS_TEST_TMPDIR/flat/Makefile"
  seed_tarball "$BATS_TEST_TMPDIR/flat" Makefile
  run --separate-stderr bash "$SCRIPT" 1
  [ "$status" -eq 1 ]
  [ "$stderr" = "pc-oc: bench: tarball has no top directory" ]
  [ ! -e "$BATS_TEST_TMPDIR/calls-make" ]
}

@test "compile exits 1 with pc-oc: bench: cannot enter when the top directory is closed" {
  need_non_root
  mkdir -p "$BATS_TEST_TMPDIR/closed/linux-6.12.1"
  seed_tarball "$BATS_TEST_TMPDIR/closed" linux-6.12.1 --mode=000
  run --separate-stderr bash "$SCRIPT" 1
  [ "$status" -eq 1 ]
  [[ "${stderr_lines[-1]}" == "pc-oc: bench: cannot enter"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/calls-make" ]
}

@test "compile refuses each wired variable, naming it, before any download or build" {
  skip "contract #118 pending"
  local v
  for v in CC CXX LDFLAGS RUSTC_WRAPPER CMAKE_C_COMPILER_LAUNCHER CMAKE_CXX_COMPILER_LAUNCHER; do
    rm -f "$BATS_TEST_TMPDIR/calls-curl" "$BATS_TEST_TMPDIR/calls-make"
    run --separate-stderr env "$v=wired" bash "$SCRIPT" 1
    wired_refused || {
      echo "$v: status $status, stderr: $stderr" >&2
      return 1
    }
    [ "$stderr" = "pc-oc: bench: wired build environment: $v" ] || {
      echo "$v: stderr: $stderr" >&2
      return 1
    }
  done
}

@test "compile refuses a compiler-wrapper dir on PATH, first or mid-PATH, trailing slash or not" {
  skip "contract #118 pending"
  run --separate-stderr env "PATH=/usr/lib/sccache/bin:$BASE_PATH" bash "$SCRIPT" 1
  wired_refused
  [[ "$stderr" == *"/usr/lib/sccache/bin"* ]]
  rm -f "$BATS_TEST_TMPDIR/calls-curl" "$BATS_TEST_TMPDIR/calls-make"
  run --separate-stderr env "PATH=$STUB_DIR:/usr/lib/ccache/bin/:$BASE_PATH" bash "$SCRIPT" 1
  wired_refused
  [[ "$stderr" == *"/usr/lib/ccache/bin"* ]]
}

@test "compile lists every offender on the one line" {
  skip "contract #118 pending"
  run --separate-stderr env RUSTC_WRAPPER=sccache LDFLAGS=-fuse-ld=mold \
    "PATH=/usr/lib/ccache/bin:$BASE_PATH" bash "$SCRIPT" 1
  wired_refused
  [[ "$stderr" == *RUSTC_WRAPPER* ]]
  [[ "$stderr" == *LDFLAGS* ]]
  [[ "$stderr" == *"/usr/lib/ccache/bin"* ]]
}

@test "compile ignores empty wired variables and a clean PATH" {
  skip "contract #118 pending"
  clean="$(printf '%s' "$BASE_PATH" | tr ':' '\n' | grep -vxE '/usr/lib/(sccache|ccache)/bin/?' | paste -sd:)"
  run --separate-stderr env -u CC -u CXX -u LDFLAGS -u RUSTC_WRAPPER \
    -u CMAKE_C_COMPILER_LAUNCHER -u CMAKE_CXX_COMPILER_LAUNCHER \
    CC= LDFLAGS= "PATH=$clean" bash "$SCRIPT" 1
  [ "$status" -eq 0 ]
  [ "$(value input.runs)" = 1 ]
  [ -s "$BATS_TEST_TMPDIR/calls-make" ]
}
