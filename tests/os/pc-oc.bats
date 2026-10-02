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
  skip "contract #117 pending"
  fake_all_loggers
  fake_recorder toolchain apply
  run --separate-stderr env HOME="$BATS_TEST_TMPDIR/home" "$root/pc-oc" apply toolchain
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$calls")" -eq 1 ]
  [[ "$(<"$calls")" == "ran toolchain apply uid=$(id -u) HOME=$BATS_TEST_TMPDIR/home "* ]]
}

# apply all is the #56 case above; with toolchain let through, the other components must still refuse
@test "non-root pc-oc apply gpu refuses with the sudo hint and runs no component" {
  skip "contract #117 pending"
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
  skip "contract #117 pending"
  needs_caller -u SUDO_UID
}

@test "as EUID 0 with SUDO_UID=0 apply toolchain dies needing the calling user and runs nothing" {
  skip "contract #117 pending"
  needs_caller SUDO_UID=0
}

@test "as EUID 0 with SUDO_UID=12x apply toolchain dies needing the calling user and runs nothing" {
  skip "contract #117 pending"
  needs_caller SUDO_UID=12x
}

@test "as EUID 0 with SUDO_GID unset apply toolchain dies needing the calling user and runs nothing" {
  skip "contract #117 pending"
  needs_caller -u SUDO_GID
}

@test "as EUID 0 apply toolchain calls setpriv with exactly the contract's argument vector and a clean environment" {
  skip "contract #117 pending"
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
  skip "contract #117 pending"
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
  skip "contract #117 pending"
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
