#!/usr/bin/env bash
set -euo pipefail
# Runs first inside the private mount namespace the #127 tests open with unshare(1) (see
# in_ns and in_ns_root in helper.bash): binds every mock in $GUARD_MOCKS over
# /usr/bin/<name>, then execs its arguments. A script that pins PATH=/usr/bin or calls a
# tool by absolute path therefore still reaches the mock and never the real nvidia-smi,
# systemctl or python3 (docs/lessons/pc-oc-non-root-reaches-real-systemctl.md).
# As root it also binds $GUARD_VARLIB over /var/lib, where root's state dir is.
# The command starts with TERM, HUP and INT at their default action: a shell cannot trap
# a signal it inherited as ignored, and the signal cases must not depend on how bats was
# started.
# Exit 97 = a bind is missing or the uid is not the one the test asked for; nothing has
# run then.
# Env: GUARD_MOCKS (dir of mocks), GUARD_AS (user|root), GUARD_VARLIB (root only: a dir
# holding the marker file .pc-oc-test-mock).

fail() {
  printf 'guard: %s\n' "$1" >&2
  exit 97
}

for name in nvidia-smi systemctl python3; do
  [[ -e "$GUARD_MOCKS/$name" ]] || fail "no mock for $name in $GUARD_MOCKS"
done
for mock in "$GUARD_MOCKS"/*; do
  target="/usr/bin/${mock##*/}"
  [[ -e "$target" ]] || fail "$target is not on this host, nothing to bind the mock over"
  mount --bind "$mock" "$target" || fail "cannot bind $mock over $target"
  cmp -s "$mock" "$target" || fail "$target is not the mock"
done

uid="$(/usr/bin/id -u)"
case "$GUARD_AS" in
  user) [[ "$uid" != 0 ]] || fail "uid is 0, the case wants the caller's uid" ;;
  root)
    [[ "$uid" == 0 ]] || fail "uid is $uid, the case wants uid 0"
    mount --bind "$GUARD_VARLIB" /var/lib || fail "cannot bind $GUARD_VARLIB over /var/lib"
    [[ -e /var/lib/.pc-oc-test-mock ]] || fail "/var/lib is not the scratch dir"
    ;;
  *) fail "GUARD_AS must be user or root" ;;
esac

exec /usr/bin/env --default-signal=TERM,HUP,INT "$@"
