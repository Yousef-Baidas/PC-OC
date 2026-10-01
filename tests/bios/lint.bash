# shellcheck shell=bash
# Runbook lint (#72), loaded by tests/bios/*.bats.

# bios_lint <menu-paths.tsv> [<runbook.md>...]: print one line per broken rule,
# `<runbook>:<line>: rule <n>: <what>`; exit 1 when any line printed, else 0.
# An allowlist (#72 amendment, 2026-10-01); a runbook line is red when:
#  1. a line with the word SET (any case) is not exactly `- SET <key> = <value>`
#     then its cite `  # src: <id>[,<id>]`, with <key> a key of menu-paths.tsv
#     (`1.`, `*`, bare or lowercase marker, backticks, two SETs are all red)
#  2. a canonical SET line has no `# src:` cite (rule 2 only, not rule 1)
#  3. any line, SET or prose, names core voltage (vcore, cpu_vcore, cpu.vcore,
#     core voltage, dvid), load-line calibration (llc, load-line, load line,
#     loadline calibration), ratio, BCLK, host or reference clock, CPU Upgrade,
#     Enhanced Multi-Core Performance, VCC SA or VDD2; the only exceptions are
#     cpu.vcore_mv, vcore_max_mv and result.stability.vcore_max_mv on a line
#     starting Report/Read/Record. So a runbook cannot name a forbidden knob
#     even in a warning ("do not touch Vcore" is red)
#  4. cpu.pl1 or cpu.pl2 is not a plain decimal with unit W, or is above 219 W
#  5. mem.vdd or mem.vddq is not a plain decimal with unit V or mV, or is above
#     1.35 V
#  6. cpu.ac_ll is not a plain decimal with unit mOhm, or the first is above
#     stock 1.1 mOhm (intel-14-pl Table 77 p191), or a later one is above the
#     previous
#  7. outside SET lines and fenced code blocks, a line has the whole word set,
#     type, enter, change, raise, increase, select or enable (any case): BIOS
#     change outside a SET line; readings use Report/Read/Record
bios_lint() {
  echo "pc-oc: bios: lint not implemented" >&2
  return 1
}
