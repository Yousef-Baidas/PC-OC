#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031 # bats `run` sets status/output/stderr in the test shell; shellcheck reads each @test as a subshell

bats_require_minimum_version 1.5.0

# Contract #26: pc-oc root hardening. The rest of pc-oc is covered in tests/lib/pc-oc.bats.
# EUID 0 seam: `unshare -r` runs pc-oc as uid 0 in a user namespace, never real root.
# Contract #56 (incident run log #1): root-path cases go through as_root, which runs under `unshare -rm`
# with mocks bind-mounted over /usr/bin/systemctl and /usr/bin/nvidia-smi and scratch over /var/lib,
# and aborts (97) unless the mocks are in place. pc-oc pins PATH=/usr/bin, so only a mount keeps
# the real tools out of reach.
# Contract #117: as root, toolchain scripts are run through /usr/bin/setpriv as the calling user. In the
# namespace setpriv is a mock that records its argument vector and then runs what follows the three
# setpriv options, and /etc/passwd is a fixture, so the caller is uid 4242, gid 4343, home
# /home/pc-oc-caller on any machine. Only uid 0 is mapped there, so the real setpriv could not drop.
# Contract #126: the search verb (search gpu only, as root, never dropped) and Amendment 1 (apply all
# checks the calling user before the first component). A non-root search case runs in a tree of fakes only.

setup_file() {
  local f="$BATS_TEST_DIRNAME/../../pc-oc"
  f="$(cd "$(dirname "$f")" && pwd)/pc-oc"
  printf '# opened %s sha256=%s, 1 file\n' "$f" "$(sha256sum <"$f" | cut -d' ' -f1)" >&3
}

# Each test runs a copy of pc-oc and lib/ so fake component folders stay out of the repo.
setup() {
  root="$BATS_TEST_TMPDIR/root"
  mkdir -p "$root"
  cp "$BATS_TEST_DIRNAME/../../pc-oc" "$root/"
  cp -r "$BATS_TEST_DIRNAME/../../lib" "$root/"
  export SYSFS_ROOT="$BATS_TEST_TMPDIR/sys" PC_OC_STATE="$BATS_TEST_TMPDIR/state"
  unset GIT_DIR GIT_WORK_TREE
  calls="$BATS_TEST_TMPDIR/calls"
  export CALLS="$calls" MOCK_LOG="$BATS_TEST_TMPDIR/mock.log"
  mkdir -p "$BATS_TEST_TMPDIR/mocks" "$BATS_TEST_TMPDIR/varlib"
  local m
  for m in systemctl nvidia-smi; do
    # shellcheck disable=SC2016 # $* and $MOCK_LOG expand when the mock runs, not here
    printf '#!/usr/bin/bash\n# pc-oc-test-mock\necho "%s $*" >>"$MOCK_LOG"\n' "$m" >"$BATS_TEST_TMPDIR/mocks/$m"
    chmod +x "$BATS_TEST_TMPDIR/mocks/$m"
  done
  echo pc-oc-test-scratch >"$BATS_TEST_TMPDIR/varlib/marker"
  # the log path is written into the mock: it must record even if pc-oc clears its environment
  setpriv_log="$BATS_TEST_TMPDIR/setpriv.log"
  cat >"$BATS_TEST_TMPDIR/mocks/setpriv" <<EOF
#!/usr/bin/bash
# pc-oc-test-mock
{
  printf '%s\n' "\$@"
  echo argv-end
} >>"$setpriv_log"
[[ "\$1" == --reuid=* && "\$2" == --regid=* && "\$3" == --clear-groups ]] || exit 96
shift 3
exec "\$@"
EOF
  chmod +x "$BATS_TEST_TMPDIR/mocks/setpriv"
  caller_passwd='pc-oc-caller:x:4242:4343::/home/pc-oc-caller:/usr/bin/bash'
  # a user named 12x has a home, so only the digit check stops SUDO_UID=12x; the lookup would not
  printf '%s\n' 'root:x:0:0::/root:/usr/bin/bash' "$caller_passwd" \
    '12x:x:4244:4343::/home/pc-oc-12x:/usr/bin/bash' >"$BATS_TEST_TMPDIR/passwd"
  export SUDO_UID=4242 SUDO_GID=4343
  cat >"$BATS_TEST_TMPDIR/guard.sh" <<EOF
#!/usr/bin/bash
mount --bind "$BATS_TEST_TMPDIR/mocks/systemctl" /usr/bin/systemctl || exit 97
mount --bind "$BATS_TEST_TMPDIR/mocks/nvidia-smi" /usr/bin/nvidia-smi || exit 97
mount --bind "$BATS_TEST_TMPDIR/mocks/setpriv" /usr/bin/setpriv || exit 97
mount --bind "$BATS_TEST_TMPDIR/varlib" /var/lib || exit 97
mount --bind "$BATS_TEST_TMPDIR/passwd" /etc/passwd || exit 97
[[ "\$(sed -n 2p /usr/bin/systemctl)" == "# pc-oc-test-mock" ]] || exit 97
[[ "\$(sed -n 2p /usr/bin/nvidia-smi)" == "# pc-oc-test-mock" ]] || exit 97
[[ "\$(sed -n 2p /usr/bin/setpriv)" == "# pc-oc-test-mock" ]] || exit 97
[[ "\$(cat /var/lib/marker)" == pc-oc-test-scratch ]] || exit 97
[[ "\$(/usr/bin/getent passwd 4242)" == "$caller_passwd" ]] || exit 97
exec "\$@"
EOF
}

