#!/usr/bin/env bash
set -euo pipefail
# run.sh <label>: run the bench kit into results/<UTC date>-<label>/.
# The MangoHud logs are the ones game.sh setup told the human to record, in
# $XDG_DATA_HOME/pc-oc/mangohud/<label>/ (default ~/.local/share).
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || die bench "cannot resolve repo root"

usage() {
  echo "pc-oc: bench: usage: run.sh <label>" >&2
  exit 2
}

[ "$#" -eq 1 ] || usage
label="$1"
[[ "$label" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] || usage

logs_dir="${XDG_DATA_HOME:-$HOME/.local/share}/pc-oc/mangohud/$label"
logs=()
if [ -d "$logs_dir" ]; then
  for f in "$logs_dir"/*.csv; do
    [ -e "$f" ] && logs+=("$f")
  done
fi
[ "${#logs[@]}" -ge 1 ] || die bench "no MangoHud logs in $logs_dir (record them: game.sh setup)"

dest="$ROOT/results/$(date -u +%F)-$label"
mkdir -p "$ROOT/results" || die bench "cannot create $ROOT/results"
# plain mkdir fails on an existing dir, so a finished run is never overwritten
mkdir "$dest" 2>/dev/null || die bench "cannot create $dest (exists?); refusing to overwrite"
done_ok=""
# a failed run must leave no results dir that looks complete
trap '[ -n "$done_ok" ] || rm -rf "$dest"' EXIT

log_bytes="$(cat "${logs[@]}" | wc -c)" || die bench "cannot read MangoHud logs in $logs_dir"
input_line "$logs_dir" "$log_bytes" "${#logs[@]}"

"$ROOT/pc-oc" probe all >"$dest/settings.txt" || die bench "pc-oc probe all failed"
"$ROOT/bench/compile.sh" >"$dest/compile.txt" || die bench "compile.sh failed"
"$ROOT/bench/stability.sh" cpu >"$dest/stability.txt" || die bench "stability.sh cpu failed"
copied=()
for f in "${logs[@]}"; do
  cp "$f" "$dest/" || die bench "cannot copy $f"
  copied+=("$dest/${f##*/}")
done
"$ROOT/bench/game.sh" parse "${copied[@]}" >"$dest/game.txt" || die bench "game.sh parse failed"

done_ok=1
echo "pc-oc: bench: wrote $dest"
