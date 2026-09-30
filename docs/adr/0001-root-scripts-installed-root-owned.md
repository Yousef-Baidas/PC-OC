# 0001: Root scripts run from a root-owned install, not the repo

Date: 2026-09-30. Status: accepted (human).

## Context

Tuning writes to `/sys`, `/etc`, and the NVIDIA driver, so it needs root without a password prompt, because agents cannot type one. A sudoers entry that names scripts inside `~/PC-OC` would let anything that can write the user's home (including any agent session) change what runs as root.

## Decision

- `install.sh`, run by the human with `sudo`, copies the reviewed scripts to `/usr/local/lib/pc-oc/` (owner root, mode 0755, files 0644/0755) and installs `/etc/sudoers.d/pc-oc`.
- sudoers allows only absolute paths under `/usr/local/lib/pc-oc/`, with no wildcards.
- Root scripts never source or execute anything from a user-writable path.
- systemd units call the installed copies, not the repo.
- After each merged change the human reruns `sudo ./install.sh`; the installed copy records the commit hash it came from.

## Consequences

- A repo edit has no root effect until the human reinstalls, which is also the review point.
- Tests run against the repo copy with a fake `SYSFS_ROOT`; only the installed copy touches real hardware.
