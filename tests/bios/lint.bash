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
  awk -v keys="$(tail -n +2 "$table" | cut -f1)" '
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
    # rule 7 findings inside a code fence count only if the fence never closes
    function flush(i) {
      for (i = 1; i <= npend; i++) print pend[i]
      if (npend) bad = 1
      npend = 0
    }
    BEGIN {
      n = split(keys, k, "\n")
      for (i = 1; i <= n; i++) known[k[i]] = 1
      reading["cpu.vcore_mv"] = reading["vcore_max_mv"] = reading["result.stability.vcore_max_mv"] = 1
      x = "[^a-z0-9]*"
      knob = "vcore|dvid|core" x "volt|(cpu|processor)" x "volt|vcc" x "(core|ia|in|sa)|load" x "line" x "cal" \
        "|ratio([^n]|$)|multiplier|bclk|(base|host|ref(erence)?|cpu|bus)" x "(clock|clk)|cpu" x "upgrade" \
        "|multi" x "core" x "(perf|enh)|enhanced" x "multi|per" x "core" x "limit|avx" x "(offset|setting)" \
        "|system" x "agent|vdd" x "2|memory" x "controller|(adaptive|override|offset)" x "(mode|volt)" \
        "|volt[a-z]*" x "(mode|offset|override|adaptive)"
      verb = "sets?|types?|typed|typing|enter(s|ed|ing)?|chang(e|es|ed|ing)|rais(e|es|ed|ing)" \
        "|increas(e|es|ed|ing)|select(s|ed|ing)?|enabl(e|es|ed|ing)"
    }
    FNR == 1 { flush(); fence = ""; ll = 1.1; ll_was = "stock 1.1 mOhm (intel-14-pl Table 77 p191)" }
    {
      l = tolower($0)
      r = $0 ~ /^[ \t]*([-*+] |[0-9]+[.)] )?(Report|Read|Record)([^A-Za-z0-9]|$)/ ? tolower(strip($0)) : l
      if (r ~ knob || word(r, "llc|sa|fsb"))
        hit(3, "forbidden knob (core voltage, LLC, ratio, BCLK, CPU Upgrade, Multi-Core, VCC SA, VDD2)")

      infence = fence != ""
      if (match($0, /^ ? ? ?(```|~~~)/)) {
        m = substr($0, RSTART + RLENGTH - 3, 3)
        if (!infence) fence = m
        else if (m == fence) { fence = ""; npend = 0 }
        infence = 1
      }

      nset = 0
      nw = split(l, w, /[^a-z0-9]+/)
      for (i = 1; i <= nw; i++) nset += w[i] == "set"
      if (!nset) {
        if (!word(l, verb)) next
        if (!infence) hit(7, "BIOS change outside a SET line; readings use Report/Read/Record")
        else pend[++npend] = FILENAME ":" FNR ": rule 7: BIOS change in a code fence that never closes"
        next
      }

      if (nset > 1 || $0 !~ /^- SET [^ ]+ = [^ #`]([^#`]*[^ #`])?(  # src: [a-z0-9][a-z0-9-]*(,[a-z0-9][a-z0-9-]*)*)?$/) {
        hit(1, "not a SET line: want - SET <key> = <value>  # src: <id>[,<id>]")
        next
      }
      key = $3
      val = $0
      sub(/^- SET [^ ]+ = /, "", val)
      sub(/  # src: .*/, "", val)
      if ($0 !~ /  # src: /) hit(2, "SET " key " has no # src: cite")
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
    END { flush(); exit bad }
  ' "$@"
}
