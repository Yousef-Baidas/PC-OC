#!/usr/bin/bash
set -euo pipefail
# Load scx_lavd through scx_loader; on any failure after the config is installed, undo and die.
# ADR 0001: root runs with a fixed PATH. Non-root (bats) keeps PATH so mock systemctl/sleep win.
[[ "$EUID" -ne 0 ]] || PATH=/usr/bin
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# shellcheck source=../lib/write.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/write.sh"

here="$(dirname "${BASH_SOURCE[0]}")"
rec="$(pc_oc_state)/os/scx_loader.enabled"
state="$(sysfs_path /sys/kernel/sched_ext/state)"
ops="$(sysfs_path /sys/kernel/sched_ext/root/ops)"

# stock enabled state, recorded on the first apply only
if [[ ! -e "$rec" ]]; then
  stock="$(systemctl is-enabled scx_loader || :)"
  [[ -n "$stock" ]] || die os "cannot read scx_loader enabled state"
  mkdir -p "$(dirname "$rec")" || die os "cannot create $(dirname "$rec")"
  printf '%s\n' "$stock" >"$rec" || die os "cannot write $rec"
fi

undo() {
  local rc=$?
  trap - EXIT
  if [[ "$rc" -ne 0 ]]; then
    bash "$here/revert.sh" || :
    printf 'pc-oc: os: scx_lavd did not load\n' >&2
    exit 1
  fi
}
trap undo EXIT

conf_dir="$(sysfs_path /etc/scx_loader)"
mkdir -p -- "$conf_dir" || die os "cannot create /etc/scx_loader"
file_install "$here/scx_loader.toml" /etc/scx_loader/config.toml
systemctl enable scx_loader
systemctl restart scx_loader

# state=enabled alone is not enough: a fallback or another scheduler must fail
loaded=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if [[ "$(cat -- "$state" 2>/dev/null || :)" == enabled && "$(cat -- "$ops" 2>/dev/null || :)" == lavd* ]]; then
    loaded=1
    break
  fi
  sleep 1
done
[[ -n "$loaded" ]] || exit 1
