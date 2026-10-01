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
      {
        low = tolower($0)
        if (low ~ /(vcore|core voltage).*(override|offset|adaptive)/ ||
            low ~ /(override|offset|adaptive).*(vcore|core voltage)/ ||
            low ~ /adaptive (mode )?voltage/ ||
            low ~ /(^|[^a-z])ratio([^a-z]|$)/ || low ~ /multipl(ier|y)/ ||
            low ~ /bclk|base clock|vdd2|system agent|vccsa/)
          say(3, "forbidden knob (Vcore, ratio, BCLK, VDD2, System Agent)")
      }
      /^[ \t]*-[ \t]+SET[ \t]/ {
        s = $0; sub(/^[ \t]*-[ \t]+SET[ \t]+/, "", s)
        key = s; sub(/[ \t=].*/, "", key)
        val = s; sub(/^[^=]*=[ \t]*/, "", val)
        if (val !~ /#[ \t]*src:[ \t]*[^ \t]/) say(2, "SET " key " has no # src: cite")
        sub(/[ \t]*#.*/, "", val)
        num = (val ~ /^[0-9.]/) ? val + 0 : -1
        if (!(key in known)) say(1, "SET key " key " has no row in menu-paths.tsv")
        if ((key == "mem.vdd" || key == "mem.vddq") && num > 1.35)
          say(4, key " " val " is above 1.35 V")
        if ((key == "cpu.pl1" || key == "cpu.pl2") && num > 219)
          say(5, key " " val " is above 219 W")
        if (key == "cpu.ac_ll" && num >= 0) {
          if (seen && num > prev) say(6, "cpu.ac_ll " val " is above the previous " prev " (loadline only goes down)")
          prev = num; seen = 1
        }
      }
      END { exit bad }
    ' "$table" "$book")" || found=1
    [ -z "$out" ] || printf '%s\n' "$out"
  done
  return "$found"
}
