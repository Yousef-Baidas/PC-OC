#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

# Text rules on the final-pass guide (#146), one case per rule. Two inputs:
#   README_ROOT  the tree the guide's paths and commands are checked against
#   README_FILE  the guide, default $README_ROOT/README.md
# readme-mutants.bats runs this file on the copies in fixtures/readme/ through
# both. A rule prints one finding per line, `<guide>:<line>: <what>`, and its
# case is red when it printed one. No case passes on an empty guide.
#
# A section is the lines under a heading `## <n>. ` up to the next line that
# starts with `##` and no third `#`. "Before" compares positions in the text:
# the line number, then the column.

# the second-level headings of the guide are exactly these, numbered from 1
SECTIONS=(
  'Before you start'
  'Install the reviewed scripts'
  'BIOS power limits'
  'Undervolt'
  'RAM'
  'GPU clocks'
  'Benchmark the tuned state'
  'Report'
  'Toolchain wiring'
  'What to send back'
  'Undo everything'
)
# sections 2 to 9 each hold a line `- <field>: <text>`, at the line start
FIELDS=('Time' 'Do' 'See' 'If it fails')
# section 1 holds this sentence on one line, with no markup inside it
NO_UPDATE='Do not update the system (pacman -Syu, yay) between the baseline and the final report'
# section 11 holds this command on one line
REVERT_ALL='sudo /usr/local/lib/pc-oc/pc-oc revert all'
LINK='\[[^]]+\]\([^) ]+\)'
CODE="\`[^\`]+\`"

setup_file() {
  export README_ROOT="${README_ROOT:-$BATS_TEST_DIRNAME/../..}"
  export README_FILE="${README_FILE:-$README_ROOT/README.md}"
  if [ -f "$README_FILE" ]; then
    echo "# $README_FILE bytes=$(wc -c <"$README_FILE") lines=$(wc -l <"$README_FILE") tree=$README_ROOT" >&3
  else
    echo "# $README_FILE missing" >&3
  fi
}

# check <rule>: red when the guide is empty, or when the rule prints a finding
check() {
  local found
  echo "guide: $README_FILE, tree: $README_ROOT"
  if [ ! -s "$README_FILE" ]; then
    echo "$README_FILE: empty or missing"
    return 1
  fi
  found="$("$@")" || true
  echo "$found"
  [ -z "$found" ]
}

# section <n>: the lines of section <n> without its heading, as `<line>:<text>`
section() {
  awk -v want="$1" '
    /^##([^#]|$)/ {
      sec = match($0, /^## [0-9]+\. /) ? substr($0, 4, RLENGTH - 5) + 0 : 0
      next
    }
    sec == want { print FNR ":" $0 }
  ' "$README_FILE"
}

# at <what>: `<line>:<text>` lines to findings
at() {
  local n
  while IFS=: read -r n _; do
    echo "$README_FILE:$n: $1"
  done
}

# positions <fixed string>: on `<line>:<text>` lines, print the first and the last place the string
# stands, each as line * 100000 + column; nothing when it is not there
positions() {
  awk -v s="$1" '
    {
      n = $0
      sub(/:.*/, "", n)
      text = substr($0, length(n) + 2)
      off = 0
      while ((c = index(text, s)) > 0) {
        last = n * 100000 + off + c
        if (!first) first = last
        off += c
        text = substr(text, c + 1)
      }
    }
    END { if (first) print first, last }
  '
}

# every byte is printable ASCII (0x20 to 0x7E) or a line feed: no tab, no carriage return
rule_ascii() {
  LC_ALL=C awk '/[^ -~]/ { print FILENAME ":" FNR ": a byte outside printable ASCII" }' "$README_FILE"
}

