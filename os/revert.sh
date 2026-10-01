#!/usr/bin/bash
set -euo pipefail
# Undo os/apply.sh: stop scx_loader, restore its config and enabled state, wait for stock sched_ext.
# Each step skips when already done and the records go last, so a failed revert can be rerun.
# ADR 0001: root runs with a fixed PATH. Non-root (bats) keeps PATH so mock systemctl/sleep win.
[[ "$EUID" -ne 0 ]] || PATH=/usr/bin
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# shellcheck source=../lib/write.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/write.sh"

rdir="$(pc_oc_state)/os"
rec="$rdir/scx_loader.enabled"
mkrec="$rdir/scx_loader.mkdir"
key='%etc%scx_loader%config.toml'
state="$(sysfs_path /sys/kernel/sched_ext/state)"

sc() {
  systemctl "$@" || die os "systemctl $* failed"
}

[[ -f "$rec" ]] || die os "nothing to revert"
stock="$(cat -- "$rec")" || die os "cannot read $rec"

sc stop scx_loader
if [[ -e "$(pc_oc_state)/backup/$key" || -e "$(pc_oc_state)/absent/$key" ]]; then
  file_restore /etc/scx_loader/config.toml
fi
# only a dir apply made is removed; rmdir leaves a populated one alone
if [[ -e "$mkrec" ]]; then
  rmdir -- "$(sysfs_path /etc/scx_loader)" 2>/dev/null || :
fi
if [[ "$stock" == disabled ]]; then
  sc disable scx_loader
fi

settled=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if [[ "$(cat -- "$state" 2>/dev/null || :)" == disabled ]]; then
    settled=1
    break
  fi
  sleep 1
done
[[ -n "$settled" ]] || die os "sched_ext still enabled after revert"

rm -f -- "$rec" "$mkrec" || die os "cannot remove records in $rdir"
rmdir -- "$rdir" 2>/dev/null || :