# as_root <cmd...>: EUID 0 in a namespace where the system tools are mocks; never real root
as_root() {
  unshare -rm bash "$BATS_TEST_TMPDIR/guard.sh" "$@"
}

# fake_logger <component> <verb>: logs every call to $calls; running it at all is the failure
fake_logger() {
  mkdir -p "$root/$1"
  cat >"$root/$1/$2.sh" <<'EOF'
#!/usr/bin/env bash
echo "ran $(basename "$(dirname "${BASH_SOURCE[0]}")") $(basename "${BASH_SOURCE[0]}")" >>"$CALLS"
exit 0
EOF
}

# every component has a logging fake for both verbs, so a pc-oc that skips the refusal runs only fakes
fake_all_loggers() {
  local c
  for c in cpu ram gpu os toolchain; do
    fake_logger "$c" apply
    fake_logger "$c" revert
  done
}

# fake_component <component> <verb> [exit status]
fake_component() {
  mkdir -p "$root/$1"
  cat >"$root/$1/$2.sh" <<EOF
#!/usr/bin/env bash
echo "$2 $1 SYSFS_ROOT=\${SYSFS_ROOT-unset} PC_OC_STATE=\${PC_OC_STATE-unset}"
exit ${3:-0}
EOF
}

@test "as EUID 0 pc-oc unsets SYSFS_ROOT and PC_OC_STATE before running a component" {
  fake_component cpu probe
  run --separate-stderr "$root/pc-oc" probe cpu
  [ "$status" -eq 0 ]
  [ "$output" = "probe cpu SYSFS_ROOT=$SYSFS_ROOT PC_OC_STATE=$PC_OC_STATE" ]
  run --separate-stderr as_root "$root/pc-oc" probe cpu
  [ "$status" -eq 0 ]
  [ "$output" = "probe cpu SYSFS_ROOT=unset PC_OC_STATE=unset" ]
}

@test "revert all runs every component in reverse order past a failure, then exits 1 naming it" {
  for c in cpu ram os toolchain; do
    fake_component "$c" revert
  done
  fake_component gpu revert 3
  run --separate-stderr as_root "$root/pc-oc" revert all
  [ "$status" -eq 1 ]
  [ "${#lines[@]}" -eq 5 ]
  [[ "${lines[0]}" == "revert toolchain "* ]]
  [[ "${lines[1]}" == "revert os "* ]]
  [[ "${lines[2]}" == "revert gpu "* ]]
  [[ "${lines[3]}" == "revert ram "* ]]
  [[ "${lines[4]}" == "revert cpu "* ]]
  [[ "${stderr_lines[-1]}" == "pc-oc: "*gpu* ]]
}

# Contract #48: os at stock must not fail revert all. cpu is the one applied component; the real
# os/revert.sh runs against an empty state dir, the rest are fakes that exit 0.
@test "revert all with one component applied and os at stock exits 0 and runs every revert" {
  for c in cpu ram gpu toolchain; do
    fake_component "$c" revert
  done
  mkdir -p "$root/os"
  cp "$BATS_TEST_DIRNAME/../../os/revert.sh" "$root/os/"
  echo "real os/revert.sh, $(wc -c <"$root/os/revert.sh") bytes, empty state $PC_OC_STATE" >&3
  run --separate-stderr as_root "$root/pc-oc" revert all
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 4 ]
  [[ "${lines[0]}" == "revert toolchain "* ]]
  [[ "${lines[1]}" == "revert gpu "* ]]
  [[ "${lines[2]}" == "revert ram "* ]]
  [[ "${lines[3]}" == "revert cpu "* ]]
  [ "$stderr" = "pc-oc: os: nothing to revert" ]
}

