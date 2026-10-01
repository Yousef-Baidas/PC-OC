#!/usr/bin/bash
set -euo pipefail
# Load scx_lavd through scx_loader; on any failure after a step ran, undo the steps taken and die.
# ADR 0001: root runs with a fixed PATH. Non-root (bats) keeps PATH so mock systemctl/sleep win.
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
! is_root || PATH=/usr/bin
# shellcheck source=../lib/write.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/write.sh"

here="$(dirname "${BASH_SOURCE[0]}")"
rdir="$(pc_oc_state)/os"
rec="$rdir/scx_loader.enabled"
mkrec="$rdir/scx_loader.mkdir"
conf_dir="$(sysfs_path /etc/scx_loader)"
state="$(sysfs_path /sys/kernel/sched_ext/state)"
ops="$(sysfs_path /sys/kernel/sched_ext/root/ops)"

sc() {
  systemctl "$@" || die os "systemctl $* failed"
}

# what this run wrote, so a failure before the install removes only that
new_rec="" new_mk="" new_dir=""
undo() {
  local rc=$?
  trap - EXIT
  [[ "$rc" -ne 0 ]] || exit 0
  if file_recorded /etc/scx_loader/config.toml; then
    # the install ran, so the loader and config need the full revert
    bash "$here/revert.sh" || :
    printf 'pc-oc: os: scx_lavd did not load\n' >&2
  else
    [[ -z "$new_dir" ]] || rmdir -- "$conf_dir" 2>/dev/null || :
    [[ -z "$new_mk" ]] || rm -f -- "$mkrec"
    [[ -z "$new_rec" ]] || rm -f -- "$rec"
    rmdir -- "$rdir" 2>/dev/null || :
    printf 'pc-oc: os: apply failed, nothing left changed\n' >&2
  fi
  exit 1
}
trap undo EXIT

mkdir -p -- "$rdir" || die os "cannot create $rdir"
# stock enabled state, recorded on the first apply only
if [[ ! -e "$rec" ]]; then
  stock="$(systemctl is-enabled scx_loader || :)"
  [[ -n "$stock" ]] || die os "cannot read scx_loader enabled state"
  printf '%s\n' "$stock" >"$rec" || die os "cannot write $rec"
  new_rec=1
fi
# file_install cannot make the parent dir; note it when stock had none
if [[ ! -d "$conf_dir" ]]; then
  mkdir -p -- "$conf_dir" || die os "cannot create /etc/scx_loader"
  new_dir=1
  if [[ ! -e "$mkrec" ]]; then
    : >"$mkrec" || die os "cannot write $mkrec"
    new_mk=1
  fi
fi

file_install "$here/scx_loader.toml" /etc/scx_loader/config.toml
sc enable scx_loader
sc restart scx_loader

# state=enabled alone is not enough: a fallback or another scheduler must fail
loaded=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if [[ "$(cat -- "$state" 2>/dev/null || :)" == enabled && "$(cat -- "$ops" 2>/dev/null || :)" == lavd* ]]; then
    loaded=1
    break
  fi
  sleep 1
done
[[ -n "$loaded" ]] || die os "scx_lavd did not load"
