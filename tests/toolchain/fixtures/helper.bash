# shellcheck shell=bash disable=SC2034,SC2154 # status, output, stderr and stderr_lines are
# set by bats run; the names below are read by the tests/toolchain/*.bats files
# Shared helpers for the #119 contract: tests/toolchain/*.bats.

# The two marker lines of lib/block.sh (#116) and the three block data files.
BEGIN='# >>> pc-oc wiring >>>'
END='# <<< pc-oc wiring <<<'
NAMES=(cargo fish makepkg)

# common_setup: BOX, a directory of the test that holds everything a script could reach:
# the fake home H (empty) with its three targets, and what guard.sh binds in the namespace:
# the stand-in for /usr/bin (a link to the real tool for every name but sccache, mold and
# cmake), the stand-in for /usr/lib/sccache/bin, and a passwd whose only home is a second
# empty directory. sccache, mold and cc start as mocks, cmake is absent. The working
# directory is BOX, so a relative HOME lands in it. What bats itself writes (the stderr of
# run) and the copies a case keeps for a later compare stay beside BOX, not in it.
common_setup() {
  unset "${!GIT_@}"
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  FIX="$BATS_TEST_DIRNAME/fixtures"
  BOX="$BATS_TEST_TMPDIR/box"
  H="$BOX/home"
  CARGO="$H/.cargo/config.toml"
  FISH="$H/.config/fish/config.fish"
  MAKEPKG="$H/.config/pacman/makepkg.conf"
  export GUARD_HOLD="$BOX/usr"
  export GUARD_BIN="$BOX/bin"
  export GUARD_SCCACHE_BIN="$BOX/sccache-bin"
  export GUARD_PASSWD="$BOX/passwd"
  export GUARD_PASSWD_HOME="$BOX/passwd-home"
  mkdir "$BOX" "$H" "$GUARD_HOLD" "$GUARD_BIN" "$GUARD_SCCACHE_BIN" "$GUARD_PASSWD_HOME"
  printf '%s\n' "root:x:0:0::$GUARD_PASSWD_HOME:/usr/bin/bash" \
    "pc-oc-test:x:$(id -u):$(id -g)::$GUARD_PASSWD_HOME:/usr/bin/bash" >"$GUARD_PASSWD"
  local -a names
  mapfile -d '' names < <(find /usr/bin -mindepth 1 -maxdepth 1 \
    ! -name sccache ! -name mold ! -name cmake -print0)
  printf '%s\0' "${names[@]/#\/usr\/bin/"$GUARD_HOLD/bin"}" | xargs -0 ln -s -t "$GUARD_BIN"
  tool_present sccache mold cc
  cd "$BOX" || return 1
}

# target <cargo|fish|makepkg>: the file the block of that name goes into
target() {
  case "$1" in
    cargo) printf '%s\n' "$CARGO" ;;
    fish) printf '%s\n' "$FISH" ;;
    makepkg) printf '%s\n' "$MAKEPKG" ;;
    *) return 1 ;;
  esac
}

# tool_dir <name>: where the namespace shows that tool: cc in /usr/lib/sccache/bin, the
# others in /usr/bin
tool_dir() {
  case "$1" in
    cc) printf '%s\n' "$GUARD_SCCACHE_BIN" ;;
    *) printf '%s\n' "$GUARD_BIN" ;;
  esac
}

# mock_at <file>: a mock program; it prints its arguments, one "arg=<argument>" line each,
# then its environment
mock_at() {
  printf '%s\n' '#!/usr/bin/bash' '# pc-oc-test-mock' \
    'printf "arg=%s\n" "$@"' 'exec /usr/bin/env' >"$1"
  chmod 755 "$1"
}

# tool_present <sccache|mold|cmake|cc>...: a mock of that name in the namespace
tool_present() {
  local name
  for name in "$@"; do
    mock_at "$(tool_dir "$name")/$name"
  done
}

# tool_absent <sccache|mold|cmake|cc>...: no file of that name in the namespace
tool_absent() {
  local name
  for name in "$@"; do
    rm -f -- "$(tool_dir "$name")/$name"
  done
}

# framed <name>: BEGIN, the data file of the tree under test, END
framed() {
  printf '%s\n' "$BEGIN" && cat "$ROOT/toolchain/$1.block" && printf '%s\n' "$END"
}

# wire <name>...: append the framed block to that target, as a finished apply leaves it
wire() {
  local name file
  for name in "$@"; do
    file="$(target "$name")"
    mkdir -p "${file%/*}"
    framed "$name" >>"$file"
  done
}

# stock <name>...: that target with other content and no block
stock() {
  local name file
  for name in "$@"; do
    file="$(target "$name")"
    mkdir -p "${file%/*}"
    case "$name" in
      cargo) printf '%s\n' '[net]' 'git-fetch-with-cli = true' >"$file" ;;
      fish) cp "$FIX/config.fish" "$file" ;;
      makepkg) printf '%s\n' 'MAKEFLAGS="-j20"' 'PKGEXT=".pkg.tar.zst"' >"$file" ;;
    esac
  done
}

# as_symlink <name>: that target is a link to a regular file elsewhere in the fake home
as_symlink() {
  local file
  file="$(target "$1")"
  mkdir -p "${file%/*}" "$H/dotfiles"
  printf '%s\n' '# kept in the dotfiles directory' >"$H/dotfiles/$1"
  ln -s "$H/dotfiles/$1" "$file"
}

# as_directory <name>: that target is a directory
as_directory() {
  mkdir -p "$(target "$1")"
}

# as_malformed <name>: that target has a BEGIN line and no END line
as_malformed() {
  local file
  file="$(target "$1")"
  mkdir -p "${file%/*}"
  printf '%s\n' '# a line of the user' "$BEGIN" '# the END line is gone' >"$file"
}

