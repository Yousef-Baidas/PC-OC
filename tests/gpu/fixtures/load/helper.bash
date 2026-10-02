# shellcheck shell=bash disable=SC2154 # lines is set by bats run
# Shared helpers for the #134 contract: tests/gpu/burn-build.bats and tests/gpu/load.bats.

# The fake commit in the test pin. It is not a gpu-burn commit, so even a real curl could
# not fetch the real tarball with it.
VERSION=0123456789abcdef0123456789abcdef01234567

# common_setup: fake repo (lib/ and the gpu scripts under test), fake HOME, mock state dir,
# and the directory of mocks that is first on PATH and bound over /usr/bin by guard.sh.
common_setup() {
  unset "${!GIT_@}"
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  FIX="$BATS_TEST_DIRNAME/fixtures/load"
  REPO="$BATS_TEST_TMPDIR/repo"
  export HOME="$BATS_TEST_TMPDIR/home"
  export TMPDIR="$BATS_TEST_TMPDIR/tmp"
  export MOCK_STATE="$BATS_TEST_TMPDIR/state"
  export GUARD_MOCKS="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$REPO/gpu" "$HOME" "$TMPDIR" "$MOCK_STATE" "$GUARD_MOCKS"
  cp -r "$ROOT/lib" "$REPO/lib"
  # absent until #134 lands: every case is red then, setup is not
  cp "$ROOT/gpu/burn-build.sh" "$ROOT/gpu/load.sh" "$REPO/gpu/" 2>/dev/null || true
  export PATH="$GUARD_MOCKS:$PATH"
}

# use_mocks <name>...: put these mocks first on PATH and on guard.sh's bind list
use_mocks() {
  local name
  for name in "$@"; do
    cp "$FIX/mocks/$name" "$GUARD_MOCKS/$name"
  done
}

# write_pin <sha256> [url]: the test pin, where the scripts read it (next to themselves)
write_pin() {
  local url="${2:-https://github.com/wilicc/gpu-burn/archive/$VERSION.tar.gz}"
  printf 'version=%s\nurl=%s\nsha256=%s\nsource=gpu-burn\n' "$VERSION" "$url" "$1" \
    >"$REPO/gpu/burn.pin"
}

# in_ns <user|root> <command...>: run the command in a private mount namespace with the
# mocks bound over /usr/bin (guard.sh). "user" keeps the caller's uid; "root" is
# unshare -r, where /usr/bin/id -u prints 0, which is how the uid 0 refusals are reached
# without sudo.
in_ns() {
  local who="$1"
  shift
  local -a map=(--map-user="$(id -u)" --map-group="$(id -g)" --keep-caps)
  [[ "$who" == user ]] || map=(-r)
  GUARD_AS="$who" unshare "${map[@]}" -m bash "$FIX/guard.sh" "$@"
}

# value <key>: print the value of the one stdout line <key>=; fails on none or several
value() {
  local l v="" n=0
  for l in "${lines[@]}"; do
    [[ "$l" == "$1="* ]] || continue
    v="${l#"$1="}"
    n=$((n + 1))
  done
  if ((n != 1)); then
    echo "key $1: $n lines" >&2
    return 1
  fi
  printf '%s\n' "$v"
}

# status_is <n>: the last run exited <n>; on a mismatch show what it printed
status_is() {
  [[ "$status" -eq "$1" ]] || {
    printf 'status %s, want %s\nstdout:\n%s\nstderr:\n%s\n' "$status" "$1" "$output" "${stderr:-}" >&2
    return 1
  }
}

# block_ok [count]: every stdout line is in the result-block grammar and there is at
# least one; with <count>, there are exactly that many
block_ok() {
  local l
  [[ -n "$output" && "$output" != *$'\n\n'* ]] || return 1
  for l in "${lines[@]}"; do
    [[ "$l" =~ ^[a-z_]+=[A-Za-z0-9._/-]*$ ]] || {
      echo "not a result line: $l" >&2
      return 1
    }
  done
  [[ -z "${1:-}" ]] || ((${#lines[@]} == $1)) || {
    echo "${#lines[@]} lines, want $1" >&2
    return 1
  }
}

# no_tool_ran: no mock recorded a call
no_tool_ran() {
  [[ -z "$(ls -A "$MOCK_STATE")" ]] || {
    echo "mocks ran: $(ls -A "$MOCK_STATE")" >&2
    return 1
  }
}
