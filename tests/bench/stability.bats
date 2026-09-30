#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup() {
  skip "contract #13 pending"
  SCRIPT="$BATS_TEST_DIRNAME/../../bench/stability.sh"
  FIX="$BATS_TEST_DIRNAME/fixtures/stability"
  XID='NVRM: Xid (PCI:0000:01:00): 79, pid=1234, GPU has fallen off the bus.'
  STUB_DIR="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB_DIR"
  export JOURNAL="$FIX/journal-clean.txt" YC_EXIT=0 YC_SLEEP=0
  write_stubs
  export PATH="$STUB_DIR:$PATH"
}

# write_stubs: y-cruncher and stress-ng log each non-version call (tab-joined
# args); y-cruncher also records when its run starts, sleeps $YC_SLEEP and
# exits $YC_EXIT; journalctl logs its args and prints $JOURNAL
write_stubs() {
  cat >"$STUB_DIR/y-cruncher" <<STUB
#!/usr/bin/env bash
echo 'y-cruncher v0.8.7.9547'
case "\$*" in '' | version | --version | -v | -V) exit 0 ;; esac
(IFS=\$'\t'; printf '%s\n' "\$*") >>"$BATS_TEST_TMPDIR/calls-y-cruncher"
date +%s >"$BATS_TEST_TMPDIR/ycruncher-start"
sleep "\$YC_SLEEP"
exit "\$YC_EXIT"
STUB
  cat >"$STUB_DIR/stress-ng" <<STUB
#!/usr/bin/env bash
if [ "\$*" = --version ]; then echo 'stress-ng, version 0.22.01'; exit 0; fi
(IFS=\$'\t'; printf '%s\n' "\$*") >>"$BATS_TEST_TMPDIR/calls-stress-ng"
exit 0
STUB
  cat >"$STUB_DIR/journalctl" <<STUB
