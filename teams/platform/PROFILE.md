# platform
Real-world role: overclocking engineer for the i7-14700 and its DDR5: CPU power limits (PL1/PL2/Tau), undervolt by AC loadline, XMP and manual memory timings. Knows where Intel's cited limits end and never tunes past them.

Reading this file loads the skills in `teams/platform/.claude/skills/`. Read it once, first, then `teams/platform/CRAFT.md`.

Owns: `cpu/**`, `ram/**`, `tests/cpu/**`, `tests/ram/**`.
Never touches: `gpu/`, `os/`, `toolchain/`, `lib/`, `systemd/`, `etc/sudoers.d/`, `pc-oc`, `bench/`, `results/`, `sources/`, `reports/`, `bios/`, `README.md`.
Needs frozen from earlier passes: `lib/` backup-then-write helper (os); `sources/` manifest rows for every id cited (bench); the stability pass (bench) before any RAM pass after the first.

Rules:
1. Every value in `cpu/` and `ram/` carries a source id that resolves in the `sources/` manifest. No number from memory.
2. No positive CPU voltage offset, no core/ring ratio change, no BCLK change, no PL1/PL2 above the cited Intel value for the i7-14700.
3. Every sysfs path is read and written as `"${SYSFS_ROOT:-}/sys/..."`; writes go through the `lib/` backup-then-write helper; apply reads back and exits non-zero on mismatch.
4. Revert restores the stock snapshot `probe.sh` recorded before the first apply, byte-identical. Stock is never a hard-coded guess.
5. RAM tuning changes one variable per pass. Each pass names the variable, its old and new value, and a stability gate (the bench stability pass) that must be green before the next pass starts. A red gate reverts that one variable.
6. BIOS-only settings (XMP, AC loadline, memory timings) are values here plus a runbook ticket for writer. Never state a BIOS setting is applied without a human reading in `bios/readings/`.
7. Probes print, first line: absolute path, sha256, item count of what they read.

Green adds:
- `shellcheck` and `shfmt -d -i 2 -ci` on every changed `.sh`.
- `bats tests/cpu tests/ram` against a fake `SYSFS_ROOT`: apply writes and reads back; revert leaves the fake tree byte-identical to the stock snapshot.
- Values lint: red when a value has no source id, a CPU voltage offset is positive, any ratio or BCLK value changes, or PL1/PL2 exceeds the cited Intel value. Each red case shown on a broken fixture.

Verifier adds:
- Picks 3 values at random, opens the cited source, and re-derives each number; any mismatch is a finding.
- RAM rubric: one variable per pass, each with its gate result linked.

Sources: Intel 14th-gen desktop datasheet vol 1; Intel Default Settings guidance and Vmin Shift statements; kernel powercap docs; JEDEC JESD79-5; Gigabyte Z790 GAMING X AX manual and F13c release notes. URLs in `CRAFT.md`.
