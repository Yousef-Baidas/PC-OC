# 0002: CI runs on the PC, not GitHub Actions

Date: 2026-09-30. Status: accepted (human).

## Context

GitHub Actions refuses to start jobs on this account (billing lock), and the repo is private on a free plan, so branch protection cannot require a status check anyway. The gates (`checks/gates.sh`) only need shellcheck, shfmt and bats, which are already installed here.

## Decision

- lefthook runs `checks/gates.sh` on pre-commit and the Conventional Commits check on commit-msg.
- `checks/ci.sh <pr>` checks the PR head out into a clean temporary worktree, runs the gates and the commit-msg check over every PR commit, and posts a `gates` commit status to GitHub.
- No `.github/workflows/`. No self-hosted runner daemon.
- `checks/ci.sh` refuses PRs whose head is a fork: it executes the PR's code on this machine.

## Consequences

- `gh pr checks` still shows `gates`, so reviewers and verifiers read CI the usual way.
- Nothing enforces the check server-side; merging only on `gates=success` is a rule for whoever merges.
- CI runs only when someone runs `checks/ci.sh`; a PR with no `gates` status has not been checked.
