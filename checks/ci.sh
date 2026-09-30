#!/usr/bin/env bash
set -euo pipefail
# Local CI (docs/adr/0002): run the gates and the commit-msg check on a PR head
# in a clean detached worktree, then post a `gates` commit status on the head.
# CI_NO_POST=1 prints the status instead of posting it. Exit 0 green, 1 red,
# 2 usage or fork (a fork's code is never run on this machine).

if [[ ! "${1:-}" =~ ^[0-9]+$ ]]; then
  echo "usage: checks/ci.sh <pr-number>" >&2
  exit 2
fi
pr=$1

cd "$(git rev-parse --show-toplevel)"

info=$(gh pr view "$pr" --json headRefOid,baseRefName,isCrossRepository \
  --jq '[.headRefOid, .baseRefName, .isCrossRepository] | @tsv')
IFS=$'\t' read -r sha base fork <<<"$info"

# post <state> <description>
post() {
  echo "gates=$1 $sha: $2"
  if [[ "${CI_NO_POST:-}" == 1 ]]; then
    echo "CI_NO_POST=1: not posted"
    return
  fi
  gh api "repos/{owner}/{repo}/statuses/$sha" \
    -f state="$1" -f context=gates -f description="$2" >/dev/null
}

if [[ "$fork" != false ]]; then
  echo "pc-oc: ci: PR #$pr head is a fork; not running its code here" >&2
  post failure "head is a fork; not run"
  exit 2
fi

git fetch -q origin "$base" "refs/pull/$pr/head"
tmp=$(mktemp -d)
trap 'git worktree remove --force "$tmp/wt" 2>/dev/null || true; rm -rf "$tmp"' EXIT
git worktree add -q --detach "$tmp/wt" "$sha"

if ! (cd "$tmp/wt" && checks/gates.sh); then
  post failure "checks/gates.sh failed"
  exit 1
fi

git rev-list --reverse "origin/$base..$sha" >"$tmp/commits"
mapfile -t commits <"$tmp/commits"
for c in "${commits[@]}"; do
  git log -1 --format=%B "$c" >"$tmp/msg"
  if ! (cd "$tmp/wt" && node teams/templates/hooks/commit-msg.js "$tmp/msg"); then
    post failure "commit ${c:0:7} message is not Conventional"
    exit 1
  fi
done

post success "gates and ${#commits[@]} commit messages green"