#!/usr/bin/env bash
if [ "\$*" = --version ]; then echo 'systemd 258 (258.1-1-arch)'; exit 0; fi
(IFS=\$'\t'; printf '%s\n' "\$*") >>"$BATS_TEST_TMPDIR/calls-journalctl"
cat "\$JOURNAL"
STUB
  chmod +x "$STUB_DIR"/*
}

# value <key>: print the value of stdout line <key>=
value() {
  local l
  for l in "${lines[@]}"; do
    [[ "$l" == "$1="* ]] && printf '%s\n' "${l#"$1="}" && return 0
  done
  return 1
}

# contract_order: stdout is input.* lines, then result.* lines, nothing else
contract_order() {
  local seen=0 l
  for l in "${lines[@]}"; do
    case "$l" in
      input.*=*) [ "$seen" -eq 0 ] || return 1 ;;
      result.*=*) seen=1 ;;
      *) return 1 ;;
    esac
  done
}

# since_arg: the --since value journalctl was called with
since_arg() {
  local -a a
  local i
  while IFS=$'\t' read -ra a; do
    for i in "${!a[@]}"; do
      case "${a[i]}" in
        --since | -S) printf '%s\n' "${a[i + 1]}" && return 0 ;;
        --since=*) printf '%s\n' "${a[i]#--since=}" && return 0 ;;
      esac
    done
  done <"$BATS_TEST_TMPDIR/calls-journalctl"
  return 1
}

# scan_fails_on <fixture> <line>: scan over <fixture> is FAIL with <line> first
scan_fails_on() {
  export JOURNAL="$FIX/$1"
  run --separate-stderr bash "$SCRIPT" scan "2026-09-30 21:00:00"
  [ "$status" -eq 1 ]
  contract_order
  [ "$(value result.stability.journal)" = FAIL ]
  [[ "$(value result.stability.first_error)" == *"$2" ]]
  [ "${lines[-1]}" = result.stability=FAIL ]
}

@test "cpu with clean tools and journal is PASS, exit 0" {
  run --separate-stderr bash "$SCRIPT" cpu 1
  [ "$status" -eq 0 ]
  contract_order
  [ "$(value result.stability.ycruncher)" = PASS ]
  [ "$(value result.stability.stressng)" = PASS ]
  [ "$(value result.stability.journal)" = PASS ]
  [ "${lines[-1]}" = result.stability=PASS ]
  [ -z "$(value result.stability.first_error)" ]
}

@test "cpu prints the exact y-cruncher and stress-ng arguments it ran as inputs" {
  run --separate-stderr bash "$SCRIPT" cpu 1
  [ "$status" -eq 0 ]
  inputs="$(grep '^input\.' <<<"$output")"
  yc="$(tr '\t' ' ' <"$BATS_TEST_TMPDIR/calls-y-cruncher")"
  sng="$(tr '\t' ' ' <"$BATS_TEST_TMPDIR/calls-stress-ng")"
  [ "$(wc -l <<<"$yc")" -eq 1 ]
  [ "$(wc -l <<<"$sng")" -eq 1 ]
  [[ "$inputs" == *"=$yc"* || "$inputs" == *"=y-cruncher $yc"* ]]
  [[ "$inputs" == *"=$sng"* || "$inputs" == *"=stress-ng $sng"* ]]
}

@test "cpu 2 runs stress-ng for 2 minutes" {
  run --separate-stderr bash "$SCRIPT" cpu 2
  [ "$status" -eq 0 ]
  [[ "$(tr '\t' ' ' <"$BATS_TEST_TMPDIR/calls-stress-ng") " =~ (-t|--timeout)[\ =](120s?|2m)\  ]]
}

@test "cpu scans the journal from before y-cruncher starts, not from earlier runs" {
  export YC_SLEEP=2
  start="$(date +%s)"
  run --separate-stderr bash "$SCRIPT" cpu 1
  [ "$status" -eq 0 ]
  since="$(since_arg)"
  since_s="$(date -d "$since" +%s)"
  [ "$since_s" -le "$(cat "$BATS_TEST_TMPDIR/ycruncher-start")" ]
  [ "$since_s" -ge "$((start - 1))" ]
}

@test "scan fails on an NVRM Xid line and prints the first one" {
  scan_fails_on journal-xid.txt "$XID"
  [ "$(value result.stability.ycruncher)" = SKIP ]
  [ "$(value result.stability.stressng)" = SKIP ]
  [ ! -e "$BATS_TEST_TMPDIR/calls-y-cruncher" ]
  [ ! -e "$BATS_TEST_TMPDIR/calls-stress-ng" ]
  [ "$(since_arg)" = "2026-09-30 21:00:00" ]
}

@test "scan fails on an mce: [Hardware Error] machine check line" {
  scan_fails_on journal-mce.txt 'mce: [Hardware Error]: CPU 12: Machine Check: 0 Bank 1: bc800800060c0859'
}

@test "scan fails on an APEI [Hardware Error] line with no mce: prefix" {
  scan_fails_on journal-ghes.txt '{1}[Hardware Error]: Hardware error from APEI Generic Hardware Error Source: 0'
}

@test "scan passes near misses: NVRM load, ACPI Error, usb error, RAS Errors" {
  run --separate-stderr bash "$SCRIPT" scan "2026-09-30 21:00:00"
  [ "$status" -eq 0 ]
  [ "$(value result.stability.journal)" = PASS ]
  [ "${lines[-1]}" = result.stability=PASS ]
}

@test "scan line 1 names journalctl, the bytes and the line count it read" {
  export JOURNAL="$FIX/journal-xid.txt"
  run --separate-stderr bash "$SCRIPT" scan "2026-09-30 21:00:00"
  [[ "${lines[0]}" =~ ^input\.source=(/[^\ ]*journalctl[^\ ]*)\ bytes=([0-9]+)\ items=([0-9]+)$ ]]
  [ "${BASH_REMATCH[2]}" -eq "$(wc -c <"$JOURNAL")" ]
  [ "${BASH_REMATCH[3]}" -eq "$(wc -l <"$JOURNAL")" ]
}

@test "y-cruncher exiting 1 is ycruncher=FAIL and overall FAIL, exit 1" {
  export YC_EXIT=1
  run --separate-stderr bash "$SCRIPT" cpu 1
  [ "$status" -eq 1 ]
  [ "$(value result.stability.ycruncher)" = FAIL ]
  [ "${lines[-1]}" = result.stability=FAIL ]
}

@test "scan with no since argument exits 2" {
  run --separate-stderr bash "$SCRIPT" scan
  [ "$status" -eq 2 ]
}