@test "as EUID 0 apply os runs the component and the mocks stay unused" {
  fake_component os apply
  run --separate-stderr as_root "$root/pc-oc" apply os
  [ "$status" -eq 0 ]
  [ "$output" = "apply os SYSFS_ROOT=unset PC_OC_STATE=unset" ]
  [ ! -e "$MOCK_LOG" ]
}

@test "the as_root guard aborts 97 when a mock is not the mock" {
  : >"$BATS_TEST_TMPDIR/mocks/systemctl"
  local rc=0
  as_root true || rc=$?
  [ "$rc" -eq 97 ]
}

# Contract #56: non-root apply/revert refuse before any component script runs.
refused() { # refused <verb> <target>
  fake_all_loggers
  run --separate-stderr "$root/pc-oc" "$1" "$2"
  [ "$status" -eq 1 ] || {
    echo "non-root $1 $2 exited $status, want 1" >&3
    return 1
  }
  [ "$stderr" = "pc-oc: $1 needs root: sudo $root/pc-oc $1 $2" ] || {
    echo "non-root $1 $2 stderr was '$stderr'" >&3
    return 1
  }
  [ -z "$output" ] || {
    echo "non-root $1 $2 wrote stdout '$output'" >&3
    return 1
  }
  [ ! -e "$calls" ] || {
    echo "non-root $1 $2 ran components: $(tr '\n' ';' <"$calls")" >&3
    return 1
  }
}

@test "non-root pc-oc apply os refuses with the sudo hint and runs no component" {
  refused apply os
}

@test "non-root pc-oc revert gpu refuses with the sudo hint and runs no component" {
  refused revert gpu
}

@test "non-root pc-oc revert all refuses with the sudo hint and runs no component" {
  refused revert all
}

@test "non-root pc-oc apply all refuses with the sudo hint and runs no component" {
  refused apply all
}

# Contract #56 amendment: the uid comes from the kernel, never from an EUID the caller put in the environment.
# Safety: these run pc-oc at the caller's uid with a forged EUID, the bypass that reaches real tools when pc-oc
# is broken; so every component script in the scratch tree must be a logging fake before pc-oc starts.
assert_only_fakes() {
  local f n=0
  for f in "$root"/{cpu,ram,gpu,os,toolchain}/{apply,revert}.sh; do
    # shellcheck disable=SC2016 # matching the literal text $CALLS in the fake
    grep -q '>>"\$CALLS"' "$f" || {
      echo "not a fake: $f" >&3
      return 97
    }
    n=$((n + 1))
  done
  [ "$n" -eq 10 ] || {
    echo "want 10 fakes in $root, found $n" >&3
    return 97
  }
}

refused_env_euid() { # refused_env_euid <EUID value> <verb> <target>
  fake_all_loggers
  assert_only_fakes
  run --separate-stderr env EUID="$1" "$root/pc-oc" "$2" "$3"
  [ "$status" -eq 1 ] || {
    echo "non-root env EUID=$1 $2 $3 exited $status, want 1" >&3
    return 1
  }
  [ "$stderr" = "pc-oc: $2 needs root: sudo $root/pc-oc $2 $3" ] || {
    echo "non-root env EUID=$1 $2 $3 stderr was '$stderr'" >&3
    return 1
  }
  [ -z "$output" ] || {
    echo "non-root env EUID=$1 $2 $3 wrote stdout '$output'" >&3
    return 1
  }
  [ ! -e "$calls" ] || {
    echo "non-root env EUID=$1 $2 $3 ran components: $(tr '\n' ';' <"$calls")" >&3
    return 1
  }
}

@test "non-root env EUID=0 pc-oc apply os and revert all still refuse and run no component" {
  refused_env_euid 0 apply os
  refused_env_euid 0 revert all
}

@test "as_root env EUID=1000 pc-oc apply os still runs with SYSFS_ROOT and PC_OC_STATE unset" {
  fake_component os apply
  run --separate-stderr as_root env EUID=1000 "$root/pc-oc" apply os
  [ "$status" -eq 0 ] || {
    echo "root with env EUID=1000 exited $status; stderr '$stderr'" >&3
    return 1
  }
  [ "$output" = "apply os SYSFS_ROOT=unset PC_OC_STATE=unset" ]
  [ ! -e "$MOCK_LOG" ]
}

@test "non-root env EUID with a command substitution refuses and never evaluates it" {
  local marker="$BATS_TEST_TMPDIR/eval-marker"
  refused_env_euid "a[\$(touch $marker)]" apply os
  [ ! -e "$marker" ] || {
    echo "pc-oc evaluated the env EUID: $marker exists" >&3
    return 1
  }
}

