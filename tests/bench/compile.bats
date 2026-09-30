#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup() {
  FIX="$BATS_TEST_DIRNAME/fixtures/compile"
  TARBALL="$FIX/linux-6.12.1.tar.xz"
  SHA=a946d1c9838a530316717e3827dc1fc4f8d8a6b202316ae570c1282ee9574cfc
  # compile.sh reads bench/kernel.pin next to itself: run a copy in a fake repo
  REPO="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$REPO/bench" "$REPO/lib"
  cp "$BATS_TEST_DIRNAME/../../bench/compile.sh" "$REPO/bench/"
  cp "$BATS_TEST_DIRNAME/../../lib/common.sh" "$REPO/lib/"
  cp "$FIX/kernel.pin" "$REPO/bench/"
  SCRIPT="$REPO/bench/compile.sh"
  export XDG_CACHE_HOME="$BATS_TEST_TMPDIR/cache"
  export TMPDIR="$BATS_TEST_TMPDIR/tmp"
  mkdir -p "$TMPDIR"
  STUB_DIR="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB_DIR"
  write_stubs
  export PATH="$STUB_DIR:$PATH"
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

# value <key>: print the value of stdout line <key>=
value() {
  local l
  for l in "${lines[@]}"; do
    [[ "$l" == "$1="* ]] && printf '%s\n' "${l#"$1="}" && return 0
  done
  return 1
}

# in_range <x> <lo> <hi>: lo <= x < hi
in_range() {
  awk -v x="$1" -v lo="$2" -v hi="$3" 'BEGIN { exit !(x >= lo && x < hi) }'
}

# contract_order: stdout is input.* lines, then result.* lines, nothing else
contract_order() {
  local seen=0 l
  for l in "${lines[@]}"; do
    case "$l" in
      input.*=*) [ "$seen" -eq 0 ] || return 1 ;;
      result.*=*) seen=1 ;;
      *) return 1 ;;
    esac
  done
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
