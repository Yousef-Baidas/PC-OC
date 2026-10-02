#!/usr/bin/env bash
set -euo pipefail
# Runs first inside the private mount namespace the #119 tests open with unshare(1) (see
# in_ns in helper.bash). toolchain/apply.sh and probe.sh ask whether /usr/bin/sccache,
# /usr/bin/mold, /usr/bin/cmake and /usr/lib/sccache/bin/cc exist, and a test has to decide
# that without installing or removing anything on the PC. Only binds, nothing is deleted:
#   the real /usr is bound at $GUARD_HOLD, so every real tool stays reachable there;
#   $GUARD_BIN is bound over /usr/bin: one link to $GUARD_HOLD/bin/<name> for every name of
#   the real /usr/bin except sccache, mold and cmake, which are there only as the mocks the
#   test put in;
#   $GUARD_SCCACHE_BIN is bound over /usr/lib/sccache/bin: cc is there only as a mock;
#   $GUARD_PASSWD is bound over /etc/passwd: every home in it is $GUARD_PASSWD_HOME, a
#   directory of the test. Without HOME in the environment bash expands ~ from passwd (and
#   a login shell takes HOME itself from there), so without this bind a script started
#   without HOME could still reach the real home.
# Then it execs its arguments: as uid 0 for "root" (unshare -r), and for "user" as the
# caller's uid with no capability left, so a directory without write permission refuses
# the script as it would refuse the user's shell.
# Exit 97 = a bind is missing, a tool is neither absent nor a mock, or the uid is not the
# one the test asked for; nothing has run then.
# Env: GUARD_HOLD, GUARD_BIN, GUARD_SCCACHE_BIN, GUARD_PASSWD, GUARD_PASSWD_HOME,
# GUARD_AS (user|root).

fail() {
  printf 'guard: %s\n' "$1" >&2
  exit 97
}

lib=/usr/lib/sccache/bin
[[ -d "$lib" ]] || fail "$lib is not on this host, nothing to bind the test's directory over"

mount --bind /usr "$GUARD_HOLD" || fail "cannot bind /usr over $GUARD_HOLD"
mount --bind "$GUARD_BIN" /usr/bin || fail "cannot bind $GUARD_BIN over /usr/bin"
[[ /usr/bin -ef "$GUARD_BIN" ]] || fail "/usr/bin is not the test's directory"
[[ -x /usr/bin/bash && -x /usr/bin/id ]] || fail "the real tools are not behind /usr/bin"

mount --bind "$GUARD_SCCACHE_BIN" "$lib" || fail "cannot bind $GUARD_SCCACHE_BIN over $lib"
[[ "$lib" -ef "$GUARD_SCCACHE_BIN" ]] || fail "$lib is not the test's directory"

for tool in /usr/bin/sccache /usr/bin/mold /usr/bin/cmake "$lib/cc"; do
  [[ -e "$tool" || -L "$tool" ]] || continue
  [[ -f "$tool" && ! -L "$tool" && "$(sed -n 2p "$tool")" == "# pc-oc-test-mock" ]] ||
    fail "$tool is not a mock"
done

mount --bind "$GUARD_PASSWD" /etc/passwd || fail "cannot bind $GUARD_PASSWD over /etc/passwd"
home="$(/usr/bin/env -i /usr/bin/bash -c 'printf %s ~')"
[[ "$home" == "$GUARD_PASSWD_HOME" ]] ||
  fail "without HOME ~ is $home, not the test's directory"

uid="$(/usr/bin/id -u)"
case "$GUARD_AS" in
  user)
    [[ "$uid" != 0 ]] || fail "uid is 0, the case wants the caller's uid"
    exec /usr/bin/setpriv --inh-caps=-all --ambient-caps=-all "$@"
    ;;
  root)
    [[ "$uid" == 0 ]] || fail "uid is $uid, the case wants uid 0"
    exec "$@"
    ;;
  *) fail "GUARD_AS must be user or root" ;;
esac
