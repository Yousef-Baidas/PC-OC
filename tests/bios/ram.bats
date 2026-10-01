#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup_file() {
  export BIOS_ROOT="${BIOS_ROOT:-$BATS_TEST_DIRNAME/../../bios}"
  local f="$BIOS_ROOT/ram.md"
  if [ -f "$f" ]; then
    echo "# $f bytes=$(wc -c <"$f") sets=$(grep -c '^- SET ' "$f")" >&3
  else
    echo "# $f missing" >&3
  fi
}

setup() {
  load lint
  RUNBOOK="$BIOS_ROOT/ram.md"
  echo "runbook: $RUNBOOK"
  [ -f "$RUNBOOK" ]
}

# sets: "<key> <value>" for each `- SET` line, in file order
sets() {
  sed -nE 's/^- SET ([^ ]+) = ([^ ]+).*/\1 \2/p' "$RUNBOOK"
}

@test "lint passes on ram.md" {
  run bios_lint "$BIOS_ROOT/menu-paths.tsv" "$RUNBOOK"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "ram.md SETs mem.vdd and mem.vddq at 1.35 or below" {
  local k missing=()
  for k in mem.vdd mem.vddq; do
    sets | awk -v k="$k" '$1 == k { f = 1 } END { exit !f }' || missing+=("$k")
  done
  echo "no SET line for: ${missing[*]}"
  [ "${#missing[@]}" -eq 0 ]
  bad="$(sets | awk '($1 == "mem.vdd" || $1 == "mem.vddq") && $2 + 0 > 1.35')"
  echo "above 1.35: $bad"
  [ -z "$bad" ]
}

@test "ram.md SETs mem.freq to 6000 then 6400" {
  freq="$(sets | awk '$1 == "mem.freq" { print $2 }' | paste -sd' ')"
  echo "mem.freq SETs: $freq"
  [ "$freq" = "6000 6400" ]
}

@test "ram.md names the gate and the soak" {
  local s missing=()
  for s in 'stability.sh cpu 10' 'stability.sh soak 60'; do
    grep -qF -- "$s" "$RUNBOOK" || missing+=("$s")
  done
  echo "missing: ${missing[*]}"
  [ "${#missing[@]}" -eq 0 ]
}

@test "ram.md has a no-POST recovery section" {
  grep -qiE '^#+ .*no-post' "$RUNBOOK"
}

@test "ram.md step 1 saves the current profile to a slot" {
  first="$(grep -m1 -E '^1\. ' "$RUNBOOK")"
  echo "step 1: $first"
  [[ "${first,,}" == *save*profile* ]]
}

@test "ram.md has a CMOS-clear recovery section naming CLR_CMOS" {
  grep -qiE '^#+ .*cmos' "$RUNBOOK"
  grep -qF CLR_CMOS "$RUNBOOK"
}

@test "ram.md runs pc-oc by its installed path" {
  local n
  n="$(grep -c 'pc-oc probe' "$RUNBOOK" || true)"
  echo "lines with pc-oc probe: $n"
  [ "$n" -ge 1 ]
  bad="$(grep -n 'pc-oc probe' "$RUNBOOK" | grep -vF '/usr/local/lib/pc-oc/pc-oc probe' | cut -d: -f1 | paste -sd' ' || true)"
  echo "lines without the installed path: $bad"
  [ -z "$bad" ]
}
