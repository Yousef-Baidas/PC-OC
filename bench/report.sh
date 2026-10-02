#!/usr/bin/env bash
set -euo pipefail
# report.sh <results dir> [<compare dir>]: write reports/<label>.md from a results dir.
# A value is the text after the first "=". source= and input.* lines are headers: they
# go in the inputs block, never in a table. With a compare dir, results gain a delta
# column (absolute and %), new minus compare, plus a "Settings changed" table (keys whose
# value differs, "n/a" on the side that lacks the key) and a "Comparability" section over
# the fixed axes. A differing fixed axis is named on stderr and the report is still
# written, then the exit status is 3. A "|" in a value is escaped as "\|" in those tables.
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || die bench "cannot resolve repo root"
FILES=(settings.txt compile.txt stability.txt game.txt)
AXES=(cpu.model cpu.microcode gpu.name gpu.driver gpu.vbios os.kernel)
SETKEY='^[a-z0-9_]+\.[a-z0-9_.]+$'

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

declare -A base=() bset=() nset=()
bkeys=() nkeys=()
base_name=""
if [ "$#" -eq 2 ]; then
  check_dir "$2"
  base_name="$(cd "$2" && pwd)" || die bench "cannot resolve $2"
  base_name="${base_name##*/}"
  for f in "${FILES[@]}"; do
    while IFS= read -r line || [ -n "$line" ]; do
      if [[ "$line" == result.* ]]; then
        base["${line%%=*}"]="${line#*=}"
      elif [[ "$line" != source=* && "$line" != input.* && "${line%%=*}" =~ $SETKEY ]]; then
        [ -n "${bset[${line%%=*}]+x}" ] || bkeys+=("${line%%=*}")
        bset["${line%%=*}"]="${line#*=}"
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
    elif [[ "$key" =~ $SETKEY ]]; then
      settings+="| $key | $val |"$'\n'
      [ -n "${nset[$key]+x}" ] || nkeys+=("$key")
      nset["$key"]="$val"
    fi
  done <"$dir/$f"
done
[ "$nres" -ge 1 ] || die bench "$dir: no result.* lines"

changed="" differ=() same=() notcomp=""
if [ -n "$base_name" ]; then
  for key in "${nkeys[@]}"; do
    if [ -z "${bset[$key]+x}" ]; then
      nv="${nset[$key]//|/\\|}"
      changed+="| $key | $nv | n/a |"$'\n'
    elif [ "${nset[$key]}" != "${bset[$key]}" ]; then
      nv="${nset[$key]//|/\\|}" bv="${bset[$key]//|/\\|}"
      changed+="| $key | $nv | $bv |"$'\n'
    fi
  done
  for key in "${bkeys[@]}"; do
    if [ -z "${nset[$key]+x}" ]; then
      bv="${bset[$key]//|/\\|}"
      changed+="| $key | n/a | $bv |"$'\n'
    fi
  done
  for key in "${AXES[@]}"; do
    nv="${nset[$key]-n/a}" bv="${bset[$key]-n/a}"
    if [ "$nv" = "$bv" ]; then
      same+=("$key")
    else
      differ+=("$key")
      notcomp+="NOT COMPARABLE on $key: $bv -> $nv"$'\n'
    fi
  done
fi

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
  if [ -n "$base_name" ]; then
    printf '\n## Settings changed\n\n'
    if [ -n "$changed" ]; then
      printf '| key | value | compare |\n|---|---|---|\n%s' "$changed"
    else
      printf 'none\n'
    fi
    printf '\n## Comparability\n\n%s' "$notcomp"
    if [ "${#same[@]}" -gt 0 ]; then
      printf 'Same on: %s' "${same[0]}"
      printf ', %s' "${same[@]:1}"
      printf '\n'
    fi
  fi
  printf '\n## Settings snapshot\n\n| key | value |\n|---|---|\n%s' "$settings"
  fence='```'
  printf '\n## Inputs\n\n%s\n%s%s\n' "$fence" "$headers" "$fence"
} >"$tmp" || die bench "cannot write $tmp"
mv "$tmp" "$out" || die bench "cannot write $out"
echo "pc-oc: bench: wrote $out"
for key in "${differ[@]}"; do
  echo "pc-oc: bench: fixed axis differs: $key" >&2
done
[ "${#differ[@]}" -eq 0 ] || exit 3
