# shellcheck shell=bash
# Sourced by the mocks of the #127 contract that stand in for a signal reaching
# gpu/apply.sh (systemd ends a start that outlives TimeoutStartSec with SIGTERM).

# signal_apply <TERM|HUP|INT>: send the signal to the gpu/apply.sh this mock runs under and
# note "<signal> <pid>" in $MOCK_STATE/signalled. The target is the outermost ancestor
# whose first argument ends in /gpu/apply.sh: a subshell of apply has the same command
# line and sits below it, while timeout or unshare above it carry the path further back.
# Exit 95 when no ancestor is an apply: the case then fails on the missing note, not on a
# signal nobody got.
signal_apply() {
  local pid="$PPID" target=""
  local -a argv
  while [[ "$pid" =~ ^[0-9]+$ && "$pid" -gt 1 ]]; do
    argv=()
    mapfile -d '' -t argv <"/proc/$pid/cmdline" || :
    [[ "${argv[1]:-}" != */gpu/apply.sh ]] || target="$pid"
    pid="$(/usr/bin/ps -o ppid= -p "$pid")" || break
    pid="${pid//[[:space:]]/}"
  done
  if [[ -z "$target" ]]; then
    echo "mock: no gpu/apply.sh among the ancestors, nothing to signal" >&2
    exit 95
  fi
  printf '%s %s\n' "$1" "$target" >>"$MOCK_STATE/signalled"
  kill -s "$1" "$target"
}
