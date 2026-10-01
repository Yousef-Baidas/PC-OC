#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup() {
  FIX="$BATS_TEST_DIRNAME/fixtures/run"
  # run.sh and report.sh write results/ and reports/ next to bench/: run copies
  # in a fake repo whose bench scripts and pc-oc are stubs
  R="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$R/bench" "$R/lib"
  cp "$BATS_TEST_DIRNAME/../../bench/run.sh" "$BATS_TEST_DIRNAME/../../bench/report.sh" "$R/bench/"
  cp "$BATS_TEST_DIRNAME/../../lib/common.sh" "$R/lib/"
  STUB_DIR="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB_DIR"
  write_stub "$R/pc-oc" 0 'cpu.pl1_uw=65000000'
  cp "$R/pc-oc" "$STUB_DIR/pc-oc"
  write_stub "$R/bench/compile.sh" 0 'result.compile.median_s=200.0'
  write_stub "$R/bench/stability.sh" 0 'result.stability=PASS'
  write_stub "$R/bench/game.sh" 0 'result.game.avg_fps=100.0'
  cat >"$STUB_DIR/sudo" <<'STUB'
#!/usr/bin/env bash
while [[ "$1" == -* ]]; do shift; done
exec "$@"
STUB
  chmod +x "$STUB_DIR/sudo"
  export PATH="$STUB_DIR:$PATH"
  export XDG_DATA_HOME="$BATS_TEST_TMPDIR/data"
  LOGS="$XDG_DATA_HOME/pc-oc/mangohud/baseline"
  mkdir -p "$LOGS"
  for n in 1 2 3; do
    printf 'v1\nv0.8.4\nrun %s\n' "$n" >"$LOGS/Cyberpunk2077_2026-09-30_21-0$n-00.csv"
  done
  # a zone whose local date differs from the UTC date right now
  if [ "$(date -u +%H)" -lt 12 ]; then export TZ=Etc/GMT+12; else export TZ=Etc/GMT-14; fi
  DAY="$(date -u +%F)"
}

# write_stub <path> <exit> <stdout>: a script that logs "<name> <args>", prints
# <stdout> and exits <exit>
write_stub() {
  cat >"$1" <<STUB
#!/usr/bin/env bash
printf '%s %s\n' "${1##*/}" "\$*" >>"$BATS_TEST_TMPDIR/calls"
printf '%s\n' '$3'
exit $2
STUB
  chmod +x "$1"
}

@test "run baseline writes the four files under results/<UTC date>-baseline" {
  run --separate-stderr bash "$R/bench/run.sh" baseline
  [ "$status" -eq 0 ]
  [ "$(ls "$R/results")" = "$DAY-baseline" ]
  d="$R/results/$DAY-baseline"
  [ "$(cat "$d/settings.txt")" = 'cpu.pl1_uw=65000000' ]
  [ "$(cat "$d/compile.txt")" = 'result.compile.median_s=200.0' ]
  [ "$(cat "$d/stability.txt")" = 'result.stability=PASS' ]
  [ "$(cat "$d/game.txt")" = 'result.game.avg_fps=100.0' ]
  grep -qx 'pc-oc probe all' "$BATS_TEST_TMPDIR/calls"
  grep -qx 'stability.sh cpu.*' "$BATS_TEST_TMPDIR/calls"
}

@test "run baseline copies the label's MangoHud logs and parses all three" {
  run --separate-stderr bash "$R/bench/run.sh" baseline
  [ "$status" -eq 0 ]
  for f in "$LOGS"/*.csv; do
    cmp "$f" "$R/results/$DAY-baseline/${f##*/}"
  done
  game="$(grep '^game.sh ' "$BATS_TEST_TMPDIR/calls")"
  [[ "$game" == "game.sh parse "* ]]
  for n in 1 2 3; do
    [[ "$game" == *"Cyberpunk2077_2026-09-30_21-0$n-00.csv"* ]]
  done
}

