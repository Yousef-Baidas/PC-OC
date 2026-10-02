# shellcheck shell=bash disable=SC2034,SC2154 # REPO and FIX are read by the cases; stderr is set by bats run
# Shared helpers for tests/gpu/apply.bats, revert.bats and probe.bats (contract #127).

# gpu_tree: a fake repo at $REPO (lib/, pc-oc, the gpu scripts under test, and the recording
# stub as gpu/nvml.py), the mock state dir, and the systemctl and python3 mocks in
# $BATS_TEST_TMPDIR/bin, which is first on PATH and bound over /usr/bin by guard.sh. The
# caller adds the nvidia-smi mock of its choice to that directory.
# Mock state: pl (the power limit, stock 150.00), calls (-pl calls), order (every
# nvidia-smi, nvml and systemctl call, one line each, in call order), python3 (how the
# helper was started), offsets ("<core> <mem>"), unit (enabled | disabled | missing).
gpu_tree() {
  unset "${!GIT_@}"
  FIX="$BATS_TEST_DIRNAME/fixtures/apply"
  REPO="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$REPO/gpu" "$BATS_TEST_TMPDIR/bin" "$BATS_TEST_TMPDIR/varlib"
  cp -r "$BATS_TEST_DIRNAME/../../lib" "$REPO/lib"
  cp "$BATS_TEST_DIRNAME/../../pc-oc" "$REPO/pc-oc"
  cp "$BATS_TEST_DIRNAME/../../gpu/"{apply.sh,revert.sh,probe.sh,pl.sh} "$REPO/gpu/"
  cp "$FIX/nvml-stub.bash" "$REPO/gpu/nvml.py"
  export MOCK_DIR="$FIX"
  export MOCK_STATE="$BATS_TEST_TMPDIR/mock"
  mkdir -p "$MOCK_STATE"
  # stock 150.00 differs from the card default 160.00, so revert-to-default fails
  printf '150.00\n' >"$MOCK_STATE/pl"
  printf '0 0\n' >"$MOCK_STATE/offsets"
  printf 'disabled\n' >"$MOCK_STATE/unit"
  : >"$MOCK_STATE/calls"
  : >"$MOCK_STATE/order"
  : >"$MOCK_STATE/python3"
  cp "$FIX/systemctl" "$FIX/python3" "$BATS_TEST_TMPDIR/bin/"
  : >"$BATS_TEST_TMPDIR/varlib/.pc-oc-test-mock"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  export PC_OC_STATE="$BATS_TEST_TMPDIR/state"
  unset MOCK_NVML MOCK_SYSTEMCTL MOCK_FAIL_ENABLE MOCK_FAIL_DISABLE MOCK_FAIL_STOP
}

# in_ns <cmd>...: run <cmd> as the calling user in a private mount namespace where the
# mocks stand over /usr/bin/nvidia-smi, /usr/bin/systemctl and /usr/bin/python3. Every run
# of a gpu script in these files goes through here or through in_ns_root.
in_ns() {
  GUARD_AS=user GUARD_MOCKS="$BATS_TEST_TMPDIR/bin" /usr/bin/unshare \
    --map-user="$(id -u)" --map-group="$(id -g)" --keep-caps -m \
    /usr/bin/bash "$FIX/guard.sh" "$@"
}

# in_ns_root <cmd>...: the same as uid 0 (unshare -r), where pc-oc and the gpu scripts pin
# PATH=/usr/bin and keep their state under /var/lib; $BATS_TEST_TMPDIR/varlib is bound there.
in_ns_root() {
  GUARD_AS=root GUARD_MOCKS="$BATS_TEST_TMPDIR/bin" GUARD_VARLIB="$BATS_TEST_TMPDIR/varlib" \
    /usr/bin/unshare -r -m /usr/bin/bash "$FIX/guard.sh" "$@"
}

# set_values <pl_w> <core_offset_mhz> <mem_offset_mhz>: write the gpu/values file of the fake repo
set_values() {
  printf 'pl_w=%s  # src: smi\ncore_offset_mhz=%s  # src: nvml-offset-t\nmem_offset_mhz=%s  # src: nvml-offset-t\n' \
    "$1" "$2" "$3" >"$REPO/gpu/values"
}

# set_snapshot <pl_w>: write a stock snapshot as probe.sh would have
set_snapshot() {
  mkdir -p "$PC_OC_STATE/gpu"
  printf 'source=/x bytes=1 items=1\ngpu.pl_w=%s\n' "$1" >"$PC_OC_STATE/gpu/stock"
}

# tuned <pl> <core> <mem> <unit>: put the mocked card and boot unit in this state
tuned() {
  printf '%s\n' "$1" >"$MOCK_STATE/pl"
  printf '%s %s\n' "$2" "$3" >"$MOCK_STATE/offsets"
  printf '%s\n' "$4" >"$MOCK_STATE/unit"
}

# logged <ERE>: how many lines of the order log match
logged() {
  grep -c -E -- "$1" "$MOCK_STATE/order" || :
}

# line_of <ERE>: line number of the first match in the order log, empty when none
line_of() {
  grep -n -m 1 -E -- "$1" "$MOCK_STATE/order" | cut -d: -f1 || :
}

# own_messages: the stderr lines of the last run that the gpu script itself wrote, which
# leaves out the helper's (pc-oc: gpu: nvml: ...) and anything a mock printed
own_messages() {
  grep -E '^pc-oc: gpu: ' <<<"$stderr" | grep -v -E '^pc-oc: gpu: nvml: ' || :
}

# starts_unit <log>: true when a systemctl line of <log> would start the unit
starts_unit() {
  grep -q -E -- '^systemctl( .*)? (start|restart|try-restart|reload-or-restart|--now)( |$)' "$1"
}

# no_start <log>: fail, showing the lines, when <log> has such a line (#127 case 15)
no_start() {
  if starts_unit "$1"; then
    grep -E -- '^systemctl ' "$1" >&2
    return 1
  fi
}

# reset_logs: forget the calls of the earlier runs of this case
reset_logs() {
  : >"$MOCK_STATE/order"
  : >"$MOCK_STATE/calls"
  : >"$MOCK_STATE/python3"
  rm -f "$MOCK_STATE/signalled"
}

# EREs for the order log: a call that enables the unit, that disables it, either, one that
# stops it, and one that asks is-enabled. is-enabled is none of the first four.
ENABLE='^systemctl( .*)? enable( |$)'
DISABLE='^systemctl( .*)? disable( |$)'
SWITCH='^systemctl( .*)? (enable|disable)( |$)'
STOP='^systemctl( .*)? stop( |$)'
IS_ENABLED='^systemctl( .*)? is-enabled( |$)'
