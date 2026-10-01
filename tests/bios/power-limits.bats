#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup_file() {
  export BIOS_ROOT="${BIOS_ROOT:-$BATS_TEST_DIRNAME/../../bios}"
  local f="$BIOS_ROOT/power-limits.md"
  if [ -f "$f" ]; then
    echo "# $f bytes=$(wc -c <"$f") sets=$(grep -c '^- SET ' "$f")" >&3
  else
    echo "# $f missing" >&3
  fi
}

setup() {
  skip "contract #77 pending"
  load lint
  RUNBOOK="$BIOS_ROOT/power-limits.md"
  echo "runbook: $RUNBOOK"
  [ -f "$RUNBOOK" ]
}

# sets: "<key> <value>" for each `- SET` line, in file order
sets() {
  sed -nE 's/^- SET ([^ ]+) = ([^ ]+).*/\1 \2/p' "$RUNBOOK"
}

@test "lint passes on power-limits.md" {
  run bios_lint "$BIOS_ROOT/menu-paths.tsv" "$RUNBOOK"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "power-limits.md SETs exactly cpu.pl1 and cpu.pl2, both 219" {
  sets
  [ "$(sets | cut -d' ' -f1 | sort -u | paste -sd' ')" = "cpu.pl1 cpu.pl2" ]
  bad="$(sets | awk '$2 != 219')"
  echo "not 219: $bad"
  [ -z "$bad" ]
}

@test "power-limits.md names the verify keys and the gate command" {
  local s missing=()
  for s in cpu.pl1_uw=219000000 cpu.pl2_uw=219000000 'bench/stability.sh cpu 10'; do
    grep -qF -- "$s" "$RUNBOOK" || missing+=("$s")
  done
  echo "missing: ${missing[*]}"
  [ "${#missing[@]}" -eq 0 ]
}

@test "power-limits.md step 1 saves the current profile to a slot" {
  first="$(grep -m1 -E '^1\. ' "$RUNBOOK")"
  echo "step 1: $first"
  [[ "${first,,}" == *save*profile* ]]
}

@test "power-limits.md has a CMOS-clear recovery section naming CLR_CMOS" {
  grep -qiE '^#+ .*cmos' "$RUNBOOK"
  grep -qF CLR_CMOS "$RUNBOOK"
}
