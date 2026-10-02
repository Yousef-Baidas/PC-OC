#!/usr/bin/env bash
# pc-oc-test-mock
# Recording stub for gpu/nvml.py in the #127 contract. gpu_tree (helper.bash) copies it to
# <tree>/gpu/nvml.py; the python3 mock in this directory runs it, so it is Bash and never
# loads NVML. Same interface as the helper (#123): get | set core|mem <mhz> | zero, exit 2
# on anything else.
# Every call is appended to $MOCK_STATE/order as "nvml <args>". The offsets it holds are
# in $MOCK_STATE/offsets ("<core> <mem>"); get prints them, or $MOCK_STATE/get when that
# file exists.
# MOCK_NVML: "<call>=<action>" entries joined by ";", <call> one of get, zero, set core,
# set mem. Actions:
#   fail            print one line, exit 1, write nothing
#   late            the call does its work and prints its rows, then exits 1
#   kill            set only: the offset lands, then SIGKILL to itself (the caller sees 137)
#   term, hup, int  the call succeeds, then that signal goes to the running gpu/apply.sh
set -euo pipefail

usage() {
  echo "pc-oc: gpu: nvml: usage: nvml.py get | set core|mem <mhz> | zero" >&2
  exit 2
}

printf 'nvml %s\n' "$*" >>"$MOCK_STATE/order"
case "$*" in
  get | zero) call="$1" ;;
  "set core "* | "set mem "*)
    [[ $# -eq 3 && "$3" =~ ^(0|[1-9][0-9]{0,3})$ ]] || usage
    call="set $2"
    ;;
  *) usage ;;
esac

action=""
IFS=';' read -r -a plan <<<"${MOCK_NVML:-}"
for entry in "${plan[@]}"; do
  [[ "${entry%%=*}" != "$call" ]] || action="${entry#*=}"
done

if [[ "$action" == fail ]]; then
  # no clock name in this line: the caller's own message has to name what failed
  echo "pc-oc: gpu: nvml: stub: refused" >&2
  exit 1
fi

read -r core mem <"$MOCK_STATE/offsets"

# rows <clock> <mhz>: the helper's three lines for one clock (ranges as probed, #111)
rows() {
  local pstate range="min=-1000 max=1000"
  [[ "$1" == core ]] || range="min=-2000 max=6000"
  for pstate in 0 1 2; do
    printf 'p%s.%s offset=%s %s\n' "$pstate" "$1" "$2" "$range"
  done
}

case "$call" in
  get)
    if [[ -e "$MOCK_STATE/get" ]]; then
      cat "$MOCK_STATE/get"
    else
      paste -d '\n' <(rows core "$core") <(rows mem "$mem")
    fi
    ;;
  zero) printf '0 0\n' >"$MOCK_STATE/offsets" ;;
  "set core")
    printf '%s %s\n' "$3" "$mem" >"$MOCK_STATE/offsets"
    [[ "$action" == kill ]] || rows core "$3"
    ;;
  "set mem")
    printf '%s %s\n' "$core" "$3" >"$MOCK_STATE/offsets"
    [[ "$action" == kill ]] || rows mem "$3"
    ;;
esac

case "$action" in
  "") ;;
  kill) kill -KILL "$$" ;;
  late) exit 1 ;;
  term | hup | int)
    # shellcheck source=signal.bash
    source "$MOCK_DIR/signal.bash"
    signal_apply "${action^^}"
    ;;
  *)
    echo "nvml stub: unknown action in MOCK_NVML: $action" >&2
    exit 94
    ;;
esac
