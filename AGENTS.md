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
- CI runs on the PC, never GitHub Actions (ADR 0002). `checks/ci.sh <pr>` runs the gates on the PR head and posts the `gates` commit status that `gh pr checks` shows. Run it after every worker push and before every verdict; no `gates` status on a PR means CI has not run, never green.
- protection: none. Private repo on a free plan, so GitHub cannot require the `gates` check; the lead merges only when `gates` is `success` on the PR head.
- BIOS changes are made by the human from `bios/` runbooks; agents never claim a BIOS setting is applied without a human-reported reading.
