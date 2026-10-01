#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup_file() {
  export BIOS_ROOT="${BIOS_ROOT:-$BATS_TEST_DIRNAME/../../bios}"
  local fix="$BATS_TEST_DIRNAME/fixtures/lint" table="$BIOS_ROOT/menu-paths.tsv" t=missing
  [ ! -f "$table" ] || t="bytes=$(wc -c <"$table") rows=$(($(wc -l <"$table") - 1))"
  echo "# $fix bytes=$(cat "$fix"/* | wc -c) files=$(find "$fix" -type f | wc -l); $table $t" >&3
}

setup() {
  skip "contract #72 pending"
  load lint
  FIX="$BATS_TEST_DIRNAME/fixtures/lint"
  TABLE="$BIOS_ROOT/menu-paths.tsv"
  MANIFEST="$BATS_TEST_DIRNAME/../../sources/manifest.tsv"
}

# lint_fails <fixture> <line> <rule>: the lint prints exactly one finding,
# that rule on that line, and exits 1
lint_fails() {
  run bios_lint "$FIX/menu-paths.tsv" "$FIX/$1"
  echo "$output"
  [ "$status" -eq 1 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "${lines[0]}" == "$FIX/$1:$2: rule $3: "* ]]
}

@test "menu-paths.tsv header is key, path, doc, page, note" {
  [ -f "$TABLE" ]
  [ "$(head -n1 "$TABLE")" = $'key\tpath\tdoc\tpage\tnote' ]
}

@test "menu-paths.tsv has a row for every contract key" {
  [ -f "$TABLE" ]
  local k missing=()
  for k in cpu.pl1 cpu.pl2 cpu.tau cpu.ac_ll cpu.dc_ll mem.xmp mem.freq mem.vdd \
    mem.vddq mem.tcl mem.trcd mem.trp mem.tras mem.trfc; do
    cut -f1 "$TABLE" | grep -qxF "$k" || missing+=("$k")
  done
  echo "missing: ${missing[*]}"
  [ "${#missing[@]}" -eq 0 ]
}

@test "every menu-paths.tsv row cites a manifest doc and a page; a '-' path is confirm-on-screen" {
  [ -f "$TABLE" ]
  run awk -F'\t' -v ids="$(tail -n +2 "$MANIFEST" | cut -f1 | paste -sd' ')" '
    BEGIN { n = split(ids, a, " "); for (i = 1; i <= n; i++) ok[a[i]] = 1 }
    NR > 1 && (NF != 5 || $2 == "" || !($3 in ok) || $4 !~ /^[1-9][0-9]*$/ ||
      ($2 == "-" && $5 != "confirm-on-screen")) { print NR ": " $0 }
  ' "$TABLE"
  echo "$output"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "lint passes every runbook in BIOS_ROOT" {
  [ -f "$TABLE" ]
  shopt -s nullglob
  local books=("$BIOS_ROOT"/*.md)
  run bios_lint "$TABLE" "${books[@]}"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "lint passes ok.md" {
  run bios_lint "$FIX/menu-paths.tsv" "$FIX/ok.md"
  echo "$output"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "lint fails unknown-key.md on rule 1 (SET key has no menu-paths row)" {
  lint_fails unknown-key.md 11 1
}

@test "lint fails no-cite.md on rule 2 (SET line has no # src:)" {
  lint_fails no-cite.md 12 2
}

@test "lint fails bclk.md on rule 3 (forbidden knob)" {
  lint_fails bclk.md 11 3
}

@test "lint fails vdd-140.md on rule 4 (mem.vdd above 1.35)" {
  lint_fails vdd-140.md 12 4
}

@test "lint fails pl-253.md on rule 5 (cpu.pl1 above 219)" {
  lint_fails pl-253.md 7 5
}

@test "lint fails ll-up.md on rule 6 (cpu.ac_ll goes up)" {
  lint_fails ll-up.md 10 6
}
