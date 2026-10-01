# shellcheck shell=bash
# Runbook lint (#72), loaded by tests/bios/*.bats.

# bios_lint <menu-paths.tsv> [<runbook.md>...]: print one line per broken rule,
# `<runbook>:<line>: rule <n>: <what>`, at most one per rule per line; exit 1
# when any line printed, else 0. <line> is the line number in the file.
# Fail-closed (#72 amendments 2 and 3, 2026-10-01): whatever is not plainly in
# the allowed form is red; obfuscation is refused (rule 8), never decoded.
# Amendment 3 makes a runbook a fixed line grammar (rule 9); it replaces the
# amendment-2 reading of rule 7, its list markers (`>` is gone) and the core-
# voltage spellings of rule 3. Rules 1, 2, 4-6, 8, fences and normalizing read
# as before.
#
# Per line, in this order:
#  8. a line with a non-ASCII byte, an HTML tag or comment (`<` then a letter,
#     `/` or `!`) or an HTML entity (`&` then `#`? and alphanumerics then `;`)
#     is red on rule 8 alone; no other rule runs on it
#  fences: on the raw line, a line that is exactly ``` or ``` then [a-z]+
#     opens or closes a fence; nothing else does (```text `a` is a stray line)
#  normalize: drop `*`, `~` and backticks, collapse runs of spaces and tabs to
#     one space (`_` is kept); rules 1-7 and 9 match on the normalized line
#
# Line kinds, on the normalized line:
#  - SET line: has the whole word SET in any case. It is canonical when it is
#    exactly `- SET <key> = <value> # src: <id>[,<id>]` (ids [a-z0-9-]+), or
#    that without ` # src: ...`, with <key> a key of menu-paths.tsv
#  - heading: starts with `#`
#  - field line: an optional single space (indent, or what a dropped `*`
#    marker leaves), an optional list marker `- `, `+ ` or `<n>. `, then a
#    field word as printed: Report, Read, Record, Revert, Save, Short, Run,
#    Why or Note, then a space, `:` or the end (`Reading:` is not one)
#  - fence line: one that opens or closes a fence, and every line inside one
#
# A runbook is red:
#  1. a SET line is not canonical (`1.`, `*`, bare or lowercase marker, an
#     unknown key such as PL1, two SETs, text after the cite are all red)
#  2. a canonical SET line has no `# src:` cite (rule 2 only, not rule 1)
#  3. any line names core voltage (vcore anywhere, cpu_vcore, cpu.vcore, core
#     voltage, dvid, or a V not after a letter or digit, then at most one of
#     space, `-`, `.`, `_`, then core: V-Core, V core, V.Core), load-line
#     calibration (llc, load-line, load line, loadline calibration), ratio,
#     BCLK, host or reference clock, CPU Upgrade, Enhanced Multi-Core
#     Performance, VCC SA or VDD2; the only exceptions are cpu.vcore_mv,
#     vcore_max_mv and result.stability.vcore_max_mv on a Report, Read or
#     Record line. So a runbook cannot name a forbidden knob even in a warning
#     ("do not touch Vcore" is red)
#  4. cpu.pl1 or cpu.pl2 is not a plain decimal with unit W, or is above 219 W
#  5. mem.vdd or mem.vddq is not a plain decimal with unit V or mV, or is above
#     1.35 V
#  6. cpu.ac_ll is not a plain decimal with unit mOhm, or the first is above
#     stock 1.1 mOhm (intel-14-pl Table 77 p191), or a later one is above the
#     previous
#  7. a heading, field line or line inside a fence has a part its kind does
#     not lift (BIOS change outside a SET line):
#     a. a change verb, whole word, any case: set, type, enter, change, raise,
#        increase, select, enable, adjust, put, configure, modify, use, apply,
#        lower, reduce, drop, decrease, disable, turn, switch, toggle, choose,
#        pick, keep, leave, unlock, remove, bump, make, lift, override, tweak,
#        tune, flip, restore, load, max; each in every inflection: the verb, a
#        stem (the verb less a final e) with an optional repeat of its last
#        letter and then s, es, ed, d or ing (sets, setting, used, enabled,
#        disabled, dropped, maxes), and chose, chosen, made, kept, left.
#        `settings` and `us` are not verbs
#     b. a number then a unit, optional space between, unit any case and not
#        followed by a letter or digit: V, mV, W, kW, mOhm, mOhms, MHz, GHz,
#        MT/s, volt, volts, millivolt, millivolts, watt, watts, milliohm,
#        milliohms
#     c. a name together with a value anywhere on the line. A name, whole word
#        and any case, is each ` / `-separated part of a leaf (the last ` > `
#        segment of a menu-paths.tsv path; `-` has none), or a key suffix:
#        pl1 pl2 tau ac_ll dc_ll xmp freq vdd vddq tcl trcd trp tras trfc.
#        A value is a number, or the whole word Auto, Enabled, Disabled,
#        Unlimited, max, On or Off, any case. A heading's leading `Step <n>`
#        is not a value
#     A number is [0-9]+ with an optional .[0-9]+, not after a letter, digit,
#     `_` or `.` (PL1 and DDR5 hold none).
#     Lifted: headings, Why, Note, Save, Short and Run lines: nothing. Report,
#     Read and Record: b and c. Revert: b and c (it names a key and its stock
#     value; rules 4-6 judge SET values only). Inside a fence: a only. The
#     field word of a Save, Run or Revert line is never a verb. A fence still
#     open at end of file is red on rule 7 at its opening line.
#  9. outside a fence, a non-blank line is not a heading, SET line or field
#     line: prose (`Disable C-States.`), a table row, `> Report ...`,
#     `- Leave ...`. Rule 7 does not run on it; rules 3 and 8 do (rule 8
#     first, as above)
bios_lint() {
  echo "pc-oc: bios: lint not implemented" >&2
  return 1
}