@test "run exits 1 and leaves no report when compile.sh exits 1" {
  write_stub "$R/bench/compile.sh" 1 'result.compile.median_s=200.0'
  run --separate-stderr bash "$R/bench/run.sh" baseline
  [ "$status" -eq 1 ]
  [[ "$stderr" == "pc-oc: bench: "* ]]
  [[ "$stderr" != *"not implemented"* ]]
  [ -z "$(find "$R/reports" -type f 2>/dev/null)" ]
  d="$R/results/$DAY-baseline"
  # no results dir that looks complete
  [ ! -f "$d/settings.txt" ] || [ ! -f "$d/compile.txt" ] || [ ! -f "$d/stability.txt" ] || [ ! -f "$d/game.txt" ]
}

@test "run exits 1 when the label has no MangoHud logs" {
  rm "$LOGS"/*.csv
  run --separate-stderr bash "$R/bench/run.sh" baseline
  [ "$status" -eq 1 ]
  [[ "$stderr" == "pc-oc: bench: "* ]]
  [[ "$stderr" != *"not implemented"* ]]
  run ! grep -q '^game.sh ' "$BATS_TEST_TMPDIR/calls"
}

@test "report over two results dirs writes reports/<label>.md with a +10.0% delta for 100 to 110 fps" {
  run --separate-stderr bash "$R/bench/report.sh" "$FIX/2026-09-02-tuned" "$FIX/2026-09-01-baseline"
  [ "$status" -eq 0 ]
  md="$R/reports/tuned.md"
  grep -F 'result.game.avg_fps' "$md" | grep -F '110.0' | grep -F '100.0' | grep -qF '+10.0%'
  # absolute and percent differ here: 200.0 s to 180.0 s is -20.0 and -10.0%
  grep -F 'result.compile.median_s' "$md" | grep -F -- '-20.0' | grep -qF -- '-10.0%'
  grep -F 'result.game.low1_fps' "$md" | grep -qF '+6.7%'
}

@test "report shows every result, the inputs, the settings snapshot and the date, and regenerates identically" {
  run --separate-stderr bash "$R/bench/report.sh" "$FIX/2026-09-02-tuned"
  [ "$status" -eq 0 ]
  md="$R/reports/tuned.md"
  cut -d= -f1 "$FIX"/2026-09-02-tuned/*.txt | grep '^result\.' >"$BATS_TEST_TMPDIR/keys"
  [ "$(wc -l <"$BATS_TEST_TMPDIR/keys")" -eq 7 ]
  while read -r key; do
    grep -qF "$key" "$md"
  done <"$BATS_TEST_TMPDIR/keys"
  grep -qF 'gcc (GCC) 15.2.1 20250813' "$md"
  grep -qF 'input.kernel_version' "$md"
  grep -F 'cpu.pl1_uw' "$md" | grep -qF 125000000
  grep -F 'os.governor' "$md" | grep -qF performance
  grep -qF 2026-09-02 "$md"
  cp "$md" "$BATS_TEST_TMPDIR/first.md"
  run --separate-stderr bash "$R/bench/report.sh" "$FIX/2026-09-02-tuned"
  [ "$status" -eq 0 ]
  cmp "$BATS_TEST_TMPDIR/first.md" "$md"
}

# real_md: run report.sh on the real-output fixture; sets MD to the one report written
real_md() {
  bash "$R/bench/report.sh" "$FIX/real" >/dev/null
  [ "$(find "$R/reports" -name '*.md' | wc -l)" -eq 1 ]
  MD="$(find "$R/reports" -name '*.md')"
}

# has_row <md> <key> <value>: a table row with a cell equal to <key> and a cell equal to <value>
has_row() {
  awk -F'|' -v k="$2" -v v="$3" '
    /^[[:space:]]*\|/ {
      hk = 0; hv = 0
      for (i = 1; i <= NF; i++) {
        c = $i; gsub(/^[[:space:]]+|[[:space:]]+$/, "", c)
        if (c == k) hk = 1
        if (c == v) hv = 1
      }
      if (hk && hv) found = 1
    }
    END { exit !found }' "$1"
}

@test "report on real output has a row per result key with the exact value" {
  real_md
  n=0
  while IFS= read -r line; do
    has_row "$MD" "${line%%=*}" "${line#*=}"
    n=$((n + 1))
  done < <(grep -h '^result\.' "$FIX"/real/*.txt)
  [ "$n" -gt 0 ]
}

@test "report on real output has no row for source= or input.* header lines" {
  real_md
  # a split on every '=' turns "bytes=N items=N" into cells of their own
  run ! grep -E '^[[:space:]]*\|[[:space:]]*(source|input\.[a-z0-9_]+|bytes|items)[[:space:]]*\|' "$MD"
  [ "$(grep -cE '^[[:space:]]*\|[[:space:]]*result\.' "$MD")" -gt 0 ]
}

@test "report on real output keeps cpu, gpu, os and ram settings with exact values" {
  real_md
  for p in cpu gpu os ram; do
    [ "$(grep -c "^$p\." "$FIX/real/settings.txt")" -gt 0 ]
  done
  while IFS= read -r line; do
    has_row "$MD" "${line%%=*}" "${line#*=}"
  done < <(grep -E '^(cpu|gpu|os|ram)\.' "$FIX/real/settings.txt")
}

@test "report on real output has as many result rows as result lines" {
  real_md
  want="$(cat "$FIX"/real/*.txt | grep -c '^result\.')"
  got="$(grep -cE '^[[:space:]]*\|[[:space:]]*result\.' "$MD")"
  [ "$want" -gt 0 ]
  [ "$got" -eq "$want" ]
}

@test "run refuses to overwrite a finished results dir" {
  mkdir -p "$R/results/$DAY-baseline"
  echo keep >"$R/results/$DAY-baseline/settings.txt"
  run --separate-stderr bash "$R/bench/run.sh" baseline
  [ "$status" -eq 1 ]
  [[ "$stderr" == "pc-oc: bench: "* ]]
  [ "$(cat "$R/results/$DAY-baseline/settings.txt")" = keep ]
}

@test "run removes its results dir when any step fails" {
  for step in pc-oc bench/stability.sh bench/game.sh; do
    write_stub "$R/$step" 1 'x'
    run --separate-stderr bash "$R/bench/run.sh" baseline
    [ "$status" -eq 1 ]
    [[ "$stderr" == "pc-oc: bench: "* ]]
    [ ! -e "$R/results/$DAY-baseline" ]
    write_stub "$R/pc-oc" 0 'cpu.pl1_uw=65000000'
    write_stub "$R/bench/stability.sh" 0 'result.stability=PASS'
    write_stub "$R/bench/game.sh" 0 'result.game.avg_fps=100.0'
  done
}

@test "run and report exit 2 on bad usage" {
  run --separate-stderr bash "$R/bench/run.sh"
  [ "$status" -eq 2 ]
  run --separate-stderr bash "$R/bench/run.sh" ../evil
  [ "$status" -eq 2 ]
  run --separate-stderr bash "$R/bench/report.sh"
  [ "$status" -eq 2 ]
}

@test "report exits 1 on a results dir that lacks a file" {
  cp -r "$FIX/2026-09-02-tuned" "$BATS_TEST_TMPDIR/2026-09-02-tuned"
  rm "$BATS_TEST_TMPDIR/2026-09-02-tuned/game.txt"
  run --separate-stderr bash "$R/bench/report.sh" "$BATS_TEST_TMPDIR/2026-09-02-tuned"
  [ "$status" -eq 1 ]
  [[ "$stderr" == "pc-oc: bench: "* ]]
  [ -z "$(find "$R/reports" -type f 2>/dev/null)" ]
}
