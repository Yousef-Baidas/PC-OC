# shellcheck shell=bash
# Runbook lint (#72), loaded by tests/bios/*.bats.

# bios_lint <menu-paths.tsv> [<runbook.md>...]: print one line per broken rule,
# `<runbook>:<line>: rule <n>: <what>`; exit 1 when any line printed, else 0
bios_lint() {
  echo "pc-oc: bios: lint not implemented" >&2
  return 1
}
