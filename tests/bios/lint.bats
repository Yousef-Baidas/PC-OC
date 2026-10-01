#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup_file() {
  export BIOS_ROOT="${BIOS_ROOT:-$BATS_TEST_DIRNAME/../../bios}"
  local fix="$BATS_TEST_DIRNAME/fixtures/lint" table="$BIOS_ROOT/menu-paths.tsv" t=missing
  [ ! -f "$table" ] || t="bytes=$(wc -c <"$table") rows=$(($(wc -l <"$table") - 1))"
  echo "# $fix bytes=$(cat "$fix"/* | wc -c) files=$(find "$fix" -type f | wc -l); $table $t" >&3
}

setup() {
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

@test "lint passes reading-ok.md (vcore reading tokens on Report/Read/Record lines)" {
  run bios_lint "$FIX/menu-paths.tsv" "$FIX/reading-ok.md"
  echo "$output"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "lint passes runbook-ok.md (full canonical runbook)" {
  run bios_lint "$FIX/menu-paths.tsv" "$FIX/runbook-ok.md"
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

@test "lint fails bclk.md on rule 3 (BCLK named on a Report line)" {
  lint_fails bclk.md 11 3
}

@test "lint fails pl-253.md on rule 4 (cpu.pl1 above 219)" {
  lint_fails pl-253.md 7 4
}

@test "lint fails vdd-140.md on rule 5 (mem.vdd above 1.35)" {
  lint_fails vdd-140.md 12 5
}

@test "lint fails ll-up.md on rule 6 (cpu.ac_ll goes up)" {
  lint_fails ll-up.md 10 6
}

@test "lint fails set-dotless.md on rule 1 (SET key PL1 is not a menu-paths key)" {
  lint_fails set-dotless.md 7 1
}

@test "lint fails set-offform.md on rule 1 (SET line not in canonical form)" {
  lint_fails set-offform.md 7 1
}

@test "lint fails prose-change.md on rule 7 (number with unit on a Note line)" {
  lint_fails prose-change.md 12 7
}

@test "lint fails llc-spaced.md on rule 3 (Load Line Calibration in a fence)" {
  lint_fails llc-spaced.md 12 3
}

@test "lint fails vcore-underscore.md on rule 3 (CPU_Vcore on a Note line)" {
  lint_fails vcore-underscore.md 11 3
}

@test "lint fails pl-unlimited.md on rule 4 (cpu.pl1 not a plain number)" {
  lint_fails pl-unlimited.md 7 4
}

@test "lint fails ll-first-high.md on rule 6 (first cpu.ac_ll above stock 1.1 mOhm)" {
  lint_fails ll-first-high.md 9 6
}

@test "lint fails adjust-verb.md on rule 7 (change verb adjust on a Note line)" {
  lint_fails adjust-verb.md 12 7
}

@test "lint fails table-row.md on rule 9 (a table row is outside the line grammar)" {
  lint_fails table-row.md 12 9
}

@test "lint fails leaf-value.md on rule 7 (menu leaf with a value on a Note line)" {
  lint_fails leaf-value.md 7 7
}

@test "lint fails split-bold.md on rule 7 (verb split by ** on a Note line)" {
  lint_fails split-bold.md 12 7
}

@test "lint fails zwsp-set.md on rule 8 (zero-width space inside SET)" {
  lint_fails zwsp-set.md 7 8
}

@test "lint fails entity.md on rule 8 (HTML entity in V&#99;ore)" {
  lint_fails entity.md 11 8
}

@test "lint fails fence-info.md on rule 9 (a backtick info string is not a fence)" {
  lint_fails fence-info.md 15 9
}

@test "lint fails fence-unclosed.md on rule 7 (fence open at end of file)" {
  lint_fails fence-unclosed.md 15 7
}

@test "lint fails c-states.md on rule 9 (prose outside the line grammar)" {
  lint_fails c-states.md 11 9
}

@test "lint fails leave-auto.md on rule 9 (list item whose first word is no field)" {
  lint_fails leave-auto.md 11 9
}

@test "lint fails record-raise.md on rule 7 (change verb on a Record line)" {
  lint_fails record-raise.md 12 7
}

@test "lint fails note-pl1.md on rule 7 (key suffix with a value on a Note line)" {
  lint_fails note-pl1.md 7 7
}

@test "lint fails why-volts.md on rule 7 (number with spelled unit on a Why line)" {
  lint_fails why-volts.md 12 7
}

@test "lint fails v-core.md on rule 3 (V-Core on a Report line)" {
  lint_fails v-core.md 11 3
}
