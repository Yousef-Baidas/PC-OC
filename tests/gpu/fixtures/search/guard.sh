#!/usr/bin/env bash
set -euo pipefail
# Runs first inside the private mount namespace the #135 tests open with unshare(1) (see
# in_ns in helper.bash). gpu/search.sh runs as root with PATH=/usr/bin and calls its tools
# by absolute path, so each stand-in is bound where the script looks:
#   every mock in $GUARD_MOCKS over /usr/bin/<name> (python3, the helper's interpreter,
#   setpriv, getent, nvidia-smi, systemctl, sleep, sudo);
#   $GUARD_VARLIB over /var/lib, so /var/lib/pc-oc is a scratch state directory and
#   /var/lib/pc-oc-test-mock is where the mocks record, whatever environment they get;
#   $GUARD_PASSWD over /etc/passwd (the calling user is uid 4242, gid 4343 on any machine);
#   $GUARD_BOOT_ID over /proc/sys/kernel/random/boot_id.
# It then writes its pid to /var/lib/pc-oc-test-mock/search.pid and execs its arguments,
# so that pid is the search and the mock load can signal it. Exit 97 = a bind is missing
# or the uid is not the one the test asked for; nothing has run then.
# Env: GUARD_MOCKS, GUARD_VARLIB, GUARD_PASSWD, GUARD_BOOT_ID, GUARD_AS (user|root).

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

mount --bind "$GUARD_VARLIB" /var/lib || fail "cannot bind $GUARD_VARLIB over /var/lib"
[[ -e /var/lib/pc-oc-test-mock/scratch ]] || fail "/var/lib is not the test scratch"

mount --bind "$GUARD_PASSWD" /etc/passwd || fail "cannot bind $GUARD_PASSWD over /etc/passwd"
grep -qxF 'pc-oc-caller:x:4242:4343::/home/pc-oc-caller:/usr/bin/bash' /etc/passwd ||
  fail "/etc/passwd is not the fixture"

boot=/proc/sys/kernel/random/boot_id
mount --bind "$GUARD_BOOT_ID" "$boot" || fail "cannot bind $GUARD_BOOT_ID over $boot"
[[ "$(<"$boot")" == "$(<"$GUARD_BOOT_ID")" ]] || fail "$boot is not the fixture"

uid="$(/usr/bin/id -u)"
case "$GUARD_AS" in
  user) [[ "$uid" != 0 ]] || fail "uid is 0, the case wants the caller's uid" ;;
  root) [[ "$uid" == 0 ]] || fail "uid is $uid, the case wants uid 0" ;;
  *) fail "GUARD_AS must be user or root" ;;
esac

printf '%s\n' "$$" >/var/lib/pc-oc-test-mock/search.pid
exec "$@"
