# shellcheck shell=bash
# Runbook lint (#72), loaded by tests/bios/*.bats.

# bios_lint <menu-paths.tsv> [<runbook.md>...]: print one line per broken rule,
# `<runbook>:<line>: rule <n>: <what>`; exit 1 when any line printed, else 0
bios_lint() {
  local table="${1:-}" book out found=0
  shift || true
  [ -f "$table" ] || {
    echo "pc-oc: bios: menu-paths table not found: $table" >&2
    return 1
  }
  for book in "$@"; do
    [ -f "$book" ] || {
      echo "pc-oc: bios: runbook not found: $book" >&2
      return 1
    }
    out="$(awk -F'\t' -v book="$book" '
      FNR == NR { if (FNR > 1) known[$1] = 1; next }
      function say(n, what) { print book ":" FNR ": rule " n ": " what; bad = 1 }
      # plain value: digits with an optional decimal, then an optional alphabetic unit
      # sets num (in base units) or says rule n; returns 1 when usable
      function plain(n, key, val, u1, u2, f2,   unit) {
        if (!match(val, /^[0-9]+(\.[0-9]+)?/)) { say(n, key " value \"" val "\" is not a plain number"); return 0 }
        num = substr(val, 1, RLENGTH) + 0
        unit = tolower(substr(val, RLENGTH + 1)); sub(/^[ \t]+/, "", unit)
        if (unit == "" || unit == u1) return 1
        if (unit == u2) { num *= f2; return 1 }
        say(n, key " value \"" val "\" has an unexpected unit"); return 0
      }
      {
        low = tolower($0)
        # reading keys such as cpu.vcore, vcore_max_mv and "peak Vcore" are not knobs
        gsub(/[a-z0-9]*[_.]+[a-z0-9_.]*vcore[a-z0-9_.]*|[a-z0-9_.]*vcore[_.][a-z0-9][a-z0-9_.]*|peak vcore/, " ", low)
        if (low ~ /vcore|core voltage|dvid|adaptive|load-?line calibration|(^|[^a-z])llc([^a-z]|$)/ ||
            low ~ /(^|[^a-z])ratio([^a-z]|$)|multipl(ier|y)|cpu upgrade|enhanced multi-core/ ||
            low ~ /bclk|(base|host|reference|ref|cpu) clock|vdd2|system agent|vccsa|vcc ?sa([^a-z]|$)/)
          say(3, "forbidden knob (Vcore, DVID, LLC, ratio, clock, VDD2, System Agent)")
      }
      match(tolower($0), /(^|[^a-z0-9_])set[ \t]+[a-z0-9_]+\.[a-z0-9_.]+/) {
        s = substr($0, RSTART); sub(/^[^Ss]?[Ss][Ee][Tt][ \t]+/, "", s)
        key = s; sub(/[ \t=].*/, "", key)
        if (!(key in known)) say(1, "SET key " key " has no row in menu-paths.tsv")
        if (s !~ /^[^ \t=]+[ \t]*=/) { say(1, "malformed SET line, want: - SET <key> = <value> [<unit>]  # src: <id>"); next }
        val = s; sub(/^[^=]*=[ \t]*/, "", val)
        if (val !~ /#[ \t]*src:[ \t]*[^ \t]/) say(2, "SET " key " has no # src: cite")
        sub(/[ \t]*#.*/, "", val); sub(/[ \t]+$/, "", val)
        if (key == "mem.vdd" || key == "mem.vddq") {
          if (plain(4, key, val, "v", "mv", 0.001) && num > 1.35 + 1e-9) say(4, key " " val " is above 1.35 V")
        } else if (key == "cpu.pl1" || key == "cpu.pl2") {
          if (plain(5, key, val, "w", "w", 1) && num > 219 + 1e-9) say(5, key " " val " is above 219 W")
        } else if (key == "cpu.ac_ll") {
          if (plain(6, key, val, "mohm", "mΩ", 1)) {
            if (!seen && num > 1.1 + 1e-9) say(6, "cpu.ac_ll " val " is above stock 1.1 mOhm (intel-14-pl Table 77, p191)")
            else if (seen && num > prev + 1e-9) say(6, "cpu.ac_ll " val " is above the previous " prev " (loadline only goes down)")
            prev = num; seen = 1
          }
        }
      }
      END { exit bad }
    ' "$table" "$book")" || found=1
    [ -z "$out" ] || printf '%s\n' "$out"
  done
  return "$found"
}