@test "non-root pc-oc probe all still runs every component" {
  local c
  for c in cpu ram gpu os toolchain; do
    fake_component "$c" probe
  done
  run --separate-stderr "$root/pc-oc" probe all
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 5 ]
  [[ "${lines[0]}" == "probe cpu "* ]]
  [[ "${lines[4]}" == "probe toolchain "* ]]
}

# Contract #117: toolchain scripts run as the calling user.
# fake_recorder <component> <verb>: one line per run in $calls with the uid and environment it saw.
# The log path is written into the script: under `env -i` no CALLS variable reaches it.
fake_recorder() {
  mkdir -p "$root/$1"
  cat >"$root/$1/$2.sh" <<EOF
#!/usr/bin/env bash
echo "ran $1 $2 uid=\$(/usr/bin/id -u) HOME=\${HOME-unset} CALLER_MARK=\${CALLER_MARK-unset}" \\
  "XDG_CONFIG_HOME=\${XDG_CONFIG_HOME-unset} CARGO_HOME=\${CARGO_HOME-unset}" \\
  "SYSFS_ROOT=\${SYSFS_ROOT-unset} PC_OC_STATE=\${PC_OC_STATE-unset}" >>"$calls"
EOF
}

# what a script run through the drop sees: the passwd home and nothing of the caller's
dropped_env="HOME=/home/pc-oc-caller CALLER_MARK=unset XDG_CONFIG_HOME=unset CARGO_HOME=unset SYSFS_ROOT=unset PC_OC_STATE=unset"

# one_drop <verb>: setpriv ran exactly once, with the contract's argument vector for toolchain/<verb>.sh
one_drop() {
  printf '%s\n' --reuid=4242 --regid=4343 --clear-groups /usr/bin/env -i HOME=/home/pc-oc-caller \
    PATH=/usr/bin /usr/bin/bash "$root/toolchain/$1.sh" argv-end >"$BATS_TEST_TMPDIR/want-argv"
  [ -e "$setpriv_log" ] || {
    echo "setpriv never ran: toolchain/$1.sh was not dropped" >&3
    return 1
  }
  diff "$BATS_TEST_TMPDIR/want-argv" "$setpriv_log" >&3
}

@test "non-root pc-oc apply toolchain runs toolchain/apply.sh once, as the caller" {
  fake_all_loggers
  fake_recorder toolchain apply
  run --separate-stderr env HOME="$BATS_TEST_TMPDIR/home" "$root/pc-oc" apply toolchain
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$calls")" -eq 1 ]
  [[ "$(<"$calls")" == "ran toolchain apply uid=$(id -u) HOME=$BATS_TEST_TMPDIR/home "* ]]
}

# apply all is the #56 case above; with toolchain let through, the other components must still refuse
@test "non-root pc-oc apply gpu refuses with the sudo hint and runs no component" {
  refused apply gpu
}

# needs_caller <env arguments...>: as uid 0 with that environment, apply toolchain dies with the
# contract's line and neither the script nor setpriv runs
needs_caller() {
  fake_all_loggers
  fake_recorder toolchain apply
  run --separate-stderr as_root env "$@" "$root/pc-oc" apply toolchain
  [ "$status" -eq 1 ] || {
    echo "root env $* apply toolchain exited $status, want 1; stderr '$stderr'" >&3
    return 1
  }
  [ "$stderr" = "pc-oc: toolchain: needs the calling user: run it without sudo, or through sudo from your own account" ] || {
    echo "root env $* apply toolchain stderr was '$stderr'" >&3
    return 1
  }
  [ ! -e "$calls" ] || {
    echo "root env $* apply toolchain ran: $(tr '\n' ';' <"$calls")" >&3
    return 1
  }
  [ ! -e "$setpriv_log" ] || {
    echo "root env $* apply toolchain called setpriv: $(tr '\n' ' ' <"$setpriv_log")" >&3
    return 1
  }
}

@test "as EUID 0 with SUDO_UID unset apply toolchain dies needing the calling user and runs nothing" {
  needs_caller -u SUDO_UID
}

@test "as EUID 0 with SUDO_UID=0 apply toolchain dies needing the calling user and runs nothing" {
  needs_caller SUDO_UID=0
}

@test "as EUID 0 with SUDO_UID=12x apply toolchain dies needing the calling user and runs nothing" {
  needs_caller SUDO_UID=12x
}

@test "as EUID 0 with SUDO_GID unset apply toolchain dies needing the calling user and runs nothing" {
  needs_caller -u SUDO_GID
}

