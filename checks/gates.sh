#!/usr/bin/env bash
set -euo pipefail
# The one gate: shellcheck, shfmt, bats. Exits non-zero on the first failure.
# Checks tracked and untracked-not-ignored files, so a new script is gated before
# it is staged. teams/ and .claude/ are Proteus tooling, not project code.

cd "$(git rev-parse --show-toplevel)"

mapfile -t files < <(git ls-files -co --exclude-standard -- \
  '*.sh' '*.bash' '*.bats' pc-oc ':!teams/' ':!.claude/')
mapfile -t tests < <(git ls-files -co --exclude-standard -- 'tests/*.bats')

echo "shellcheck: ${#files[@]} files"
shellcheck "${files[@]}"

echo "shfmt: ${#files[@]} files"
shfmt -d -i 2 -ci "${files[@]}"

echo "bats: ${#tests[@]} files"
bats -r tests/

echo "gates: green"
