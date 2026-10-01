#!/usr/bin/env bash
set -euo pipefail
# report.sh <results dir> [<compare dir>]: write reports/<label>.md from a results dir.
# A value is the text after the first "=". source= and input.* lines are headers: they
# go in the inputs block, never in a table. With a compare dir, results gain a delta
# column (absolute and %), new minus compare.
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || die bench "cannot resolve repo root"
FILES=(settings.txt compile.txt stability.txt game.txt)

usage() {
  echo "pc-oc: bench: usage: report.sh <results dir> [<compare dir>]" >&2
  exit 2
}

# check_dir <dir>: die unless <dir> holds the four result files
check_dir() {
  local f
  [ -d "$1" ] || die bench "not a directory: $1"
  for f in "${FILES[@]}"; do
    [ -r "$1/$f" ] || die bench "$1: missing $f"
  done
}

# delta <new> <old>: "<abs> <pct>" for two numbers, "- -" when either is not one
delta() {
  awk -v a="$1" -v b="$2" 'BEGIN {
    num = "^-?[0-9]+(\\.[0-9]+)?$"
    if (a !~ num || b !~ num) { print "- -"; exit }
    da = index(a, ".") ? length(a) - index(a, ".") : 0
    db = index(b, ".") ? length(b) - index(b, ".") : 0
    d = da > db ? da : db; if (d < 1) d = 1
    abs = sprintf("%+." d "f", a - b)
    pct = b == 0 ? "-" : sprintf("%+.1f%%", (a - b) / b * 100)
    print abs, pct
  }'
}

[ "$#" -ge 1 ] && [ "$#" -le 2 ] || usage
check_dir "$1"
dir="$(cd "$1" && pwd)" || die bench "cannot resolve $1"
name="${dir##*/}"
date_txt="unknown"
label="$name"
if [[ "$name" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2})-(.+)$ ]]; then
  date_txt="${BASH_REMATCH[1]}"
  label="${BASH_REMATCH[2]}"
fi

declare -A base=()
base_name=""
if [ "$#" -eq 2 ]; then
  check_dir "$2"
  base_name="$(cd "$2" && pwd)" || die bench "cannot resolve $2"
  base_name="${base_name##*/}"
  for f in "${FILES[@]}"; do
    while IFS= read -r line || [ -n "$line" ]; do
      if [[ "$line" == result.* ]]; then
        base["${line%%=*}"]="${line#*=}"
      fi
    done <"$2/$f"
  done
fi

headers="" settings="" results=""
nres=0
for f in "${FILES[@]}"; do
  while IFS= read -r line || [ -n "$line" ]; do
    key="${line%%=*}"
    val="${line#*=}"
    if [[ "$line" == source=* || "$line" == input.* ]]; then
      headers+="$line"$'\n'
    elif [[ "$key" == result.* ]]; then
      nres=$((nres + 1))
      if [ -z "$base_name" ]; then
        results+="| $key | $val |"$'\n'
      elif [ -n "${base[$key]+x}" ]; then
        read -r abs pct < <(delta "$val" "${base[$key]}")
        results+="| $key | $val | ${base[$key]} | $abs | $pct |"$'\n'
      else
        results+="| $key | $val | n/a | - | - |"$'\n'
      fi
    elif [[ "$key" =~ ^[a-z0-9_]+\.[a-z0-9_.]+$ ]]; then
      settings+="| $key | $val |"$'\n'
    fi
  done <"$dir/$f"
done
[ "$nres" -ge 1 ] || die bench "$dir: no result.* lines"

mkdir -p "$ROOT/reports" || die bench "cannot create $ROOT/reports"
out="$ROOT/reports/$label.md"
tmp="$(mktemp "$ROOT/reports/.tmp.XXXXXX")" || die bench "mktemp failed in $ROOT/reports"
trap 'rm -f "$tmp"' EXIT
{
  printf '# %s\n\nDate: %s\n\nResults dir: %s\n' "$label" "$date_txt" "$name"
  printf '\n## Results\n\n'
  if [ -n "$base_name" ]; then
    printf 'Compared with %s; delta is this run minus that one.\n\n' "$base_name"
    printf '| key | value | compare | delta | delta %% |\n|---|---|---|---|---|\n'
  else
    printf '| key | value |\n|---|---|\n'
  fi
  printf '%s' "$results"
  printf '\n## Settings snapshot\n\n| key | value |\n|---|---|\n%s' "$settings"
  fence='```'
  printf '\n## Inputs\n\n%s\n%s%s\n' "$fence" "$headers" "$fence"
} >"$tmp" || die bench "cannot write $tmp"
mv "$tmp" "$out" || die bench "cannot write $out"
echo "pc-oc: bench: wrote $out"