@test "as EUID 0 apply toolchain calls setpriv with exactly the contract's argument vector and a clean environment" {
  fake_all_loggers
  fake_recorder toolchain apply
  run --separate-stderr as_root env HOME="$BATS_TEST_TMPDIR/home" CALLER_MARK=set \
    XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/xdg" CARGO_HOME="$BATS_TEST_TMPDIR/cargo" \
    SYSFS_ROOT="$SYSFS_ROOT" PC_OC_STATE="$PC_OC_STATE" "$root/pc-oc" apply toolchain
  [ "$status" -eq 0 ]
  one_drop apply
  run grep -cE 'XDG_CONFIG_HOME|CARGO_HOME|SYSFS_ROOT|PC_OC_STATE|CALLER_MARK' "$setpriv_log"
  [ "$output" = 0 ]
  [ "$(wc -l <"$calls")" -eq 1 ]
  [[ "$(<"$calls")" == "ran toolchain apply uid="*" $dropped_env" ]]
}

@test "as EUID 0 with SUDO_UID unset revert all still runs gpu's revert, exits 1 and names toolchain" {
  fake_recorder gpu revert
  fake_recorder toolchain revert
  run --separate-stderr as_root env -u SUDO_UID "$root/pc-oc" revert all
  [ "$status" -eq 1 ]
  [ "$(wc -l <"$calls")" -eq 1 ]
  [[ "$(<"$calls")" == "ran gpu revert uid=0 "* ]]
  [ ! -e "$setpriv_log" ]
  [[ "$stderr" == *"pc-oc: toolchain: needs the calling user: "* ]]
  [ "${stderr_lines[-1]}" = "pc-oc: all: revert.sh failed: toolchain" ]
}

@test "as EUID 0 probe all drops for the toolchain probe only; the other probes run as root as today" {
  local c
  for c in cpu ram gpu os toolchain; do
    fake_recorder "$c" probe
  done
  run --separate-stderr as_root env HOME="$BATS_TEST_TMPDIR/home" CALLER_MARK=set \
    XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/xdg" CARGO_HOME="$BATS_TEST_TMPDIR/cargo" "$root/pc-oc" probe all
  [ "$status" -eq 0 ]
  one_drop probe
  mapfile -t ran <"$calls"
  [ "${#ran[@]}" -eq 5 ]
  # as today: the caller's environment passes through, minus the two test seams pc-oc unsets as root
  local i=0 as_today="HOME=$BATS_TEST_TMPDIR/home CALLER_MARK=set XDG_CONFIG_HOME=$BATS_TEST_TMPDIR/xdg"
  as_today+=" CARGO_HOME=$BATS_TEST_TMPDIR/cargo SYSFS_ROOT=unset PC_OC_STATE=unset"
  for c in cpu ram gpu os; do
    [ "${ran[i]}" = "ran $c probe uid=0 $as_today" ] || {
      echo "probe $c ran as '${ran[i]}'" >&3
      return 1
    }
    i=$((i + 1))
  done
  [[ "${ran[4]}" == "ran toolchain probe uid="*" $dropped_env" ]]
}

# Interface rules of #117 that its Check list does not name.
@test "as EUID 0 with SUDO_GID=12x apply toolchain dies needing the calling user and runs nothing" {
  needs_caller SUDO_GID=12x
}

# setpriv and getent read an id modulo 2^32: 00 and 4294967296 are uid 0, whose fixture home is absolute,
# and 4294967295 is setresuid's "keep". Each would leave the script running as root.
@test "as EUID 0 with a SUDO_UID or SUDO_GID that setpriv would read as another id apply toolchain dies and runs nothing" {
  needs_caller SUDO_UID=00
  needs_caller SUDO_UID=4294967296
  needs_caller SUDO_UID=4294967295
  needs_caller SUDO_GID=4294967296
}

# In a UTF-8 locale a [0-9] range matches fullwidth digits too. The fixture has a user of that name with a
# home, so only an ASCII digit check stops it; the lookup would not.
@test "as EUID 0 with fullwidth digits in SUDO_UID apply toolchain dies needing the calling user and runs nothing" {
  locale -a | grep -qix 'en_US\.utf-\?8' || skip "no en_US.UTF-8 locale on this machine"
  printf '%s\n' '４２４２:x:4247:4343::/home/pc-oc-wide:/usr/bin/bash' >>"$BATS_TEST_TMPDIR/passwd"
  needs_caller LC_ALL=en_US.UTF-8 SUDO_UID=４２４２
}

