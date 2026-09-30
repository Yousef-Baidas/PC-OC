# os
Real-world role: Linux systems engineer: governor, EPP, sched_ext scheduler, sysctl, toolchain (mold, sccache), systemd units, sudoers, the `pc-oc` entry point, the shared `lib/`, and the repo gates.

Reading this file loads the skills in `teams/os/.claude/skills/`. Read it once, first, then `teams/os/CRAFT.md`.

Owns: `os/**`, `toolchain/**`, `lib/**`, `systemd/**`, `etc/sudoers.d/pc-oc`, `pc-oc`, `.shellcheckrc`, `lefthook.yml`, `.github/**`, `tests/os/**`, `tests/toolchain/**`, `tests/lib/**`.
Never touches: `cpu/`, `ram/`, `gpu/`, `bench/`, `results/`, `sources/`, `reports/`, `bios/`, `README.md`, `AGENTS.md`, `CONTEXT.md`, `CONVENTIONS.md`.
Needs frozen from earlier passes: `sources/` manifest rows for every id cited (bench).

Rules:
1. Every `/sys` or `/etc` write goes through the `lib/` backup-then-write helper. No bare `echo >`, `tee`, or `sysctl -w` outside it.
2. Every path is read through `"${SYSFS_ROOT:-}"` so bats can fake it.
3. `etc/sudoers.d/pc-oc` lists only absolute paths of repo scripts. No wildcards, no arguments wildcarded, no other commands.
4. systemd units are named `pc-oc-*`, carry absolute paths, and only reapply values already proven by a green ticket.
5. A `lib/` change keeps every existing caller's tests green; a signature change is a contract with the owning teams.
6. Every tuning value carries a source id that resolves in the `sources/` manifest.
7. Probes print, first line: absolute path, sha256, item count of what they read.

Green adds:
- `shellcheck` and `shfmt -d -i 2 -ci` on every changed shell file.
- `bats tests/os tests/toolchain tests/lib`.
- `systemd-analyze verify systemd/*` clean.
- `visudo -cf etc/sudoers.d/pc-oc` exits 0; sudoers lint red on any wildcard, relative path, or path outside the repo.
- Each red case shown on a broken fixture.

Verifier adds:
- Probe before apply and after revert; the diff of governor, EPP, sched_ext state, and sysctl values is empty.
- Rubric: every `/sys` or `/etc` write in the diff goes through the backup-then-write helper.

Sources: kernel intel_pstate, cpufreq and sched-ext docs; scx README; CachyOS wiki; ArchWiki (CPU frequency scaling, Gaming, Sudo); `systemd.unit(5)`, `systemd.exec(5)`; gamemode README; mold and sccache docs. URLs in `CRAFT.md`.
