#!/usr/bin/env bash
set -euo pipefail
# Local CI (docs/adr/0002): run the gates and the commit-msg check on a PR head
# in a clean detached worktree, then post a `gates` commit status on the head.
# CI_NO_POST=1 prints the status instead of posting it. Exit 0 green, 1 red,
# 2 usage or fork (a fork's code is never run here, and it gets no status).

if [[ ! "${1:-}" =~ ^[0-9]+$ ]]; then
  echo "usage: checks/ci.sh <pr-number>" >&2
  exit 2
fi
pr=$1
# from this trusted checkout, not the PR head, so a PR cannot weaken its own message check
commit_msg="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/teams/templates/hooks/commit-msg.js"

cd "$(git rev-parse --show-toplevel)"

if ! pr_info=$(gh pr view "$pr" --json headRefOid,baseRefName,isCrossRepository \
  --jq '[.headRefOid, .baseRefName, .isCrossRepository] | @tsv'); then
  echo "pc-oc: ci: gh pr view $pr failed" >&2
  exit 1
fi
IFS=$'\t' read -r sha base is_fork <<<"$pr_info"

if [[ "$is_fork" != false ]]; then
  echo "pc-oc: ci: PR #$pr head is a fork; not running its code here" >&2
  exit 2
fi

# post <state> <description>: set the gates status on the head, exit 1 if gh refuses
post() {
  echo "gates=$1 $sha: $2"
  if [[ "${CI_NO_POST:-}" == 1 ]]; then
    echo "CI_NO_POST=1: not posted"
    return
  fi
  if ! gh api "repos/{owner}/{repo}/statuses/$sha" \
    -f state="$1" -f context=gates -f description="$2" >/dev/null; then
    echo "pc-oc: ci: posting gates=$1 on $sha failed" >&2
    exit 1
  fi
}

# fail <description>: post gates=failure naming the failed step, exit 1
fail() {
  echo "pc-oc: ci: $1" >&2
  post failure "$1"
  exit 1
}

git fetch -q origin "refs/pull/$pr/head" || fail "git fetch of PR #$pr head failed"
[[ "$(git rev-parse FETCH_HEAD)" == "$sha" ]] || fail "PR head moved off ${sha:0:7}; rerun"
git fetch -q origin "$base" || fail "git fetch of $base failed"
tmp=$(mktemp -d) || fail "mktemp failed"
trap 'git worktree remove --force "$tmp/wt" 2>/dev/null || true; rm -rf "$tmp"; git worktree prune' EXIT
git worktree add -q --detach "$tmp/wt" "$sha" || fail "git worktree add failed"

if ! (cd "$tmp/wt" && checks/gates.sh) 2>&1 | tee "$tmp/gates.log"; then
  # gates.sh prints "<step>: N files" before each step, so the last one printed is the one that failed
  step=$(awk -F: '/^(shellcheck|shfmt|bats):/ { s = $1 } END { print s }' "$tmp/gates.log")
  fail "gates: ${step:-checks/gates.sh} failed"
fi

# a file, not a process substitution, so a rev-list failure is caught
git rev-list --reverse "origin/$base..$sha" >"$tmp/commits" || fail "git rev-list failed"
mapfile -t commits <"$tmp/commits"
for c in "${commits[@]}"; do
  git log -1 --format=%B "$c" >"$tmp/msg" || fail "git log of ${c:0:7} failed"
  node "$commit_msg" "$tmp/msg" || fail "commit ${c:0:7} message is not Conventional"
done

post success "gates and ${#commits[@]} commit messages green"