@test "as EUID 0 with no absolute home for SUDO_UID apply toolchain dies needing the calling user and runs nothing" {
  printf '%s\n' 'pc-oc-relhome:x:4245:4343::home/pc-oc-relhome:/usr/bin/bash' \
    'pc-oc-nohome:x:4246:4343:::/usr/bin/bash' >>"$BATS_TEST_TMPDIR/passwd"
  needs_caller SUDO_UID=4245
  needs_caller SUDO_UID=4246
  # no passwd entry at all
  needs_caller SUDO_UID=4999
}

# Contract #126 Amendment 1: apply all checks the calling user before the first component, so a root
# caller without one is told so with nothing applied, instead of after cpu, ram, gpu and os.
# apply_all_needs_caller <env arguments...>: as uid 0 with that environment, apply all exits 1 with one
# line that names apply all and the calling user; no component script ran and setpriv was not called
apply_all_needs_caller() {
  local c
  for c in cpu ram gpu os toolchain; do
    fake_recorder "$c" apply
  done
  run --separate-stderr as_root env "$@" "$root/pc-oc" apply all
  [ "$status" -eq 1 ] || {
    echo "root env $* apply all exited $status, want 1; stderr '$stderr'" >&3
    return 1
  }
  [ ! -e "$calls" ] || {
    echo "root env $* apply all ran: $(tr '\n' ';' <"$calls")" >&3
    return 1
  }
  [ ! -e "$setpriv_log" ] || {
    echo "root env $* apply all called setpriv: $(tr '\n' ' ' <"$setpriv_log")" >&3
    return 1
  }
  [[ "${#stderr_lines[@]}" -eq 1 && "$stderr" == "pc-oc: "*"apply all"* && "$stderr" == *"calling user"* ]] || {
    echo "root env $* apply all stderr was '$stderr', want one pc-oc: line naming apply all and the calling user" >&3
    return 1
  }
}

@test "as EUID 0 with SUDO_UID unset apply all dies naming apply all before any component runs" {
  apply_all_needs_caller -u SUDO_UID
}

# the check is #117's whole check, not only "SUDO_UID is set"
@test "as EUID 0 with SUDO_GID unset, SUDO_UID=0 or no passwd entry apply all dies before any component runs" {
  apply_all_needs_caller -u SUDO_GID
  apply_all_needs_caller SUDO_UID=0
  apply_all_needs_caller SUDO_UID=4999
}

@test "as EUID 0 with a calling user apply all runs all five in order, toolchain through the drop" {
  local c
  for c in cpu ram gpu os toolchain; do
    fake_recorder "$c" apply
  done
  run --separate-stderr as_root env HOME="$BATS_TEST_TMPDIR/home" CALLER_MARK=set \
    XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/xdg" CARGO_HOME="$BATS_TEST_TMPDIR/cargo" "$root/pc-oc" apply all
  [ "$status" -eq 0 ] || {
    echo "root apply all with a calling user exited $status; stderr '$stderr'" >&3
    return 1
  }
  one_drop apply
  mapfile -t ran <"$calls"
  [ "${#ran[@]}" -eq 5 ]
  local i=0 as_today="HOME=$BATS_TEST_TMPDIR/home CALLER_MARK=set XDG_CONFIG_HOME=$BATS_TEST_TMPDIR/xdg"
  as_today+=" CARGO_HOME=$BATS_TEST_TMPDIR/cargo SYSFS_ROOT=unset PC_OC_STATE=unset"
  for c in cpu ram gpu os; do
    [ "${ran[i]}" = "ran $c apply uid=0 $as_today" ] || {
      echo "apply $c ran as '${ran[i]}'" >&3
      return 1
    }
    i=$((i + 1))
  done
  [[ "${ran[4]}" == "ran toolchain apply uid="*" $dropped_env" ]]
}

@test "non-root pc-oc revert toolchain and probe toolchain run the script once, as the caller, with no drop" {
  local v
  fake_all_loggers
  for v in revert probe; do
    fake_recorder toolchain "$v"
    rm -f "$calls"
    run --separate-stderr env HOME="$BATS_TEST_TMPDIR/home" "$root/pc-oc" "$v" toolchain
    [ "$status" -eq 0 ] || {
      echo "non-root $v toolchain exited $status; stderr '$stderr'" >&3
      return 1
    }
    [ "$(wc -l <"$calls")" -eq 1 ]
    [[ "$(<"$calls")" == "ran toolchain $v uid=$(id -u) HOME=$BATS_TEST_TMPDIR/home "* ]]
    [ ! -e "$setpriv_log" ]
  done
}

