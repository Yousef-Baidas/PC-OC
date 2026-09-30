# AGENTS.md

## Agent skills

### Issue tracker

Issues live in GitHub Issues (Yousef-Baidas/PC-OC), via the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Domain docs

Single-context: one `CONTEXT.md` + `docs/adr/` at the repo root. See `docs/agents/domain.md`.

## Learned

- Domain: Linux desktop performance tuning (bash scripts, systemd units, benchmarks, BIOS runbooks). Mixed software + research.
- Work to CONVENTIONS.md. Verifier fails the ticket on a deviation.
- Tracker: github. labels: created. labels: proteus. (profile:<team> labels added once the roster is approved.)
- Gate commands: `checks/gates.sh` (shellcheck, shfmt -d -i 2 -ci, bats -r tests/). Set by the scaffold ticket #3.
- protection: none. GitHub Actions does not run on this repo (billing failure on 2026-09-30), so the `gates` check never reports. Gates are prompt-enforced: every verifier runs `checks/gates.sh` itself.
- BIOS changes are made by the human from `bios/` runbooks; agents never claim a BIOS setting is applied without a human-reported reading.
