#!/usr/bin/env bash
set -euo pipefail
# Bench output helpers. Source after lib/common.sh; do not execute.

# need <tool> <install hint>: die unless <tool> is on PATH
need() {
  command -v "$1" >/dev/null || die bench "$1 not found; install: $2"
}

# input_line <source> <bytes> <items>: print the input.source= line
input_line() {
  [[ "$2" =~ ^[0-9]+$ ]] || die bench "input_line: bytes is not a non-negative integer: $2"
  [[ "$3" =~ ^[0-9]+$ ]] || die bench "input_line: items is not a non-negative integer: $3"
  printf 'input.source=%s bytes=%s items=%s\n' "$1" "$2" "$3"
}