# Contract #126 Amendment 1: pins for the two mutants of pc-oc that survived the #117 review.
# 2^32-1 as a gid is setresgid's "keep", so the script would keep root's group. The uid line above is also
# stopped by its missing passwd entry; for the gid only the bound stops it.
@test "as EUID 0 with SUDO_GID=4294967295 apply toolchain dies needing the calling user and runs nothing" {
  needs_caller SUDO_GID=4294967295
}

# Leading zeros keep an eleven-digit id inside the range, and getent and setpriv read it as 4242 (4343),
# the fixture caller: only the ten-digit limit stops it.
@test "as EUID 0 with an eleven-digit SUDO_UID or SUDO_GID apply toolchain dies needing the calling user and runs nothing" {
  needs_caller SUDO_UID=00000004242
  needs_caller SUDO_GID=00000004343
  needs_caller SUDO_UID=10000004242
}

# Contract #126: pc-oc search gpu, the one search form. Root only and run as root (no drop), under apply's rules.
# fake_search <component> [exit status]: one line per run in $calls with the uid, PATH and test seams it saw
fake_search() {
  mkdir -p "$root/$1"
  cat >"$root/$1/search.sh" <<EOF
#!/usr/bin/env bash
echo "ran $1 search uid=\$(/usr/bin/id -u) PATH=\$PATH" \\
  "SYSFS_ROOT=\${SYSFS_ROOT-unset} PC_OC_STATE=\${PC_OC_STATE-unset}" >>"$calls"
exit ${2:-0}
EOF
}

# every component has a recording search.sh next to recording apply and revert scripts, so a pc-oc that
# takes search for another component, or runs a search.sh under all, leaves a line in $calls
fake_search_tree() {
  local c
  for c in cpu ram gpu os toolchain; do
    fake_recorder "$c" apply
    fake_recorder "$c" revert
    fake_search "$c"
  done
}

# search_usage <pc-oc arguments...>: as uid 0 they are a usage error, exit 2; no script ran, setpriv was not called
search_usage() {
  run --separate-stderr as_root "$root/pc-oc" "$@"
  [ "$status" -eq 2 ] || {
    echo "root pc-oc $* exited $status, want 2; stderr '$stderr'" >&3
    return 1
  }
  [[ "$stderr" == usage:* ]] || {
    echo "root pc-oc $* stderr was '$stderr'" >&3
    return 1
  }
  [ -z "$output" ] || {
    echo "root pc-oc $* wrote stdout '$output'" >&3
    return 1
  }
  [ ! -e "$calls" ] || {
    echo "root pc-oc $* ran: $(tr '\n' ';' <"$calls")" >&3
    return 1
  }
  [ ! -e "$setpriv_log" ] || {
    echo "root pc-oc $* called setpriv: $(tr '\n' ' ' <"$setpriv_log")" >&3
    return 1
  }
}

@test "as EUID 0 pc-oc search gpu runs gpu/search.sh once as root with PATH=/usr/bin and the test seams unset" {
  fake_search_tree
  mkdir -p "$BATS_TEST_TMPDIR/evil"
  run --separate-stderr as_root env PATH="$BATS_TEST_TMPDIR/evil:$PATH" "$root/pc-oc" search gpu
  [ "$status" -eq 0 ] || {
    echo "root search gpu exited $status; stderr '$stderr'" >&3
    return 1
  }
  [ "$(<"$calls")" = "ran gpu search uid=0 PATH=/usr/bin SYSFS_ROOT=unset PC_OC_STATE=unset" ]
  [ ! -e "$setpriv_log" ]
  [ ! -e "$MOCK_LOG" ]
}

@test "as EUID 0 pc-oc search with a target other than gpu, no target or an extra argument is a usage error and runs nothing" {
  fake_search_tree
  search_usage search all
  search_usage search cpu
  search_usage search toolchain
  search_usage search
  search_usage search gpu extra
}

@test "as EUID 0 pc-oc search gpu without gpu/search.sh is a usage error and runs nothing" {
  fake_search_tree
  rm "$root/gpu/search.sh"
  search_usage search gpu
}

@test "as EUID 0 pc-oc search gpu exits 1 with the search.sh failed line when the script exits 3" {
  fake_search_tree
  fake_search gpu 3
  run --separate-stderr as_root "$root/pc-oc" search gpu
  [ "$status" -eq 1 ]
  [ "$stderr" = "pc-oc: gpu: search.sh failed" ]
  [ "$(<"$calls")" = "ran gpu search uid=0 PATH=/usr/bin SYSFS_ROOT=unset PC_OC_STATE=unset" ]
}

