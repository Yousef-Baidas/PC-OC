# shellcheck shell=bash
# Runbook lint (#72), loaded by tests/bios/*.bats.

# bios_lint <menu-paths.tsv> [<runbook.md>...]: print one line per broken rule,
# `<runbook>:<line>: rule <n>: <what>`, at most one per rule per line; exit 1
# when any line printed, else 0. <line> is the line number in the file.
# Fail-closed (#72 amendment 2, 2026-10-01): whatever is not plainly in the
# allowed form is red; obfuscation is refused (rule 8), never decoded.
#
# Per line, in this order:
#  8. a line with a non-ASCII byte, an HTML tag or comment (`<` then a letter,
#     `/` or `!`) or an HTML entity (`&` then `#`? and alphanumerics then `;`)
#     is red on rule 8 alone; no other rule runs on it
#  fences: on the raw line, a line that is exactly ``` or ``` then [a-z]+
#     opens or closes a fence; nothing else does (```text `a` is prose)
#  normalize: drop `*`, `~` and backticks, collapse runs of spaces and tabs to
#     one space (`_` is kept); rules 1-7 match on the normalized line
#
# A SET line has the whole word SET in any case. It is canonical when it is
# exactly `- SET <key> = <value> # src: <id>[,<id>]` (ids [a-z0-9-]+), or that
# without ` # src: ...`, with <key> a key of menu-paths.tsv. A runbook is red:
#  1. a SET line is not canonical (`1.`, `*`, bare or lowercase marker, an
#     unknown key such as PL1, two SETs, text after the cite are all red)
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
#  7. a line that is not a SET line has any of (BIOS change outside a SET line):
#     - a change verb, whole word, any case: set, type, enter, change, raise,
#       increase, select, enable, adjust, put, configure, modify, use, apply,
#       lower, reduce, drop, decrease
#     - a number then a unit, optional space between, unit any case and not
#       followed by a letter or digit: V, mV, W, kW, mOhm, MHz, GHz
#     - the leaf of a menu-paths.tsv path (its last ` > ` segment, `-` has
#       none), any case, together with a value: a number, or the whole word
#       Auto, Enabled, Disabled, Unlimited or max (any case)
#     A line whose first word after an optional list marker (`-`, `+`, `>`,
#     `1.`) is Report, Read or Record is exempt from rule 7 only. Inside a
#     fence only the change-verb part is lifted; every other rule and part
#     applies. A fence still open at end of file is red on rule 7 at its
#     opening line.
bios_lint() {
  echo "pc-oc: bios: lint not implemented" >&2
  return 1
}
