#!/usr/bin/env bash
set -euo pipefail
# Bench output helpers. Source after lib/common.sh; do not execute.

# need <tool> <install hint>: die unless <tool> is on PATH
need() {
  die bench "not implemented"
}

# input_line <source> <bytes> <items>: print the input.source= line
input_line() {
  die bench "not implemented"
}
