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
    # word(s, re): re is a whole word of s; anything but a-z0-9 breaks words
    function word(s, re) { return s ~ ("(^|[^a-z0-9])(" re ")([^a-z0-9]|$)") }
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
    # leafval(s): s names a menu leaf and, besides the leaf, a value
    function leafval(s, lf, i, rest) {
      for (lf in leaf) {
        if (!index(s, lf)) continue
        rest = s
        while ((i = index(rest, lf))) rest = substr(rest, 1, i - 1) " " substr(rest, i + length(lf))
        if (rest ~ /[0-9]/ || word(rest, "auto|enabled|disabled|unlimited|max")) return 1
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
      for (i = 1; i <= n; i++) if (p[i] != "-" && p[i] != "") { sub(/.* > /, "", p[i]); leaf[tolower(p[i])] = 1 }
      reading["cpu.vcore_mv"] = reading["vcore_max_mv"] = reading["result.stability.vcore_max_mv"] = 1
      x = "[^a-z0-9]*"
      knob = "vcore|dvid|core" x "volt|(cpu|processor)" x "volt|vcc" x "(core|ia|in|sa)|load" x "line" x "cal" \
        "|ratio([^n]|$)|multiplier|bclk|(base|host|ref(erence)?|cpu|bus)" x "(clock|clk)|cpu" x "upgrade" \
        "|multi" x "core" x "(perf|enh)|enhanced" x "multi|per" x "core" x "limit|avx" x "(offset|setting)" \
        "|system" x "agent|vdd" x "2|memory" x "controller|(adaptive|override|offset)" x "(mode|volt)" \
        "|volt[a-z]*" x "(mode|offset|override|adaptive)"
      verb = "sets?|types?|typed|typing|enter(s|ed|ing)?|chang(e|es|ed|ing)|rais(e|es|ed|ing)" \
        "|increas(e|es|ed|ing)|select(s|ed|ing)?|enabl(e|es|ed|ing)|adjust(s|ed|ing)?|puts?|putting" \
        "|configur(e|es|ed|ing)|modif(y|ies|ied|ying)|us(e|es|ed|ing)|appl(y|ies|ied|ying)" \
        "|lower(s|ed|ing)?|reduc(e|es|ed|ing)|drop(s|ped|ping)?|decreas(e|es|ed|ing)"
      unit = "[0-9] ?(v|mv|w|kw|mohm|mhz|ghz)([^a-z0-9]|$)"
    }
    FNR == 1 { unclosed(); ll = 1.1; ll_was = "stock 1.1 mOhm (intel-14-pl Table 77 p191)" }
    /[\200-\377]|<[A-Za-z\/!]|&#?[A-Za-z0-9]+;/ {
      hit(8, "not plain ASCII Markdown (non-ASCII byte, HTML tag or comment, or entity)")
      next
    }
    /^```([a-z]+)?$/ { fence = fence == "" ? FILENAME ":" FNR : "" }
    {
      s = $0
      gsub(/[*~`]/, "", s)
      gsub(/[ \t]+/, " ", s)
      l = tolower(s)
      rep = l ~ /^ ?(([-+>]|[0-9]+\.) )?(report|read|record)([^a-z0-9]|$)/
      r = rep ? tolower(strip(s)) : l
      if (r ~ knob || word(r, "llc|sa|fsb"))
        hit(3, "forbidden knob (core voltage, LLC, ratio, BCLK, CPU Upgrade, Multi-Core, VCC SA, VDD2)")

      nset = 0
      nw = split(l, w, /[^a-z0-9]+/)
      for (i = 1; i <= nw; i++) nset += w[i] == "set"
      if (!nset) {
        if (!rep && ((fence == "" && word(l, verb)) || l ~ unit || leafval(l)))
          hit(7, "BIOS change outside a SET line; readings use Report/Read/Record")
        next
      }

      if (nset > 1 || s !~ /^- SET [^ ]+ = [^ #]+( [^ #]+)*( # src: [a-z0-9-]+(,[a-z0-9-]+)*)?$/) {
        hit(1, "not a SET line: want - SET <key> = <value> # src: <id>[,<id>]")
        next
      }
      split(s, f, " ")
      key = f[3]
      val = s
      sub(/^- SET [^ ]+ = /, "", val)
      sub(/ # src: .*/, "", val)
      if (s !~ / # src: /) hit(2, "SET " key " has no # src: cite")
      if (!(key in known)) { hit(1, "SET key " key " has no row in menu-paths.tsv"); next }

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
    }
    END { unclosed(); exit bad }
  ' "$@"
}
