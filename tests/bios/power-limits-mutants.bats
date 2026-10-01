#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

# power-limits.bats must go red when bios/power-limits.md loses the installed
# copy check before its first probe. Each case runs power-limits.bats against a
# mutated copy of bios/ through BIOS_ROOT.

setup_file() {
  local src="$BATS_TEST_DIRNAME/../../bios"
  echo "# $src bytes=$(cat "$src"/*.md | wc -c) files=$(find "$src" -type f | wc -l) power-limits-sets=$(grep -c '^- SET ' "$src/power-limits.md")" >&3
}

setup() {
  SRC="$BATS_TEST_DIRNAME/../../bios"
  COPY="$BATS_TEST_TMPDIR/bios"
  cp -r "$SRC" "$COPY"
  cp -r "$SRC/../sources" "$BATS_TEST_TMPDIR/sources"
}

# mutant_without <fixed string>: drop every line of the copy containing it
mutant_without() {
  sed -i "\\|$1|d" "$COPY/power-limits.md"
  ! grep -qF -- "$1" "$COPY/power-limits.md"
}

run_power_limits() {
  BIOS_ROOT="$COPY" run -- bats "$BATS_TEST_DIRNAME/power-limits.bats"
  echo "$output"
}

@test "power-limits.bats goes red when no line reads the installed VERSION" {
  skip "contract #103 pending"
  mutant_without /usr/local/lib/pc-oc/VERSION
  run_power_limits
  [ "$status" -ne 0 ]
}

@test "power-limits.bats goes red when no line runs os/install.sh" {
  skip "contract #103 pending"
  mutant_without os/install.sh
  run_power_limits
  [ "$status" -ne 0 ]
}

@test "power-limits.bats stays green on an unmodified copy of bios/" {
  skip "contract #103 pending"
  run_power_limits
  [ "$status" -eq 0 ]
}
