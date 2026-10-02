# CONVENTIONS.md

## Naming
- Script files kebab-case: `set-power-limits.sh`, not `setPowerLimits.sh`
- Variables and functions snake_case: `pl1_watts`, `read_rapl_limit`
- Constants and exported env vars UPPER_SNAKE: `PC_OC_ROOT`, `SYSFS_ROOT`
- systemd units prefixed `pc-oc-`: `pc-oc-cpu.service`
- Branches: `proteus/<run>` and `proteus/<run>-<issue>`

## Layout
- By component: `cpu/`, `ram/`, `gpu/`, `os/`, `toolchain/`, `bench/`, `bios/`
- Each tunable component has `apply.sh`, `revert.sh`, `probe.sh`
- `bios/` holds runbooks only (markdown), applied by the human
- Tests in `tests/<component>/*.bats`
- One entry point `pc-oc` (`pc-oc apply|revert|probe <component>|all`, `pc-oc search gpu`)

## Style
- Bash only; shebang `#!/usr/bin/env bash`; `set -euo pipefail` first line after it
- shellcheck clean, no disables without an inline reason
- shfmt, 2-space indent (`shfmt -i 2 -ci`)
- Quote every expansion: `"$var"`, not `$var`

## Errors
- Fatal on any unexpected state; print `pc-oc: <component>: <what>` to stderr, exit non-zero
- Every sysfs/procfs path read through `${SYSFS_ROOT:-}` prefix so tests can fake it
- Apply scripts verify the value took (read back) before exit 0

## Persistence
- Proven settings reapply at boot via systemd units
- Every `apply.sh` has a `revert.sh` restoring stock values; `pc-oc revert all` undoes everything
- Stock values are recorded by `probe.sh` before first apply, never hard-coded guesses

## Root
- Root only through repo scripts allowed by `/etc/sudoers.d/pc-oc`; no other sudo use
- sudoers entries name absolute script paths, no wildcards

## Tests
- bats-core against a fake sysfs tree; runs without root and in CI
- Hardware probes print first line: absolute path, hash or size, item count of what they read
- Benchmarks print inputs (versions, settings snapshot) with every result

## Values
- Every tuning number cites a primary source (Intel, NVIDIA, kernel, Gigabyte docs) in a comment or runbook line

## Commits
- Conventional Commits, scopes = component folders: `feat(cpu): ...`, `fix(bench): ...`
- No AI attribution trailers

## Forbidden
- No CPU core voltage increase, no ratio or BCLK change
- No new dependency without human approval
