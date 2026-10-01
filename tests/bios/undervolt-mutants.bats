#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

# undervolt.bats must go red when bios/undervolt.md loses its Intel Default
# Settings Report line or has it after the first SET. Each case runs
# undervolt.bats against a mutated copy of bios/ through BIOS_ROOT.

setup_file() {
  local src="$BATS_TEST_DIRNAME/../../bios"
  echo "# $src bytes=$(cat "$src"/*.md | wc -c) files=$(find "$src" -type f | wc -l) undervolt-sets=$(grep -c '^- SET ' "$src/undervolt.md")" >&3
}

setup() {
  SRC="$BATS_TEST_DIRNAME/../../bios"
  COPY="$BATS_TEST_TMPDIR/bios"
  cp -r "$SRC" "$COPY"
  cp -r "$SRC/../sources" "$BATS_TEST_TMPDIR/sources"
}

# report_line: number of the Intel Default Settings stop line in the copy
report_line() {
  grep -n -E '^- Report:' "$COPY/undervolt.md" | grep -F 'Intel Default Settings' | grep -i -w 'stop' | head -1 | cut -d: -f1
}

run_undervolt() {
  BIOS_ROOT="$COPY" run -- bats "$BATS_TEST_DIRNAME/undervolt.bats"
  echo "$output"
}

@test "undervolt.bats goes red when the Intel Default Settings Report line is deleted" {
  skip "contract #102 pending"
  local ln
  ln="$(report_line)"
  echo "deleted line: $ln"
  [ -n "$ln" ]
  sed -i "${ln}d" "$COPY/undervolt.md"
  run_undervolt
  [ "$status" -ne 0 ]
}

@test "undervolt.bats goes red when the Report line moves after the last SET" {
  skip "contract #102 pending"
  local ln line
  ln="$(report_line)"
  echo "moved line: $ln"
  [ -n "$ln" ]
  line="$(sed -n "${ln}p" "$COPY/undervolt.md")"
  sed -i "${ln}d" "$COPY/undervolt.md"
  printf '%s\n' "$line" >>"$COPY/undervolt.md"
  run_undervolt
  [ "$status" -ne 0 ]
}

@test "undervolt.bats stays green on an unmodified copy of bios/" {
  skip "contract #102 pending"
  run_undervolt
  [ "$status" -eq 0 ]
}
