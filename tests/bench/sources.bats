#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

# The manifest and citation check for #27. SOURCES_MANIFEST and SOURCES_ROOT
# repoint the repo-level cases at a fixture, to watch them go red.

setup_file() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  M="${SOURCES_MANIFEST:-$ROOT/sources/manifest.tsv}"
  printf '%s %s %s rows\n' "$M" "$(wc -c <"$M")B" "$(($(wc -l <"$M") - 1))" >&3
}

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  FIX="$BATS_TEST_DIRNAME/fixtures/sources"
  M="${SOURCES_MANIFEST:-$ROOT/sources/manifest.tsv}"
  SCAN_ROOT="${SOURCES_ROOT:-$ROOT}"
}

# manifest_errors FILE: one line per problem on stdout, status 1 if any
# (a failing run of the real manifest prints them in the bats log)
manifest_errors() {
  awk -F'\t' '
    NR == 1 { if ($0 != "id\ttitle\turl\trevision") print "bad header: " $0; next }
    NF != 4 { print "line " NR ": want 4 fields, got " NF; next }
    $1 !~ /^[a-z0-9][a-z0-9-]*$/ { print "line " NR ": bad id " $1 }
    seen[$1]++ { print "line " NR ": duplicate id " $1 }
    $3 !~ /^https:\/\// { print "line " NR ": non-https url for " $1 ": " $3 }
    END { if (NR < 1) print "empty manifest" }
  ' "$1" >"$BATS_TEST_TMPDIR/errors"
  cat "$BATS_TEST_TMPDIR/errors"
  [ ! -s "$BATS_TEST_TMPDIR/errors" ]
}

# cited_ids ROOT: every id after "# src:" under the scanned dirs, one per line
cited_ids() {
  local d dirs=()
  for d in cpu ram gpu os toolchain lib bench; do
    [ -d "$1/$d" ] && dirs+=("$1/$d")
  done
  [ "${#dirs[@]}" -gt 0 ] || return 0
  grep -rhoE '# src:[ a-z0-9,-]*' "${dirs[@]}" | sed 's/^# src://' | tr ',' '\n' | tr -d ' ' | grep -v '^$' | sort -u || true
}

# unresolved_ids ROOT MANIFEST: cited ids missing from the manifest
unresolved_ids() {
  cited_ids "$1" | grep -vxFf <(cut -f1 "$2" | tail -n +2) || true
}

# craft_ids: ids in the Sources tables of the os and gpu CRAFT docs
craft_ids() {
  local f
  for f in "$ROOT/teams/os/CRAFT.md" "$ROOT/teams/gpu/CRAFT.md"; do
    awk -F'|' '
      /^## / { in_src = ($0 ~ /^## Sources/); next }
      in_src && /^\| / { id = $2; gsub(/^ +| +$/, "", id); if (id != "id" && id !~ /^-+$/) print id }
    ' "$f"
  done | sort -u
}

@test "manifest parses: header, unique ids, https urls" {
  run manifest_errors "$M"
  [ "$status" -eq 0 ] || {
    echo "$output" >&2
    return 1
  }
}

@test "manifest holds every id in the os and gpu CRAFT Sources tables" {
  missing="$(craft_ids | grep -vxFf <(cut -f1 "$M" | tail -n +2) || true)"
  [ -z "$missing" ] || {
    echo "ids missing from manifest: $missing" >&2
    return 1
  }
}

@test "every # src: id cited in the repo resolves in the manifest" {
  unresolved="$(unresolved_ids "$SCAN_ROOT" "$M")"
  [ -z "$unresolved" ] || {
    echo "unknown source ids: $unresolved" >&2
    return 1
  }
}

@test "red: duplicate id in manifest fails and names the id" {
  run -1 manifest_errors "$FIX/dup-id.tsv"
  [[ "$output" == *"duplicate id k-one"* ]]
}

@test "red: http url in manifest fails and names the id" {
  run -1 manifest_errors "$FIX/http-url.tsv"
  [[ "$output" == *"non-https url for k-three"* ]]
}

@test "red: script citing an unknown id fails and names the id" {
  run unresolved_ids "$FIX/unknown-cite" "$FIX/good.tsv"
  [ "$output" = "k-nope" ]
}

@test "good fixtures are accepted" {
  run manifest_errors "$FIX/good.tsv"
  [ "$status" -eq 0 ]
  run unresolved_ids "$FIX/known-cite" "$FIX/good.tsv"
  [ -z "$output" ]
}

# cpu_ram_errors FILE: one line per cpu-ram id that is missing, repeated, or has
# a non-https url or an empty or `same` revision; status 1 if any (#71)
cpu_ram_errors() {
  local id
  for id in gb-bios700 intel-14-pl intel-ll intel-sdm-perfstatus kernel-rapl \
    kernel-spd5118 jep106 kingston-kf556c40 ddr5-vdd; do
    awk -F'\t' -v id="$id" '
      $1 == id { n++; url = $3; rev = $4 }
      END {
        if (n != 1) print id ": " n + 0 " rows, want 1"
        else if (url !~ /^https:\/\//) print id ": non-https url " url
        else if (rev == "" || rev == "same") print id ": bad revision \"" rev "\""
      }
    ' "$1"
  done >"$BATS_TEST_TMPDIR/errors"
  cat "$BATS_TEST_TMPDIR/errors"
  [ ! -s "$BATS_TEST_TMPDIR/errors" ]
}

@test "cpu-ram ids present" {
  run cpu_ram_errors "$M"
  [ "$status" -eq 0 ] || {
    echo "$output" >&2
    return 1
  }
}
