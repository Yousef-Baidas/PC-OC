#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup() {
  FIX="$BATS_TEST_DIRNAME/fixtures/report"
  # report.sh writes reports/ next to bench/: run a copy in a fake repo
  R="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$R/bench" "$R/lib"
  cp "$BATS_TEST_DIRNAME/../../bench/report.sh" "$R/bench/"
  cp "$BATS_TEST_DIRNAME/../../lib/common.sh" "$R/lib/"
  AXES="cpu.model, cpu.microcode, gpu.name, gpu.driver, gpu.vbios, os.kernel"
}

# section <md> <heading>: the lines under "## <heading>" up to the next heading
section() {
  awk -v h="## $2" '
    $0 == h { on = 1; next }
    /^## / { on = 0 }
    on' "$1"
}

# rows <md> <heading>: the table rows of a section as "cell<TAB>cell<TAB>...",
# without the header row and the separator; "\|" stays inside its cell
rows() {
  section "$1" "$2" | awk '
    /^\|/ {
      if (!seen++) next
      gsub(/\\\|/, "\001")
      n = split($0, c, "|")
      if (c[2] ~ /^-+$/) next
      out = ""
      for (i = 2; i < n; i++) {
        x = c[i]; gsub(/^ +| +$/, "", x); gsub(/\001/, "\\|", x)
        out = out (i > 2 ? "\t" : "") x
      }
      print out
    }'
}

# order_ok <md> <heading>...: the headings occur in this order
order_ok() {
  local md="$1" prev=0 n h
  shift
  for h in "$@"; do
    n="$(grep -nxF "## $h" "$md" | head -n1 | cut -d: -f1)"
    [ -n "$n" ] && [ "$n" -gt "$prev" ] || return 1
    prev="$n"
  done
}

@test "report with a compare dir lists exactly the changed settings with both values" {
  skip "contract #145 pending"
  run --separate-stderr bash "$R/bench/report.sh" "$FIX/2026-10-02-pl" "$FIX/2026-10-01-old"
  [ "$status" -eq 0 ]
  md="$R/reports/pl.md"
  order_ok "$md" Results "Settings changed" Comparability "Settings snapshot" Inputs
  [ "$(rows "$md" "Settings changed")" = "$(printf 'cpu.pl1_uw\t125000000\t65000000\ngpu.pl_w\t180.00\t160.00')" ]
}

@test "report with identical settings says none, names all six axes and exits 0" {
  skip "contract #145 pending"
  run --separate-stderr bash "$R/bench/report.sh" "$FIX/2026-10-02-same" "$FIX/2026-10-01-old"
  [ "$status" -eq 0 ]
  md="$R/reports/same.md"
  [ "$(section "$md" "Settings changed" | grep -v '^$')" = none ]
  [ "$(section "$md" Comparability | grep -v '^$')" = "Same on: $AXES" ]
  [ -z "$stderr" ]
}

@test "report on a differing kernel and driver names both axes, exits 3 and still writes the deltas" {
  skip "contract #145 pending"
  run --separate-stderr bash "$R/bench/report.sh" "$FIX/2026-10-02-kern" "$FIX/2026-10-01-old"
  [ "$status" -eq 3 ]
  [ "${#lines[@]}" -le 1 ]
  [ "$(printf '%s\n' "$stderr" | wc -l)" -eq 2 ]
  [ "${stderr_lines[0]}" = "pc-oc: bench: fixed axis differs: gpu.driver" ]
  [ "${stderr_lines[1]}" = "pc-oc: bench: fixed axis differs: os.kernel" ]
  md="$R/reports/kern.md"
  [ -f "$md" ]
  want="NOT COMPARABLE on gpu.driver: 580.82.09 -> 590.44.01
NOT COMPARABLE on os.kernel: 6.17.1-1-cachyos -> 6.18.2-1-cachyos
Same on: cpu.model, cpu.microcode, gpu.name, gpu.vbios"
  [ "$(section "$md" Comparability | grep -v '^$')" = "$want" ]
  grep -F 'result.game.avg_fps' "$md" | grep -F 110.0 | grep -F 100.0 | grep -qF '+10.0%'
  grep -F 'result.compile.median_s' "$md" | grep -qF -- '-5.0%'
}

@test "report puts a key found in one directory only in the table with n/a, new files first" {
  skip "contract #145 pending"
  run --separate-stderr bash "$R/bench/report.sh" "$FIX/2026-10-02-onlynew" "$FIX/2026-10-01-onlyold"
  [ "$status" -eq 0 ]
  md="$R/reports/onlynew.md"
  want="ram.xmp	on	n/a
cpu.pl1_uw	125000000	65000000
ram.profile	1	n/a
os.governor	n/a	powersave
os.thp	n/a	madvise"
  [ "$(rows "$md" "Settings changed")" = "$want" ]
}

@test "report counts a fixed axis missing in the compare dir as differing and exits 3" {
  skip "contract #145 pending"
  run --separate-stderr bash "$R/bench/report.sh" "$FIX/2026-10-02-same" "$FIX/2026-10-01-novbios"
  [ "$status" -eq 3 ]
  [ "$stderr" = "pc-oc: bench: fixed axis differs: gpu.vbios" ]
  md="$R/reports/same.md"
  [ -f "$md" ]
  want="NOT COMPARABLE on gpu.vbios: n/a -> 95.04.31.00.9f
Same on: cpu.model, cpu.microcode, gpu.name, gpu.driver, os.kernel"
  [ "$(section "$md" Comparability | grep -v '^$')" = "$want" ]
  [ "$(rows "$md" "Settings changed")" = "$(printf 'gpu.vbios\t95.04.31.00.9f\tn/a')" ]
}

@test "report escapes a pipe in a value so the row keeps three cells" {
  skip "contract #145 pending"
  run --separate-stderr bash "$R/bench/report.sh" "$FIX/2026-10-02-pipe" "$FIX/2026-10-01-old"
  [ "$status" -eq 0 ]
  md="$R/reports/pipe.md"
  row="$(section "$md" "Settings changed" | grep -F 'os.cmdline')"
  [ "$row" = '| os.cmdline | quiet a\|b | quiet |' ]
  [ "$(printf '%s' "$row" | sed 's/\\|//g' | tr -cd '|' | wc -c)" -eq 4 ]
}

@test "report without a compare dir is byte-identical to the expected file and regenerates identically either way" {
  skip "contract #145 pending"
  run --separate-stderr bash "$R/bench/report.sh" "$FIX/2026-10-02-pl"
  [ "$status" -eq 0 ]
  cmp "$FIX/expected-pl.md" "$R/reports/pl.md"
  run --separate-stderr bash "$R/bench/report.sh" "$FIX/2026-10-02-pl"
  cmp "$FIX/expected-pl.md" "$R/reports/pl.md"
  run --separate-stderr bash "$R/bench/report.sh" "$FIX/2026-10-02-pl" "$FIX/2026-10-01-old"
  cp "$R/reports/pl.md" "$BATS_TEST_TMPDIR/first.md"
  run --separate-stderr bash "$R/bench/report.sh" "$FIX/2026-10-02-pl" "$FIX/2026-10-01-old"
  cmp "$BATS_TEST_TMPDIR/first.md" "$R/reports/pl.md"
}
