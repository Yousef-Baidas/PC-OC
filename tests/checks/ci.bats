#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

# Each test runs checks/ci.sh in a throwaway clone whose origin holds main and
# refs/pull/1/head, with a stub gh that logs its arguments to $GH_LOG.
setup() {
  # lefthook runs this suite inside a git hook; its GIT_* vars would point git at the real repo
  unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_PREFIX
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
  ci="$BATS_TEST_DIRNAME/../../checks/ci.sh"
  repo="$BATS_TEST_TMPDIR/repo"
  export GH_LOG="$BATS_TEST_TMPDIR/gh.log" STUB_FORK=false

  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat >"$BATS_TEST_TMPDIR/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$GH_LOG"
if [[ "$1 $2" == "pr view" ]]; then
  printf '%s\tmain\t%s\n' "$(git rev-parse pr)" "$STUB_FORK"
fi
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"

  git init -q --bare -b main "$BATS_TEST_TMPDIR/origin.git"
  git init -q -b main "$repo"
  mkdir -p "$repo/checks" "$repo/teams/templates/hooks"
  cp "$BATS_TEST_DIRNAME/../../teams/templates/hooks/commit-msg.js" "$repo/teams/templates/hooks/"
  gates 'echo gates ran'
  git -C "$repo" add -A
  git -C "$repo" commit -q -m "chore: init"
  git -C "$repo" remote add origin "$BATS_TEST_TMPDIR/origin.git"
  git -C "$repo" push -q origin main
  git -C "$repo" checkout -q -b pr
}

# gates <body>: write the fixture's checks/gates.sh
gates() {
  printf '#!/usr/bin/env bash\n%s\n' "$1" >"$repo/checks/gates.sh"
  chmod +x "$repo/checks/gates.sh"
}

# pr_commit <subject>: commit the worktree on branch pr and publish it as PR #1
pr_commit() {
  git -C "$repo" add -A
  git -C "$repo" commit -q --allow-empty -m "$1"
  git -C "$repo" push -q origin pr:refs/pull/1/head
}

run_ci() {
  cd "$repo" || return
  run "$ci" "$@"
}

@test "green PR exits 0 and posts gates=success on the head" {
  pr_commit "feat(cpu): add probe"
  run_ci 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"gates ran"* ]]
  grep -q "^api repos/{owner}/{repo}/statuses/$(git -C "$repo" rev-parse pr) .*-f state=success -f context=gates " "$GH_LOG"
}

@test "failing gates in the PR head exit 1 and post gates=failure" {
  gates 'exit 1'
  pr_commit "fix(cpu): break gates"
  run_ci 1
  [ "$status" -eq 1 ]
  grep -q -- "-f state=failure -f context=gates -f description=checks/gates.sh failed" "$GH_LOG"
}

@test "a non-Conventional commit subject exits 1 and posts gates=failure" {
  pr_commit "feat(cpu): add probe"
  pr_commit "Add stuff"
  run_ci 1
  [ "$status" -eq 1 ]
  sha=$(git -C "$repo" rev-parse --short=7 pr)
  grep -q -- "-f state=failure -f context=gates -f description=commit $sha message is not Conventional" "$GH_LOG"
}

@test "a fork PR is not run, exits 2 and posts gates=failure" {
  gates 'echo pwned'
  pr_commit "feat(cpu): add probe"
  STUB_FORK=true run_ci 1
  [ "$status" -eq 2 ]
  [[ "$output" != *pwned* ]]
  [[ "$output" == *fork* ]]
  grep -q -- "-f state=failure -f context=gates " "$GH_LOG"
}

@test "CI_NO_POST=1 prints the status and posts nothing" {
  pr_commit "feat(cpu): add probe"
  CI_NO_POST=1 run_ci 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"gates=success"* ]]
  run ! grep -q '^api ' "$GH_LOG"
}

@test "the temporary worktree is removed on exit" {
  gates 'exit 1'
  pr_commit "fix(cpu): break gates"
  run_ci 1
  [ "$(git -C "$repo" worktree list | wc -l)" -eq 1 ]
}

@test "a non-numeric PR argument prints usage and exits 2" {
  run_ci 'x;y'
  [ "$status" -eq 2 ]
  [[ "$output" == usage:* ]]
  [ ! -e "$GH_LOG" ]
}