# every line that starts with `##` and no third `#` is `## <n>. <SECTIONS[n]>`, n counting from 1 to 11
rule_sections() {
  awk -v titles="$(printf '%s\n' "${SECTIONS[@]}")" '
    BEGIN { n = split(titles, title, "\n") }
    /^##([^#]|$)/ {
      got++
      want = "## " got ". " title[got]
      if (got > n) print FILENAME ":" FNR ": a heading after section " n ": " $0
      else if ($0 != want) print FILENAME ":" FNR ": heading " got " is \"" $0 "\", want \"" want "\""
    }
    END { for (i = got + 1; i <= n; i++) print FILENAME ": no heading \"## " i ". " title[i] "\"" }
  ' "$README_FILE"
}

# sections 2 to 9: each of the four fields at least once; every Do line holds a markdown link or a
# backtick span, every If it fails line a markdown link
rule_fields() {
  local s f head body
  for s in 2 3 4 5 6 7 8 9; do
    head="$(grep -n -m1 "^## $s\. " "$README_FILE" | cut -d: -f1)"
    if [ -z "$head" ]; then
      echo "$README_FILE: no section $s"
      continue
    fi
    body="$(section "$s")"
    for f in "${FIELDS[@]}"; do
      grep -q -E "^[0-9]+:- $f: [^ ]" <<<"$body" ||
        echo "$README_FILE:$head: section $s has no line \"- $f: <text>\""
    done
    grep -E '^[0-9]+:- Do: ' <<<"$body" | grep -v -E "$LINK|$CODE" |
      at "this Do line holds no link and no command in backticks"
    grep -E '^[0-9]+:- If it fails: ' <<<"$body" | grep -v -E "$LINK" |
      at "this If it fails line holds no link"
  done
}

# paths: the repo paths the guide names, as `<line>\037<path>`. Named: a word of a backtick span or of a
# line inside a ``` fence that holds a `/` or ends in .md or .sh, and the target of a markdown link without
# its `#anchor`. Not a repo path: a word that starts with `/`, `~`, `$` or `-`, or holds `://`; a link
# target with a scheme (https:) or that is an anchor only.
paths() {
  awk '
    function word(w) {
      gsub(/^["\047(]+|["\047),;:]+$/, "", w)
      sub(/^\.\//, "", w)
      if (w == "" || w ~ /^[\/~$-]/ || w ~ /:\/\//) return
      if (w ~ /\// || w ~ /\.(md|sh)$/) print FNR "\037" w
    }
    function link(t) {
      if (t ~ /^[A-Za-z][A-Za-z0-9+.-]*:/) return
      sub(/#.*/, "", t)
      sub(/^\.\//, "", t)
      if (t != "") print FNR "\037" t
    }
    /^```/ {
      fence = !fence
      next
    }
    fence {
      n = split($0, w, /[ \t]+/)
      for (i = 1; i <= n; i++) word(w[i])
      next
    }
    {
      n = split($0, span, "`")
      for (i = 2; i <= n; i += 2) {
        m = split(span[i], w, /[ \t]+/)
        for (j = 1; j <= m; j++) word(w[j])
      }
      rest = $0
      while (match(rest, /\]\([^) \t]+\)/)) {
        link(substr(rest, RSTART + 2, RLENGTH - 3))
        rest = substr(rest, RSTART + RLENGTH)
      }
      if (match($0, /^\[[^]]+\]:[ \t]+[^ \t]+/)) {
        t = substr($0, 1, RLENGTH)
        sub(/^\[[^]]+\]:[ \t]+/, "", t)
        link(t)
      }
    }
  ' "$README_FILE"
}

