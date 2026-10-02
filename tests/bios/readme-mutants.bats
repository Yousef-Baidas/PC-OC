#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

# readme.bats must go red, on the one case that owns the rule, for each broken
# copy of the guide in fixtures/readme/, and stay green on good.md. Each case
# runs readme.bats through README_ROOT and README_FILE: the guide is the
# fixture, the tree is a fake one built from fixtures/readme/tree.txt (every
# path an empty file, a directory when it ends in `/`) plus this repo's pc-oc,
# so the cases hold whatever the real tree has merged. The pending skips of
# readme.bats are dropped from the copy that runs here.

setup_file() {
  local d="$BATS_TEST_DIRNAME/fixtures/readme"
  echo "# $d bytes=$(cat "$d"/*.md | wc -c) guides=$(find "$d" -name '*.md' | wc -l) tree-paths=$(grep -c . "$d/tree.txt")" >&3
}

setup() {
  local p
  FIX="$BATS_TEST_DIRNAME/fixtures/readme"
  TREE="$BATS_TEST_TMPDIR/tree"
  mkdir "$TREE"
  while read -r p; do
    if [[ "$p" == */ ]]; then
      mkdir -p "$TREE/$p"
    else
      mkdir -p "$TREE/$(dirname "$p")"
      : >"$TREE/$p"
    fi
  done <"$FIX/tree.txt"
  cp "$BATS_TEST_DIRNAME/../../pc-oc" "$TREE/pc-oc"
  sed '/^  skip "contract #146 pending"$/d' "$BATS_TEST_DIRNAME/readme.bats" >"$BATS_TEST_TMPDIR/readme.bats"
  CASES="$(grep -c '^@test ' "$BATS_TEST_TMPDIR/readme.bats")"
}

# run_readme <fixture>: readme.bats on fixtures/readme/<fixture>.md and the fake tree
run_readme() {
  README_ROOT="$TREE" README_FILE="$FIX/$1.md" run -- bats "$BATS_TEST_TMPDIR/readme.bats"
  echo "$output"
  ! grep -q '# skip' <<<"$output"
}

# only_red <fixture> <case> <finding>: that case of readme.bats fails with that finding, every other passes
only_red() {
  local failed
  run_readme "$1"
  failed="$(grep '^not ok ' <<<"$output" | sed -E 's/^not ok [0-9]+ //')"
  echo "failed: $failed"
  [ "$failed" = "README.md $2" ]
  [ "$(grep -c '^ok ' <<<"$output")" -eq "$((CASES - 1))" ]
  [[ "$output" == *"$3"* ]]
}

@test "readme.bats stays green on good.md" {
  run_readme good
  [ "$status" -eq 0 ]
  [ "$(grep -c '^ok ' <<<"$output")" -eq "$CASES" ]
}

@test "readme.bats goes red on a non-ASCII dash" {
  only_red non-ascii-dash "is ASCII only" "a byte outside printable ASCII"
}

@test "readme.bats goes red on a section with another title" {
  only_red section-title "has the eleven sections, numbered and titled, in order" \
    'heading 5 is "## 5. Memory", want "## 5. RAM"'
}

@test "readme.bats goes red on section 4 placed before section 3" {
  only_red section-order "has the eleven sections, numbered and titled, in order" \
    'heading 3 is "## 4. Undervolt", want "## 3. BIOS power limits"'
}

@test "readme.bats goes red on a section without If it fails:" {
  only_red no-if-it-fails "sections 2 to 9 each have the four fields" \
    'section 4 has no line "- If it fails: <text>"'
}

@test "readme.bats goes red on a Do: line without a link or a command" {
  only_red do-plain "sections 2 to 9 each have the four fields" \
    "this Do line holds no link and no command in backticks"
}

@test "readme.bats goes red on an If it fails: line without a link" {
  only_red fails-no-link "sections 2 to 9 each have the four fields" \
    "this If it fails line holds no link"
}

@test "readme.bats goes red on a path in backticks that does not exist" {
  only_red missing-path "names only repo paths that exist in the tree" \
    "no such path in the tree: bench/compiles.sh"
}

@test "readme.bats goes red on a link target that does not exist" {
  only_red missing-link "names only repo paths that exist in the tree" \
    "no such path in the tree: bios/memory.md"
}

@test "readme.bats goes red on pc-oc search cpu" {
  only_red search-cpu "names only pc-oc commands the entry point accepts" \
    "pc-oc search cpu: the entry point takes"
}

@test "readme.bats goes red on pc-oc apply cpu, which has no script in the tree" {
  only_red apply-cpu "names only pc-oc commands the entry point accepts" \
    "pc-oc apply cpu: no cpu/apply.sh in the tree"
}

@test "readme.bats goes red on apply toolchain moved above bench/run.sh" {
  only_red toolchain-early "keeps the commands in the order of the pass" \
    '"apply toolchain" is not after the first "bench/run.sh"'
}

@test "readme.bats goes red on search gpu after the last apply gpu" {
  only_red search-last "keeps the commands in the order of the pass" \
    'section 6: "search gpu" is not before the last "apply gpu"'
}

@test "readme.bats goes red on bench/report.sh named before bench/run.sh" {
  only_red report-early "keeps the commands in the order of the pass" \
    '"bench/report.sh" is not after the first "bench/run.sh"'
}

@test "readme.bats goes red on a line set 219 W" {
  only_red tuning-value "has no number followed by a tuning unit" \
    "a number with a tuning unit: set 219 W"
}

@test "readme.bats goes red without the no-update line" {
  only_red no-update-line "section 1 has the no-update line" "section 1 lacks the line: Do not update the system"
}

@test "readme.bats goes red on an undo section without revert all" {
  only_red no-revert-all "section 11 names revert all by the installed path" \
    "section 11 lacks the command: sudo /usr/local/lib/pc-oc/pc-oc revert all"
}

@test "readme.bats goes red on revert all without the installed path" {
  only_red revert-all-bare "section 11 names revert all by the installed path" \
    "section 11 lacks the command: sudo /usr/local/lib/pc-oc/pc-oc revert all"
}

@test "every broken copy is good.md with one edit, and has a case here" {
  local f name hunks
  for f in "$FIX"/*.md; do
    name="$(basename "$f" .md)"
    [ "$name" != good ] || continue
    hunks="$(diff "$FIX/good.md" "$f" | grep -c '^[0-9]' || true)"
    echo "$name: hunks=$hunks"
    # a moved line is two hunks
    [ "$hunks" -ge 1 ]
    [ "$hunks" -le 2 ]
    grep -q -E "^  only_red $name " "$BATS_TEST_FILENAME"
  done
}
