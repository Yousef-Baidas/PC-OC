#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup_file() {
  export BIOS_ROOT="${BIOS_ROOT:-$BATS_TEST_DIRNAME/../../bios}"
  local f="$BIOS_ROOT/undervolt.md"
  if [ -f "$f" ]; then
    echo "# $f bytes=$(wc -c <"$f") sets=$(grep -c '^- SET ' "$f")" >&3
  else
    echo "# $f missing" >&3
  fi
}

setup() {
  load lint
  RUNBOOK="$BIOS_ROOT/undervolt.md"
  echo "runbook: $RUNBOOK"
  [ -f "$RUNBOOK" ]
}

# sets: "<key> <value>" for each `- SET` line, in file order
sets() {
  sed -nE 's/^- SET ([^ ]+) = ([^ ]+).*/\1 \2/p' "$RUNBOOK"
}

@test "lint passes on undervolt.md" {
  run bios_lint "$BIOS_ROOT/menu-paths.tsv" "$RUNBOOK"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "undervolt.md SETs cpu.ac_ll at least twice, strictly descending" {
  sets
  bad="$(sets | awk '$1 == "cpu.ac_ll" {
      if (n++ && $2 + 0 >= prev) print "cpu.ac_ll " $2 " not below " prev
      prev = $2 + 0
    }
    END { if (n < 2) print "cpu.ac_ll SETs: " n + 0 }')"
  echo "$bad"
  [ -z "$bad" ]
}

@test "undervolt.md names the gate, vcore_max_mv, the scan and the margin rule" {
  local s missing=()
  for s in 'bench/stability.sh cpu 10' vcore_max_mv 'stability.sh scan'; do
    grep -qF -- "$s" "$RUNBOOK" || missing+=("$s")
  done
  grep -qi margin "$RUNBOOK" || missing+=(margin)
  echo "missing: ${missing[*]}"
  [ "${#missing[@]}" -eq 0 ]
}

@test "undervolt.md step 1 saves the current profile to a slot" {
  first="$(grep -m1 -E '^1\. ' "$RUNBOOK")"
  echo "step 1: $first"
  [[ "${first,,}" == *save*profile* ]]
}

@test "undervolt.md has a CMOS-clear recovery section naming CLR_CMOS" {
  grep -qiE '^#+ .*cmos' "$RUNBOOK"
  grep -qF CLR_CMOS "$RUNBOOK"
}

@test "undervolt.md stops before any SET when Intel Default Settings is not on" {
  local rep set
  rep="$(grep -n -E '^- Report:' "$RUNBOOK" | grep -F 'Intel Default Settings' | grep -i -w 'stop' | head -1 | cut -d: -f1 || true)"
  set="$(grep -n -m1 -E '^- SET' "$RUNBOOK" | cut -d: -f1)"
  echo "Report line: ${rep:-none}; first SET line: $set"
  [ -n "$rep" ]
  [ "$rep" -lt "$set" ]
}
