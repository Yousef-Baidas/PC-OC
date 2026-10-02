#!/usr/bin/env bash
set -euo pipefail
# Runs first inside the private mount namespace the #134 tests open with unshare(1) (see
# in_ns in helper.bash): binds every mock in $GUARD_MOCKS over /usr/bin/<name>, then execs
# its arguments. A script that pins PATH=/usr/bin or calls a tool by absolute path
# therefore still reaches the mock and never the real curl, make, nvidia-smi, journalctl,
# timeout or memtest_vulkan. Exit 97 = a bind is missing or the uid is not the one the
# test asked for; nothing has run then.
# Env: GUARD_MOCKS (dir of mocks), GUARD_AS (user|root), GUARD_ICD (optional: dir bound
# over /usr/share/vulkan/icd.d; it holds the marker file .pc-oc-test-mock).

fail() {
  printf 'guard: %s\n' "$1" >&2
  exit 97
}

for mock in "$GUARD_MOCKS"/*; do
  target="/usr/bin/${mock##*/}"
  [[ -e "$target" ]] || fail "$target is not on this host, nothing to bind the mock over"
  mount --bind "$mock" "$target" || fail "cannot bind $mock over $target"
  [[ "$(sed -n 2p "$target")" == "# pc-oc-test-mock" ]] || fail "$target is not the mock"
done

if [[ -n "${GUARD_ICD:-}" ]]; then
  icd=/usr/share/vulkan/icd.d
  [[ -d "$icd" ]] || fail "$icd is not on this host, nothing to bind the fixture over"
  mount --bind "$GUARD_ICD" "$icd" || fail "cannot bind $GUARD_ICD over $icd"
  [[ -e "$icd/.pc-oc-test-mock" ]] || fail "$icd is not the fixture"
fi

uid="$(/usr/bin/id -u)"
case "$GUARD_AS" in
  user) [[ "$uid" != 0 ]] || fail "uid is 0, the case wants the caller's uid" ;;
  root) [[ "$uid" == 0 ]] || fail "uid is $uid, the case wants uid 0" ;;
  *) fail "GUARD_AS must be user or root" ;;
esac

exec "$@"
