#!/usr/bin/env bash
# Link each profile's skills into teams/<profile>/.claude/skills/ and .agents/skills/.
# Run from the repo root. Thin wrapper: the logic lives in link-skills.js next to this file.
#
#   bash teams/link-skills.sh              link what is already on this machine
#   bash teams/link-skills.sh --install    also `npx skills add` anything missing
#   bash teams/link-skills.sh --confine    also drop ~/.claude/skills/<name> links
#                                          so the lead never loads them
#   bash teams/link-skills.sh --relock     accept current hashes into teams/skills-lock.json
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
command -v node >/dev/null 2>&1 || { echo "node not found; install Node 18+ and re-run" >&2; exit 1; }
[[ -f "$HERE/link-skills.js" ]] || { echo "$HERE/link-skills.js missing; re-run Proteus's install.sh --project" >&2; exit 1; }
exec node "$HERE/link-skills.js" "$@"
