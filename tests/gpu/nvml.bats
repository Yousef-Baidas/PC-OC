#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

# Contract for gpu/nvml.py (#123). The numbered cases live in nvml_test.py; this
# file runs them and holds the checks that need a real process.

setup() {
  unset "${!GIT_@}"
  REPO="$(git -C "$BATS_TEST_DIRNAME" rev-parse --show-toplevel)"
  # test-only override, the same one nvml_test.py reads; nothing in the repo sets it
  HELPER="${PC_OC_NVML_HELPER:-$REPO/gpu/nvml.py}"
  cd "$REPO" || return 1
}

@test "nvml: the unittest contract passes under python3 -I -B" {
  run /usr/bin/python3 -I -B tests/gpu/nvml_test.py
  [ "$status" -eq 0 ] || {
    printf '%s\n' "$output"
    false
  }
  [[ "${lines[0]}" == "nvml_test: helper=$HELPER sha256="* ]]
}

@test "nvml: no argument exits 2 with a pc-oc: gpu: nvml: message" {
  [ -f "$HELPER" ]
  run --separate-stderr /usr/bin/python3 -I -B "$HELPER"
  [ "$status" -eq 2 ]
  [ "$output" = "" ]
  [[ "$stderr" == "pc-oc: gpu: nvml: "* ]]
}

@test "nvml: an unknown command exits 2 with a pc-oc: gpu: nvml: message" {
  [ -f "$HELPER" ]
  run --separate-stderr /usr/bin/python3 -I -B "$HELPER" bogus
  [ "$status" -eq 2 ]
  [ "$output" = "" ]
  [[ "$stderr" == "pc-oc: gpu: nvml: "* ]]
}

@test "nvml: no command and an unknown command do not import pynvml" {
  [ -f "$HELPER" ]
  run --separate-stderr /usr/bin/python3 -I -B -X importtime "$HELPER"
  [ "$status" -eq 2 ]
  imports="$stderr"
  run --separate-stderr /usr/bin/python3 -I -B -X importtime "$HELPER" bogus
  [ "$status" -eq 2 ]
  imports+=$'\n'"$stderr"
  [[ "$imports" == *"import time:"* ]]
  run grep -E '^import time:.*\| +pynvml$' <<<"$imports"
  [ "$status" -eq 1 ]
}

@test "nvml: the contract and the helper leave no __pycache__ under gpu/ or tests/gpu/" {
  [ -f "$HELPER" ]
  run /usr/bin/python3 -I -B tests/gpu/nvml_test.py
  run /usr/bin/python3 -I -B "$HELPER"
  run git status --porcelain --ignored --untracked-files=all -- gpu tests/gpu
  [ "$status" -eq 0 ]
  [[ "$output" != *__pycache__* ]]
  [[ "$output" != *.pyc* ]]
}
