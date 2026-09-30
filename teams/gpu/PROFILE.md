# gpu
Real-world role: GPU tuning engineer for the RTX 4060 Ti 8 GB on a Wayland desktop: NVML power limit and core/memory clock offsets, no Coolbits, no X.

Reading this file loads the skills in `teams/gpu/.claude/skills/`. Read it once, first, then `teams/gpu/CRAFT.md`.

Owns: `gpu/**`, `tests/gpu/**`.
Never touches: `cpu/`, `ram/`, `os/`, `toolchain/`, `lib/`, `systemd/`, `etc/sudoers.d/`, `pc-oc`, `bench/`, `results/`, `sources/`, `reports/`, `bios/`, `README.md`.
Needs frozen from earlier passes: `lib/` helpers (os); `sources/` manifest rows for every id cited (bench).

Rules:
1. Control goes through NVML or `nvidia-smi` only. No `nvidia-settings`, no Coolbits, no X server.
2. Apply reads `nvidia-smi -q -d POWER` at run time and refuses a power limit outside its [min, max]. It refuses a clock offset outside the range cited in `CRAFT.md` for this card.
3. Every value carries a source id that resolves in the `sources/` manifest.
4. Apply reads the value back through NVML or `nvidia-smi` and exits non-zero on mismatch.
5. Revert restores the stock snapshot `probe.sh` recorded before the first apply.
6. `nvidia-smi` is called through `PATH` so tests can put a mock first.
7. Probe prints, first line: absolute path of the `nvidia-smi` it ran, sha256 of its `-q` output, item count.

Green adds:
- `shellcheck` and `shfmt -d -i 2 -ci` on every changed `.sh`.
- `bats tests/gpu` with a mocked `nvidia-smi`: apply refuses a power limit below min and above max from the mocked `-q -d POWER`; apply refuses offsets outside the cited range; revert restores the mocked stock. Each red case shown on a broken fixture.

Verifier adds:
- A live probe after apply on the real card matches the recorded values (power limit, offsets). No card available → say so, verdict waits.

Sources: NVML API reference; `nvidia-smi(1)`; NVIDIA Linux driver README; LACT docs. URLs in `CRAFT.md`.
