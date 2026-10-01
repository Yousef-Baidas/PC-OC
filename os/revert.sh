#!/usr/bin/bash
set -euo pipefail
# Undo os/apply.sh: stop scx_loader, restore its config and enabled state, wait for stock sched_ext.
# ADR 0001: root runs with a fixed PATH. Non-root (bats) keeps PATH so mock systemctl/sleep win.
[[ "$EUID" -ne 0 ]] || PATH=/usr/bin
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# shellcheck source=../lib/write.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/write.sh"

rec="$(pc_oc_state)/os/scx_loader.enabled"
state="$(sysfs_path /sys/kernel/sched_ext/state)"

[[ -f "$rec" ]] || die os "nothing to revert"
stock="$(cat -- "$rec")" || die os "cannot read $rec"

systemctl stop scx_loader
file_restore /etc/scx_loader/config.toml
# apply made the dir when stock had none; rmdir leaves a populated one alone
rmdir -- "$(sysfs_path /etc/scx_loader)" 2>/dev/null || :
if [[ "$stock" == disabled ]]; then
  systemctl disable scx_loader
fi
rm -f -- "$rec" || die os "cannot remove $rec"
rmdir -- "$(dirname "$rec")" 2>/dev/null || :

for _ in 1 2 3 4 5 6 7 8 9 10; do
  [[ "$(cat -- "$state" 2>/dev/null || :)" != disabled ]] || exit 0
  sleep 1
done
die os "sched_ext still enabled after revert"
