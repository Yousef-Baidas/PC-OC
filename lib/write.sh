#!/usr/bin/env bash
set -euo pipefail
# Backup-then-write helpers for /sys and /etc. Source after lib/common.sh; do not execute it.
# Stubs: contract #25.

# pc_oc_state: print ${PC_OC_STATE:-/var/lib/pc-oc}; always /var/lib/pc-oc when EUID is 0.
pc_oc_state() {
  die lib "pc_oc_state not implemented"
}

# sys_write <path> <value>: back up stock on the first call for <path>, write <value>, read it back.
sys_write() {
  die lib "sys_write not implemented"
}

# sys_restore <path>: write the backed-up stock value, read it back, remove the backup.
sys_restore() {
  die lib "sys_restore not implemented"
}

# file_install <src> <dest>: back up <dest> (or record it absent), install <src> atomically.
file_install() {
  die lib "file_install not implemented"
}

# file_restore <dest>: put the original <dest> back, or remove it if it was absent; remove the backup.
file_restore() {
  die lib "file_restore not implemented"
}
