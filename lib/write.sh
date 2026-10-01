#!/usr/bin/env bash
set -euo pipefail
# Backup-then-write helpers for /sys and /etc. Source after lib/common.sh; do not execute it.
# Every command is guarded with || die so no failure leaves with a status other than 1.
# Backups live under $(pc_oc_state): backup/<path with / as %> holds stock content,
# absent/<same key> marks a file_install dest that did not exist.

# pc_oc_state: print ${PC_OC_STATE:-/var/lib/pc-oc}; always /var/lib/pc-oc when EUID is 0.
pc_oc_state() {
  if [[ "$EUID" -eq 0 ]]; then
    printf '%s\n' /var/lib/pc-oc
  else
    printf '%s\n' "${PC_OC_STATE:-/var/lib/pc-oc}"
  fi
}

# _w_key <path>: print the backup file name for <path>; dies unless <path> is absolute.
_w_key() {
  [[ "$1" == /* ]] || die lib "not an absolute path: $1"
  # / maps to %, so a % in the path would make two paths share one backup
  [[ "$1" != *%* ]] || die lib "path contains %: $1"
  local key="${1//\//%}"
  printf '%s\n' "$key"
}

# sys_write <path> <value>: back up stock on the first call for <path>, write <value>, read it back.
sys_write() {
  [[ $# -eq 2 ]] || die lib "usage: sys_write <path> <value>"
  local path="$1" want="$2" real state key bak="" got
  real="$(sysfs_path "$path")" || die lib "sysfs_path $path failed"
  state="$(pc_oc_state)" || die lib "pc_oc_state failed"
  key="$(_w_key "$path")" || exit 1
  if [[ ! -e "$state/backup/$key" ]]; then
    mkdir -p "$state/backup" || die lib "mkdir $state/backup failed"
    bak="$state/backup/$key"
    # stage then rename, so a crash never leaves a half-written backup
    { cat -- "$real" >"$bak.tmp"; } 2>/dev/null || {
      rm -f -- "$bak.tmp" || :
      die lib "cannot read $path"
    }
    mv -f -- "$bak.tmp" "$bak" || die lib "cannot record backup for $path"
  fi
  { printf '%s\n' "$want" >"$real"; } 2>/dev/null || {
    # nothing was written, so a backup made by this call is not stock history
    [[ -z "$bak" ]] || rm -f -- "$bak" || :
    die lib "cannot write $path"
  }
  got="$(cat -- "$real" 2>/dev/null)" || die lib "readback $path: want $want got <unreadable>"
  [[ "$got" == "$want" ]] || die lib "readback $path: want $want got $got"
}

# sys_restore <path>: write the backed-up value, read it back, remove the backup.
sys_restore() {
  [[ $# -eq 1 ]] || die lib "usage: sys_restore <path>"
  local path="$1" real state key bak want got
  real="$(sysfs_path "$path")" || die lib "sysfs_path $path failed"
  state="$(pc_oc_state)" || die lib "pc_oc_state failed"
  key="$(_w_key "$path")" || exit 1
  bak="$state/backup/$key"
  [[ -f "$bak" ]] || die lib "no backup for $path"
  { cat -- "$bak" >"$real"; } 2>/dev/null || die lib "cannot write $path"
  want="$(cat -- "$bak")" || die lib "cannot read backup for $path"
  got="$(cat -- "$real" 2>/dev/null)" || die lib "readback $path: want $want got <unreadable>"
  [[ "$got" == "$want" ]] || die lib "readback $path: want $want got $got"
  rm -f -- "$bak" || die lib "cannot remove backup for $path"
}

# _w_place <src> <real>: copy <src> over <real> via a temp file in the same dir, then compare bytes.
# Returns 1 when <real> is untouched, 2 when the mv ran but the compare did not pass.
_w_place() {
  local tmp
  tmp="$(mktemp -- "$2.XXXXXX" 2>/dev/null)" || return 1
  if ! { cp -p -- "$1" "$tmp" && mv -f -- "$tmp" "$2"; } 2>/dev/null; then
    rm -f -- "$tmp" || :
    return 1
  fi
  cmp -s -- "$1" "$2" 2>/dev/null || return 2
}

# file_install <src> <dest>: back up <dest> (or record it absent), install <src> atomically.
file_install() {
  [[ $# -eq 2 ]] || die lib "usage: file_install <src> <dest>"
  local src="$1" dest="$2" real state key made="" rc
  [[ -f "$src" ]] || die lib "no such file: $src"
  real="$(sysfs_path "$dest")" || die lib "sysfs_path $dest failed"
  state="$(pc_oc_state)" || die lib "pc_oc_state failed"
  key="$(_w_key "$dest")" || exit 1
  if [[ ! -e "$state/backup/$key" && ! -e "$state/absent/$key" ]]; then
    mkdir -p "$state/backup" "$state/absent" || die lib "mkdir under $state failed"
    if [[ -e "$real" ]]; then
      made="$state/backup/$key"
      { cp -p -- "$real" "$made.tmp" && mv -f -- "$made.tmp" "$made"; } 2>/dev/null || {
        rm -f -- "$made.tmp" || :
        die lib "cannot back up $dest"
      }
    else
      made="$state/absent/$key"
      : >"$made" || die lib "cannot record $dest as absent"
    fi
  fi
  # a second install keeps the first record, so restore still gives stock
  rc=0
  _w_place "$src" "$real" || rc=$?
  if [[ "$rc" -eq 1 ]]; then
    [[ -z "$made" ]] || rm -f -- "$made" || :
    die lib "cannot install $src to $dest"
  elif [[ "$rc" -ne 0 ]]; then
    # dest was replaced, so the backup is the only stock left: keep it
    die lib "installed $dest but verify failed; backup kept"
  fi
}

# file_restore <dest>: put the original <dest> back, or remove it if it was absent; remove the backup.
file_restore() {
  [[ $# -eq 1 ]] || die lib "usage: file_restore <dest>"
  local dest="$1" real state key
  real="$(sysfs_path "$dest")" || die lib "sysfs_path $dest failed"
  state="$(pc_oc_state)" || die lib "pc_oc_state failed"
  key="$(_w_key "$dest")" || exit 1
  if [[ -f "$state/backup/$key" ]]; then
    _w_place "$state/backup/$key" "$real" || die lib "cannot restore $dest"
    rm -f -- "$state/backup/$key" || die lib "cannot remove backup for $dest"
  elif [[ -e "$state/absent/$key" ]]; then
    rm -f -- "$real" || die lib "cannot remove $dest"
    rm -f -- "$state/absent/$key" || die lib "cannot remove backup for $dest"
  else
    die lib "no backup for $dest"
  fi
}

# file_recorded <dest>: return 0 when a file_install record exists for <dest>, else 1. Contract #48.
file_recorded() {
  die lib "file_recorded not implemented"
}
