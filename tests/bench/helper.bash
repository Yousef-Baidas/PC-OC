# shellcheck shell=bash disable=SC2154 # lines is set by bats run
# Shared helpers for tests/bench/*.bats.

# value <key>: print the value of stdout line <key>=
value() {
  local l
  for l in "${lines[@]}"; do
    [[ "$l" == "$1="* ]] && printf '%s\n' "${l#"$1="}" && return 0
  done
  return 1
}

# contract_order: stdout is input.* lines, then result.* lines, nothing else
contract_order() {
  local seen=0 l
  for l in "${lines[@]}"; do
    case "$l" in
      input.*=*) [ "$seen" -eq 0 ] || return 1 ;;
      result.*=*) seen=1 ;;
      *) return 1 ;;
    esac
  done
}
