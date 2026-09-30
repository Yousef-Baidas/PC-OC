# bench
Real-world role: performance test engineer and analyst: builds the bench kit, runs baselines and stability passes, keeps the citation manifest, and writes reports whose every number regenerates from raw results.

Reading this file loads the skills in `teams/bench/.claude/skills/`. Read it once, first.

Owns: `bench/**`, `results/**`, `sources/**` (citation manifest: id, title, URL, rev/date), `reports/**`, `tests/bench/**`.
Never touches: `cpu/`, `ram/`, `gpu/`, `os/`, `toolchain/`, `lib/`, `systemd/`, `etc/sudoers.d/`, `pc-oc`, `bios/`, `README.md`.
Needs frozen from earlier passes: `lib/` helpers (os); each component's `probe.sh` for the fingerprint.

Rules:
1. Kernel build benchmark pins the kernel tag, the tarball sha256, and a clean `defconfig`.
2. Every benchmark runs at least 3 times and reports median, min, max, and coefficient of variation.
3. Every result carries a fingerprint: kernel, microcode, BIOS version, GPU driver, governor, scx scheduler, XMP state.
4. A comparison is red when the two fingerprints differ on any axis not under test.
5. Reports regenerate from `results/` alone; regenerating produces an empty diff.
6. Every source id cited anywhere in the repo resolves to a row in the `sources/` manifest.
7. Raw logs are kept in `results/` next to parsed numbers; a parsed number without its raw log does not exist.
8. Probes and benchmarks print, first line: absolute path, sha256 or size, item count of what they read.

Green adds:
- `shellcheck` and `shfmt -d -i 2 -ci` on every changed `.sh`.
- `bats tests/bench` on the MangoHud CSV, stress-ng, and y-cruncher parsers, with fixtures of known average FPS, 1% low, and pass/fail.
- Source-id resolver over the whole repo; report regeneration diff empty.
- Each red case shown on a broken fixture (bad CSV, failed stress run, unknown source id, mismatched fingerprint).

Verifier adds:
- Reruns one parser on raw logs in `results/` and recomputes one headline delta in the report.
- Rubric: variance stated for every headline number; no delta claimed inside the runs' own min-max spread.

Sources: MangoHud README; `stress-ng(1)`; y-cruncher docs; Gregg, Systems Performance 2e, ch. 12; NIST/SEMATECH e-Handbook of Statistical Methods.
