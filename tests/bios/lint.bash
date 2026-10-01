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
  [ "$#" -gt 0 ] || {
    echo "pc-oc: bios: usage: bios_lint <menu-paths.tsv> [<runbook.md>...]" >&2
    return 2
  }
  local table="$1" f
  shift
  for f in "$table" "$@"; do
    [ -r "$f" ] || {
      echo "pc-oc: bios: cannot read $f" >&2
      return 2
    }
  done
  [ "$#" -gt 0 ] || return 0
  LC_ALL=C awk -v keys="$(tail -n +2 "$table" | cut -f1)" -v paths="$(tail -n +2 "$table" | cut -f2)" '
    function hit(rule, what) { print FILENAME ":" FNR ": rule " rule ": " what; bad = 1 }
    # word(s, re): re is a whole word of s; a-z, 0-9 and _ make up words
    function word(s, re) { return s ~ ("(^|[^a-z0-9_])(" re ")([^a-z0-9_]|$)") }
    # strip(s): s without the reading tokens a Report/Read/Record line may name
    function strip(s, o, t) {
      while (match(s, /[A-Za-z0-9_.]+/)) {
        t = substr(s, RSTART, RLENGTH)
        sub(/\.+$/, "", t)
        o = o substr(s, 1, RSTART - 1) (t in reading ? " " : substr(s, RSTART, RLENGTH))
        s = substr(s, RSTART + RLENGTH)
      }
      return o s
    }
    # named(s): s names a leaf part or key suffix as a whole word
    function named(s, n, t, i) {
      for (n in name) {
        t = s
        while ((i = index(t, n))) {
          if (substr(t, i - 1, 1) !~ /[a-z0-9_]/ && substr(t, i + length(n), 1) !~ /[a-z0-9_]/) return 1
          t = substr(t, i + 1)
        }
      }
      return 0
    }
    function unclosed() {
      if (fence != "") { print fence ": rule 7: code fence never closes"; bad = 1 }
      fence = ""
    }
    BEGIN {
      n = split(keys, k, "\n")
      for (i = 1; i <= n; i++) known[k[i]] = 1
      n = split(paths, p, "\n")
      for (i = 1; i <= n; i++) {
        if (p[i] == "-" || p[i] == "") continue
        sub(/.* > /, "", p[i])
        m = split(tolower(p[i]), part, / \/ /)
        for (j = 1; j <= m; j++) name[part[j]] = 1
      }
      n = split("pl1 pl2 tau ac_ll dc_ll xmp freq vdd vddq tcl trcd trp tras trfc", k, " ")
      for (i = 1; i <= n; i++) name[k[i]] = 1
      reading["cpu.vcore_mv"] = reading["vcore_max_mv"] = reading["result.stability.vcore_max_mv"] = 1
      x = "[^a-z0-9]*"
      knob = "vcore|dvid|core" x "volt|(cpu|processor)" x "volt|vcc" x "(core|ia|in|sa)|load" x "line" x "cal" \
        "|ratio([^n]|$)|multiplier|bclk|(base|host|ref(erence)?|cpu|bus)" x "(clock|clk)|cpu" x "upgrade" \
        "|multi" x "core" x "(perf|enh)|enhanced" x "multi|per" x "core" x "limit|avx" x "(offset|setting)" \
        "|system" x "agent|vdd" x "2|memory" x "controller|(adaptive|override|offset)" x "(mode|volt)" \
        "|volt[a-z]*" x "(mode|offset|override|adaptive)|(^|[^a-z0-9])(llc|sa|fsb)([^a-z0-9]|$)" \
        "|(^|[^a-z0-9])v[ ._-]?core"
      n = split("set type enter change raise increase select enable adjust put configure modify use apply" \
        " lower reduce drop decrease disable turn switch toggle choose pick keep leave unlock remove bump" \
        " make lift override tweak tune flip restore load max try push add give go bring boost", k, " ")
      verb = "chose|chosen|made|kept|left|gave|given|went|gone|brought|more|higher|up|further|extra|beyond"
      for (i = 1; i <= n; i++) {
        st = k[i]
        sub(/e$/, "", st)
        verb = verb "|" k[i] "|" st substr(st, length(st)) "?(s|es|ed|d|ing)"
        if (k[i] ~ /y$/) verb = verb "|" substr(k[i], 1, length(k[i]) - 1) "(ies|ied)"
      }
      num = "(^|[^a-z0-9_.])[0-9]+"
      unit = num "([.][0-9]+)? ?(v|mv|w|kw|mohms?|mhz|ghz|mt/s|volts?|millivolts?|watts?|milliohms?)([^a-z0-9]|$)"
      value = "auto|enabled|disabled|unlimited|max|on|off"
    }
    FNR == 1 { unclosed(); ll = 1.1; ll_was = "stock 1.1 mOhm (intel-14-pl Table 77 p191)" }
    /[\200-\377]|<[A-Za-z\/!]|&#?[A-Za-z0-9]+;/ {
      hit(8, "not plain ASCII Markdown (non-ASCII byte, HTML tag or comment, or entity)")
      next
    }
    {
      infence = fence != ""
      if ($0 ~ /^```([a-z]+)?$/) { fence = infence ? "" : FILENAME ":" FNR; infence = 1 }
      s = $0
      gsub(/[*~`]/, "", s)
      gsub(/[ \t]+/, " ", s)
      l = tolower(s)
      field = rest = ""
      if (match(s, /^ ?(([-+]|[0-9]+\.) )?(Report|Read|Record|Revert|Save|Short|Run|Why|Note)( |:|$)/)) {
        field = substr(s, RSTART, RLENGTH)
        sub(/^ ?(([-+]|[0-9]+\.) )?/, "", field)
        sub(/[ :]$/, "", field)
        rest = tolower(substr(s, RSTART + RLENGTH))
      }
      r = field ~ /^Re(port|ad|cord)$/ ? tolower(strip(s)) : l
      if (r ~ knob)
        hit(3, "forbidden knob (core voltage, LLC, ratio, BCLK, CPU Upgrade, Multi-Core, VCC SA, VDD2)")

      if (word(l, "set")) {
        nset = 0
        nw = split(l, w, /[^a-z0-9_]+/)
        for (i = 1; i <= nw; i++) nset += w[i] == "set"
        if (nset > 1 || s !~ /^- SET [^ ]+ = [^ #]+( [^ #]+)*( # src: [a-z0-9-]+(,[a-z0-9-]+)*)?$/) {
          hit(1, "not a SET line: want - SET <key> = <value> # src: <id>[,<id>]")
          next
        }
        split(s, f, " ")
        key = f[3]
        if (!(key in known)) { hit(1, "SET key " key " has no row in menu-paths.tsv"); next }
        val = s
        sub(/^- SET [^ ]+ = /, "", val)
        sub(/ # src: .*/, "", val)
        if (s !~ / # src: /) hit(2, "SET " key " has no # src: cite")

        if (key == "cpu.pl1" || key == "cpu.pl2") {
          if (val !~ /^[0-9]+(\.[0-9]+)? W$/) hit(4, key " value \"" val "\" is not a plain decimal in W")
          else if (val + 0 > 219) hit(4, key " " val " is above 219 W")
        } else if (key == "mem.vdd" || key == "mem.vddq") {
          if (val !~ /^[0-9]+(\.[0-9]+)? m?V$/) hit(5, key " value \"" val "\" is not a plain decimal in V or mV")
          else if ((val ~ /mV$/ ? val / 1000 : val + 0) > 1.35) hit(5, key " " val " is above 1.35 V")
        } else if (key == "cpu.ac_ll") {
          if (val !~ /^[0-9]+(\.[0-9]+)? mOhm$/) hit(6, key " value \"" val "\" is not a plain decimal in mOhm")
          else if (val + 0 > ll) hit(6, key " " val " is above " ll_was)
          else { ll = val + 0; ll_was = "the previous " val }
        } else if (val !~ /^[A-Za-z0-9.+_-]+( (W|V|mV|mOhm|s|ms|MHz|ns))?$/)
          hit(1, key " value \"" val "\" is not one token and a unit")
        next
      }

      # rule 7 parts each line kind checks: a change verb, b number with unit, c name with value
      if (infence) { a = ""; b = c = l }
      else if (s ~ /^#/) { a = b = c = l; sub(/^#+ ?step [0-9]+/, "#", c) }
      else if (field ~ /^(Re(port|ad|cord|vert))$/) { a = rest; b = c = "" }
      else if (field != "") { a = rest; b = c = l }
      else {
        if ($0 !~ /^[ \t]*$/)
          hit(9, "not a heading, SET line or Report/Read/Record/Revert/Save/Short/Run/Why/Note line")
        next
      }
      why = word(a, verb) ? "change verb" : b ~ unit ? "number with unit" : \
        named(c) && (c ~ num || word(c, value)) ? "name with value" : ""
      if (why != "") hit(7, "BIOS change outside a SET line (" why ")")
    }
    END { unclosed(); exit bad }
  ' "$@"
}
