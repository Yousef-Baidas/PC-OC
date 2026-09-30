#!/usr/bin/env bash
set -euo pipefail
# game.sh setup | parse <csv>...: Cyberpunk 2077 MangoHud logs to avg and 1% low FPS.
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

# Sources:
# - MangoHud README (github.com/flightlessmango/MangoHud): output_folder,
#   autostart_log, log_duration, no_display, toggle_logging.
# - MangoHud v0.8.x src/logging.cpp: the CSV is a "v1" line, the MangoHud version,
#   a SYSTEM INFO block, a FRAME METRICS block, then a fps,frametime,... header and
#   one row per frame; frametime is in ms.
# - MangoHud v0.8.x src/logging.cpp calculate_benchmark_data: frametimes sorted
#   slowest first, 1% low is the frametime at index 0.01 * n - 1, as fps.
# - Cyberpunk 2077: the benchmark is started from Settings > Graphics > Run
#   Benchmark; no launch option starts it.

APP_ID=1091500
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/pc-oc/mangohud"
LOW1_DEF="MangoHud: frametime at index 0.01*n-1 of frametimes sorted slowest first, as fps"

usage() {
  echo "usage: game.sh setup | parse <csv>..." >&2
  exit 2
}

setup() {
  mkdir -p "$LOG_DIR"
  cat <<TXT
input.log_dir=$LOG_DIR
Steam launch options for Cyberpunk 2077 (app $APP_ID, /mnt/games/SteamLibrary):
  MANGOHUD_CONFIGFILE=$ROOT/bench/mangohud.conf MANGOHUD_CONFIG=output_folder=$LOG_DIR mangohud %command%
In game: Settings > Graphics > Run Benchmark. Press Shift_L+F2 when the benchmark starts and again when it ends
one log per run; do 3 runs, then:
  $ROOT/bench/game.sh parse $LOG_DIR/*.csv
TXT
}

# parse_one <n> <csv>: print "<frames> <avg_fps> <low1_fps> <version>" for one log.
parse_one() {
  awk -F, '
    NR == 2 { ver = $0 }
    body && NF >= 2 && $2 + 0 > 0 { n++; ft[n] = $2 + 0; sum += $2 }
    $1 == "fps" && $2 == "frametime" { body = 1 }
    END {
      if (n == 0) exit 3
      for (i = 1; i <= n; i++) idx[i] = i
      # sort slowest first (insertion sort on ft)
      for (i = 2; i <= n; i++) {
        v = ft[i]; j = i - 1
        while (j >= 1 && ft[j] < v) { ft[j + 1] = ft[j]; j-- }
        ft[j + 1] = v
      }
      k = int(0.01 * n - 1); if (k < 0) k = 0
      printf "%d %.6f %.6f %s\n", n, 1000 * n / sum, 1000 / ft[k + 1], ver
    }' "$1"
}

parse() {
  [ "$#" -ge 1 ] || usage
  local f src="" bytes=0 items=0 run=0 ver="" res n avg low v
  local sum_avg=0 sum_low=0 out=""
  for f in "$@"; do
    [ -r "$f" ] || die bench "cannot read $f"
    src+="${src:+,}$(realpath "$f")"
    bytes=$((bytes + $(wc -c <"$f")))
    res="$(parse_one "$f")" || die bench "no frames in $f"
    read -r n avg low v <<<"$res"
    [ -z "$ver" ] && ver="$v"
    [ "$v" = "$ver" ] || die bench "mixed MangoHud versions: $ver and $v"
    items=$((items + n))
    run=$((run + 1))
    out+="$(printf 'result.game.run%d.avg_fps=%.1f\nresult.game.run%d.low1_fps=%.1f' "$run" "$avg" "$run" "$low")"$'\n'
    sum_avg="$(awk -v a="$sum_avg" -v b="$avg" 'BEGIN { printf "%.6f", a + b }')"
    sum_low="$(awk -v a="$sum_low" -v b="$low" 'BEGIN { printf "%.6f", a + b }')"
  done
  printf 'input.source=%s bytes=%d items=%d\n' "$src" "$bytes" "$items"
  printf 'input.mangohud=%s\ninput.files=%d\ninput.low1_definition=%s\n' "$ver" "$run" "$LOW1_DEF"
  printf '%s' "$out"
  awk -v a="$sum_avg" -v l="$sum_low" -v r="$run" \
    'BEGIN { printf "result.game.avg_fps=%.1f\nresult.game.low1_fps=%.1f\n", a / r, l / r }'
}

case "${1:-}" in
  setup) setup ;;
  parse)
    shift
    parse "$@"
    ;;
  *) usage ;;
esac