# every script in the scratch tree is a fake before pc-oc starts without root, as for the #56 cases
@test "non-root pc-oc search gpu refuses with the sudo hint and runs no component" {
  fake_search_tree
  refused search gpu
}

@test "as EUID 0 revert all and apply all never run gpu/search.sh" {
  local v line
  fake_search_tree
  for v in revert apply; do
    rm -f "$calls"
    run --separate-stderr as_root "$root/pc-oc" "$v" all
    [ "$status" -eq 0 ] || {
      echo "root $v all exited $status; stderr '$stderr'" >&3
      return 1
    }
    mapfile -t ran <"$calls"
    [ "${#ran[@]}" -eq 5 ] || {
      echo "root $v all ran: $(tr '\n' ';' <"$calls")" >&3
      return 1
    }
    for line in "${ran[@]}"; do
      [[ "$line" == "ran "*" $v uid="* ]] || {
        echo "root $v all ran '$line'" >&3
        return 1
      }
    done
  done
}

# Worker cases for #126: what the contract leaves open.
# Order of refusals without root: a target other than gpu is the usage error before the root check (whose
# toolchain exception would otherwise run toolchain/search.sh as the caller); a missing gpu/search.sh is
# found only as root, as for apply. Every script in the scratch tree is a fake.
@test "non-root pc-oc search with a target other than gpu is a usage error and runs nothing" {
  local t
  fake_search_tree
  for t in toolchain all cpu; do
    run --separate-stderr "$root/pc-oc" search "$t"
    [ "$status" -eq 2 ] || {
      echo "non-root search $t exited $status, want 2; stderr '$stderr'" >&3
      return 1
    }
    [[ "$stderr" == usage:* ]]
    [ -z "$output" ]
    [ ! -e "$calls" ] || {
      echo "non-root search $t ran: $(tr '\n' ';' <"$calls")" >&3
      return 1
    }
  done
}

@test "non-root pc-oc search gpu without gpu/search.sh still refuses with the sudo hint" {
  fake_search_tree
  rm "$root/gpu/search.sh"
  refused search gpu
}

# Amendment 2: the check is for toolchain/apply.sh only; a tree without it needs no calling user
@test "as EUID 0 with SUDO_UID unset apply all in a tree without toolchain/apply.sh runs the four root components" {
  local c
  for c in cpu ram gpu os; do
    fake_recorder "$c" apply
  done
  fake_recorder toolchain revert
  fake_recorder toolchain probe
  run --separate-stderr as_root env -u SUDO_UID "$root/pc-oc" apply all
  [ "$status" -eq 0 ] || {
    echo "root env -u SUDO_UID apply all exited $status; stderr '$stderr'" >&3
    return 1
  }
  [ -z "$stderr" ]
  mapfile -t ran <"$calls"
  [ "${#ran[@]}" -eq 4 ]
  [[ "${ran[0]}" == "ran cpu apply uid=0 "* ]]
  [[ "${ran[3]}" == "ran os apply uid=0 "* ]]
  [ ! -e "$setpriv_log" ]
}

@test "as EUID 0 with no absolute home or SUDO_UID=12x apply all dies before any component runs" {
  printf '%s\n' 'pc-oc-relhome:x:4245:4343::home/pc-oc-relhome:/usr/bin/bash' \
    'pc-oc-nohome:x:4246:4343:::/usr/bin/bash' >>"$BATS_TEST_TMPDIR/passwd"
  apply_all_needs_caller SUDO_UID=4245
  apply_all_needs_caller SUDO_UID=4246
  apply_all_needs_caller SUDO_UID=12x
}

@test "as EUID 0 with SUDO_UID unset apply all says to go through sudo or apply the components one by one" {
  apply_all_needs_caller -u SUDO_UID
  [ "$stderr" = "pc-oc: all: apply all needs the calling user: run it through sudo from your own account, or apply the components one by one" ]
}

# Amendment 1: probe all is unchanged, the check is apply all's alone
@test "as EUID 0 with SUDO_UID unset probe all still runs the four root probes, then dies at toolchain" {
  local c
  for c in cpu ram gpu os toolchain; do
    fake_recorder "$c" probe
  done
  run --separate-stderr as_root env -u SUDO_UID "$root/pc-oc" probe all
  [ "$status" -eq 1 ]
  mapfile -t ran <"$calls"
  [ "${#ran[@]}" -eq 4 ]
  [[ "${ran[3]}" == "ran os probe uid=0 "* ]]
  [ ! -e "$setpriv_log" ]
  [ "$stderr" = "pc-oc: toolchain: needs the calling user: run it without sudo, or through sudo from your own account" ]
}