# listing <home|rest>: one line per entry (type, mode, path, link target) and the sha256 of
# every file, of the fake home or of everything else in BOX
listing() {
  local dir="$BOX"
  local -a prune=(-path ./home -prune -o)
  if [[ "$1" == home ]]; then
    dir="$H"
    prune=()
  fi
  (
    cd "$dir" && export LC_ALL=C &&
      find . "${prune[@]}" -printf '%y %m %p -> %l\n' | sort &&
      find . "${prune[@]}" -type f -print0 | sort -z | xargs -0 -r sha256sum
  )
}

# same_listing <home|rest> <before>: nothing in that part was created, changed or removed
same_listing() {
  local after
  after="$(listing "$1")"
  [[ "$after" == "$2" ]] && return 0
  echo "the $1 part of the test directory changed:" >&2
  diff <(printf '%s\n' "$2") <(printf '%s\n' "$after") >&2 || true
  return 1
}

# unchanged: the fake home is as it was before the last start of a script
unchanged() {
  same_listing home "$HOME_BEFORE"
}

# in_ns <user|root> <command...>: run the command in a private mount namespace behind
# guard.sh. "root" is unshare -r, where /usr/bin/id -u prints 0; "user" keeps the caller's
# uid. timeout only bounds a script that hangs.
in_ns() {
  local who="$1"
  shift
  local -a map=(--map-user="$(id -u)" --map-group="$(id -g)" --keep-caps)
  [[ "$who" == user ]] || map=(-r)
  GUARD_AS="$who" timeout -k 5 60 unshare "${map[@]}" -m bash "$FIX/guard.sh" "$@"
}

# toolchain <user|root> <apply|revert|probe> [NAME=value...]: one start of the script, the
# way pc-oc starts it: its whole environment is PATH=/usr/bin and HOME (the fake home),
# plus the variables given; a HOME among them wins, NO_HOME=1 leaves HOME out. Whatever
# the script does, nothing outside the fake home may change; that is checked here.
toolchain() {
  local who="$1" verb="$2" rest
  shift 2
  local -a home=("HOME=$H")
  [[ -z "${NO_HOME:-}" ]] || home=()
  HOME_BEFORE="$(listing home)"
  rest="$(listing rest)"
  run --separate-stderr in_ns "$who" /usr/bin/env -i PATH=/usr/bin "${home[@]}" "$@" \
    /usr/bin/bash "$ROOT/toolchain/$verb.sh"
  same_listing rest "$rest"
}

apply() {
  toolchain user apply "$@"
}

revert() {
  toolchain user revert "$@"
}

# probe [NAME=value...]: the probe is read-only, so every start of it must leave the fake
# home as it was
probe() {
  toolchain user probe "$@" || return 1
  unchanged
}

# status_is <n>
status_is() {
  [[ "$status" -eq "$1" ]] && return 0
  printf 'exit status %s, expected %s\nstdout: %s\nstderr: %s\n' \
    "$status" "$1" "$output" "$stderr" >&2
  return 1
}

# stdout_is <line>...: stdout holds exactly these lines, in any order
stdout_is() {
  local want got
  want="$(printf '%s\n' "$@" | LC_ALL=C sort)"
  got="$(printf '%s\n' "$output" | LC_ALL=C sort)"
  [[ "$got" == "$want" ]] && return 0
  printf 'stdout:\n%s\nexpected, in any order:\n%s\nstderr: %s\n' \
    "$output" "$(printf '%s\n' "$@")" "$stderr" >&2
  return 1
}

# named <text>: a line of stderr starts with "pc-oc: toolchain: " and holds <text>
named() {
  local line
  for line in "${stderr_lines[@]}"; do
    [[ "$line" != "pc-oc: toolchain: "*"$1"* ]] || return 0
  done
  printf 'no "pc-oc: toolchain: " line of stderr names %s\nstderr: %s\n' "$1" "$stderr" >&2
  return 1
}

# refused [text]...: exit 1, nothing on stdout, stderr is the one line
# "pc-oc: toolchain: <reason>" and the reason holds every <text>; nothing in the fake home
# was created, changed or removed
refused() {
  local text
  status_is 1 || return 1
  if [[ -n "$output" ]]; then
    printf 'a refusal prints nothing on stdout, got: %s\n' "$output" >&2
    return 1
  fi
  if [[ "${#stderr_lines[@]}" -ne 1 || "$stderr" != "pc-oc: toolchain: "* ]]; then
    printf 'stderr is not the one line "pc-oc: toolchain: <reason>": %s\n' "$stderr" >&2
    return 1
  fi
  for text in "$@"; do
    named "$text" || return 1
  done
  unchanged
}

# home_holds [path]...: the entries below the fake home are exactly these
home_holds() {
  local want got
  want="$(printf '%s\n' "$@" | LC_ALL=C sort)"
  got="$(cd "$H" && find . -mindepth 1 -printf '%P\n' | LC_ALL=C sort)"
  [[ "$got" == "$want" ]] && return 0
  printf 'the fake home holds:\n%s\nexpected:\n%s\n' "$got" "$want" >&2
  return 1
}

# probe_says <key> <value>: the probe printed toolchain.<key>=<value>, and that key once
probe_says() {
  local n
  n="$(grep -c -- "^toolchain\.$1=" <<<"$output" || true)"
  if [[ "$n" -eq 1 ]] && grep -qxF -- "toolchain.$1=$2" <<<"$output"; then
    return 0
  fi
  printf 'expected one line toolchain.%s=%s\nstdout: %s\nstderr: %s\n' \
    "$1" "$2" "$output" "$stderr" >&2
  return 1
}