# every named repo path exists under README_ROOT, and there is at least one. A path with a `<placeholder>`
# stands for a name only the pass knows: the directory before the placeholder must exist
rule_paths() {
  local n p lit count=0
  while IFS=$'\037' read -r n p; do
    count=$((count + 1))
    lit="$p"
    if [[ "$p" == *"<"* ]]; then
      lit="${p%%<*}"
      lit="${lit%"${lit##*/}"}"
    fi
    if [[ "/$p/" == */../* ]]; then
      echo "$README_FILE:$n: path leaves the tree: $p"
    elif [ ! -e "$README_ROOT/$lit" ]; then
      echo "$README_FILE:$n: no such path in the tree: $p"
    fi
  done < <(paths)
  [ "$count" -gt 0 ] || echo "$README_FILE: names no repo path"
}

# entry_point: read what README_ROOT/pc-oc accepts, from its `components=(...)` line and its usage line:
# verbs (take a component or all), components, single (`<verb>=<target>` forms such as search=gpu)
entry_point() {
  local line rest
  components="$(sed -n 's/^components=(\(.*\))$/\1/p' "$README_ROOT/pc-oc")"
  line="$(grep -m1 -F 'usage: pc-oc ' "$README_ROOT/pc-oc")"
  [[ "$line" =~ usage:\ pc-oc\ ([a-z|]+)\ \<component\>\|all(.*) ]] || return 1
  verbs="${BASH_REMATCH[1]//|/ }"
  rest="${BASH_REMATCH[2]}"
  single=""
  while [[ "$rest" =~ pc-oc\ ([a-z]+)\ ([a-z]+)(.*) ]]; do
    single+="${BASH_REMATCH[1]}=${BASH_REMATCH[2]} "
    rest="${BASH_REMATCH[3]}"
  done
  [ -n "$components" ] && [ -n "$verbs" ]
}

# commands: every `pc-oc`, or word ending in `/pc-oc`, that another word follows, as
# `<line>\037<code|prose>\037<word 1>\037<word 2>`; code is a backtick span or a line inside a ``` fence
commands() {
  awk '
    function scan(text, kind,    n, w, i, a, b) {
      n = split(text, w, /[ \t]+/)
      for (i = 1; i < n; i++) {
        if (w[i] != "pc-oc" && w[i] !~ /\/pc-oc$/) continue
        a = w[i + 1]
        b = i + 2 <= n ? w[i + 2] : ""
        if (kind == "prose") {
          sub(/[.,;:)]+$/, "", a)
          sub(/[.,;:)]+$/, "", b)
        }
        if (a != "") print FNR "\037" kind "\037" a "\037" b
      }
    }
    /^```/ {
      fence = !fence
      next
    }
    fence {
      scan($0, "code")
      next
    }
    {
      n = split($0, span, "`")
      for (i = 1; i <= n; i++) scan(span[i], i % 2 ? "prose" : "code")
    }
  ' "$README_FILE"
}

# every pc-oc command is `<verb> <component>` the entry point accepts and whose <component>/<verb>.sh is in
# the tree (pc-oc prints its usage without it), and there is at least one. In code every word pair after
# pc-oc counts; in prose only a pair that starts with a verb of the entry point
rule_commands() {
  local components verbs single n kind v t count=0
  if ! entry_point; then
    echo "$README_ROOT/pc-oc: cannot read the verbs and components"
    return
  fi
  while IFS=$'\037' read -r n kind v t; do
    if [ "$kind" = prose ] && [[ " $verbs $single" != *" $v"[\ =]* ]]; then
      continue
    fi
    count=$((count + 1))
    if [ -n "$t" ] && [[ " $single" == *" $v=$t "* ]]; then
      [ -f "$README_ROOT/$t/$v.sh" ] || echo "$README_FILE:$n: pc-oc $v $t: no $t/$v.sh in the tree"
    elif [ -n "$t" ] && [[ " $verbs " == *" $v "* && " $components all " == *" $t "* ]]; then
      [ "$t" = all ] || [ -f "$README_ROOT/$t/$v.sh" ] ||
        echo "$README_FILE:$n: pc-oc $v $t: no $t/$v.sh in the tree"
    else
      echo "$README_FILE:$n: pc-oc $v $t: the entry point takes ${verbs// /|} <${components// /|}>|all, ${single//=/ }"
    fi
  done < <(commands)
  [ "$count" -gt 0 ] || echo "$README_FILE: names no pc-oc command"
}

# in section 6 the first `search gpu` stands before the last `apply gpu`; in the whole guide the first
# `bench/run.sh` stands before the first `apply toolchain` and before the first `bench/report.sh`
rule_order() {
  local search="" apply="" run="" wire="" report="" all
  read -r search _ < <(section 6 | positions 'search gpu') || true
  read -r _ apply < <(section 6 | positions 'apply gpu') || true
  all="$(grep -n '' "$README_FILE")"
  read -r run _ < <(positions 'bench/run.sh' <<<"$all") || true
  read -r wire _ < <(positions 'apply toolchain' <<<"$all") || true
  read -r report _ < <(positions 'bench/report.sh' <<<"$all") || true

  if [ -z "$search" ] || [ -z "$apply" ]; then
    echo "$README_FILE: section 6 lacks \"search gpu\" or \"apply gpu\""
  elif [ "$search" -ge "$apply" ]; then
    echo "$README_FILE:$((search / 100000)): section 6: \"search gpu\" is not before the last \"apply gpu\" (line $((apply / 100000)))"
  fi
  if [ -z "$run" ]; then
    echo "$README_FILE: no \"bench/run.sh\""
    return
  fi
  if [ -z "$wire" ]; then
    echo "$README_FILE: no \"apply toolchain\""
  elif [ "$wire" -le "$run" ]; then
    echo "$README_FILE:$((wire / 100000)): \"apply toolchain\" is not after the first \"bench/run.sh\" (line $((run / 100000)))"
  fi
  if [ -z "$report" ]; then
    echo "$README_FILE: no \"bench/report.sh\""
  elif [ "$report" -le "$run" ]; then
    echo "$README_FILE:$((report / 100000)): \"bench/report.sh\" is not after the first \"bench/run.sh\" (line $((run / 100000)))"
  fi
}

# no digit followed, after optional spaces or tabs, by a tuning unit. The line is lowercased and loses
# its `*`, `~` and backticks first. Units, each as a whole word: mv, mohm, mhz, mt/s, w, v, watt(s),
# volt(s), millivolt(s), megahertz, milliohm(s). Not a unit here: `%` and percent, no tuning value of the
# pass is one and the game metric is named `1% low`
rule_units() {
  awk '
    {
      text = tolower($0)
      gsub(/[*~`]/, "", text)
      if (text ~ /[0-9][ \t]*(mv|mohm|mhz|mt\/s|w|v|watts?|volts?|millivolts?|megahertz|milliohms?)([^a-z0-9_]|$)/)
        print FILENAME ":" FNR ": a number with a tuning unit: " $0
    }
  ' "$README_FILE"
}

rule_no_update() {
  section 1 | grep -q -F -- "$NO_UPDATE" || echo "$README_FILE: section 1 lacks the line: $NO_UPDATE"
}

rule_undo() {
  section 11 | grep -q -F -- "$REVERT_ALL" || echo "$README_FILE: section 11 lacks the command: $REVERT_ALL"
}

@test "README.md is ASCII only" {
  skip "contract #146 pending"
  check rule_ascii
}

@test "README.md has the eleven sections, numbered and titled, in order" {
  skip "contract #146 pending"
  check rule_sections
}

@test "README.md sections 2 to 9 each have the four fields" {
  skip "contract #146 pending"
  check rule_fields
}

@test "README.md names only repo paths that exist in the tree" {
  skip "contract #146 pending"
  check rule_paths
}

@test "README.md names only pc-oc commands the entry point accepts" {
  skip "contract #146 pending"
  check rule_commands
}

@test "README.md keeps the commands in the order of the pass" {
  skip "contract #146 pending"
  check rule_order
}

@test "README.md has no number followed by a tuning unit" {
  skip "contract #146 pending"
  check rule_units
}

@test "README.md section 1 has the no-update line" {
  skip "contract #146 pending"
  check rule_no_update
}

@test "README.md section 11 names revert all by the installed path" {
  skip "contract #146 pending"
  check rule_undo
}
