#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031 # bats `run` sets status/output/stderr in the test shell; shellcheck reads each @test as a subshell

bats_require_minimum_version 1.5.0

# Contract #26: pc-oc root hardening. The rest of pc-oc is covered in tests/lib/pc-oc.bats.
# EUID 0 seam: `unshare -r` runs pc-oc as uid 0 in a user namespace, never real root.
# Contract #56 (incident run log #1): root-path cases go through as_root, which runs under `unshare -rm`
# with mocks bind-mounted over /usr/bin/systemctl and /usr/bin/nvidia-smi and scratch over /var/lib,
# and aborts (97) unless the mocks are in place. pc-oc pins PATH=/usr/bin, so only a mount keeps
# the real tools out of reach.

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
  cat >"$BATS_TEST_TMPDIR/guard.sh" <<EOF
#!/usr/bin/bash
mount --bind "$BATS_TEST_TMPDIR/mocks/systemctl" /usr/bin/systemctl || exit 97
mount --bind "$BATS_TEST_TMPDIR/mocks/nvidia-smi" /usr/bin/nvidia-smi || exit 97
mount --bind "$BATS_TEST_TMPDIR/varlib" /var/lib || exit 97
[[ "\$(sed -n 2p /usr/bin/systemctl)" == "# pc-oc-test-mock" ]] || exit 97
[[ "\$(sed -n 2p /usr/bin/nvidia-smi)" == "# pc-oc-test-mock" ]] || exit 97
[[ "\$(cat /var/lib/marker)" == pc-oc-test-scratch ]] || exit 97
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
  [ "$stderr" = "pc-oc: $1 needs root: sudo pc-oc $1 $2" ] || {
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
  skip "contract #56 pending"
  refused apply os
}

@test "non-root pc-oc revert gpu refuses with the sudo hint and runs no component" {
  skip "contract #56 pending"
  refused revert gpu
}

@test "non-root pc-oc revert all refuses with the sudo hint and runs no component" {
  skip "contract #56 pending"
  refused revert all
}

@test "non-root pc-oc apply all refuses with the sudo hint and runs no component" {
  skip "contract #56 pending"
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
  [ "$stderr" = "pc-oc: $2 needs root: sudo pc-oc $2 $3" ] || {
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
  skip "contract #56 pending"
  refused_env_euid 0 apply os
  refused_env_euid 0 revert all
}

@test "as_root env EUID=1000 pc-oc apply os still runs with SYSFS_ROOT and PC_OC_STATE unset" {
  skip "contract #56 pending"
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
  skip "contract #56 pending"
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
