#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

# ram.bats must go red when bios/ram.md drops a voltage SET line. Each case
# runs ram.bats against a mutated copy of bios/ through BIOS_ROOT.

setup_file() {
  local src="$BATS_TEST_DIRNAME/../../bios"
  echo "# $src bytes=$(cat "$src"/*.md | wc -c) files=$(find "$src" -type f | wc -l) ram-sets=$(grep -c '^- SET ' "$src/ram.md")" >&3
}

setup() {
  SRC="$BATS_TEST_DIRNAME/../../bios"
  COPY="$BATS_TEST_TMPDIR/bios"
  cp -r "$SRC" "$COPY"
}

# mutant_without <key>: drop every `- SET <key> = ...` line from the copy
mutant_without() {
  sed -i -E "/^- SET $1 = /d" "$COPY/ram.md"
  ! grep -qE "^- SET $1 = " "$COPY/ram.md"
}

run_ram() {
  BIOS_ROOT="$COPY" run -- bats "$BATS_TEST_DIRNAME/ram.bats"
  echo "$output"
}

@test "ram.bats goes red when ram.md has no mem.vdd SET line" {
  mutant_without mem.vdd
  run_ram
  [ "$status" -ne 0 ]
  [[ "$output" =~ mem\.vdd([^q]|$) ]]
}

@test "ram.bats goes red when ram.md has no mem.vddq SET line" {
  mutant_without mem.vddq
  run_ram
  [ "$status" -ne 0 ]
  [[ "$output" == *mem.vddq* ]]
}

@test "ram.bats stays green on an unmodified copy of bios/" {
  run_ram
  [ "$status" -eq 0 ]
}
