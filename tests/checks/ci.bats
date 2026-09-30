#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

# Each test runs checks/ci.sh in a throwaway clone (on branch pr) whose origin
# holds main and refs/pull/1/head, with a stub gh that logs its arguments to $GH_LOG.
setup() {
  # lefthook runs this suite inside a git hook; its GIT_* vars would point git at the real repo
  # and checks/ci.sh runs it too, maybe under CI_NO_POST=1
  unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_PREFIX CI_NO_POST
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
  ci="$BATS_TEST_DIRNAME/../../checks/ci.sh"
  repo="$BATS_TEST_TMPDIR/repo"
  export GH_LOG="$BATS_TEST_TMPDIR/gh.log" STUB_FORK=false STUB_API_FAIL=0

  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat >"$BATS_TEST_TMPDIR/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$GH_LOG"
if [[ "$1 $2" == "pr view" ]]; then
  printf '%s\tmain\t%s\n' "$(git rev-parse pr)" "$STUB_FORK"
elif [[ "$1" == api ]]; then
  exit "$STUB_API_FAIL"
fi
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"

  git init -q --bare -b main "$BATS_TEST_TMPDIR/origin.git"
  git init -q -b main "$repo"
  mkdir -p "$repo/checks"
  gates 'echo gates ran'
  git -C "$repo" add -A
  git -C "$repo" commit -q -m "chore: init"
  git -C "$repo" remote add origin "$BATS_TEST_TMPDIR/origin.git"
  git -C "$repo" push -q origin main
  git -C "$repo" checkout -q -b pr
}

# gates <body>: write the fixture's checks/gates.sh in the clone's working tree
gates() {
  printf '#!/usr/bin/env bash\n%s\n' "$1" >"$repo/checks/gates.sh"
  chmod +x "$repo/checks/gates.sh"
}

# pr_commit <subject>: commit the working tree on branch pr and publish it as PR #1
pr_commit() {
  git -C "$repo" add -A
  git -C "$repo" commit -q --allow-empty -m "$1"
  git -C "$repo" push -q origin pr:refs/pull/1/head
}

# posted <state> <description>: gh was asked to post that gates status on the pr head
posted() {
  grep -qF -- "api repos/{owner}/{repo}/statuses/$(git -C "$repo" rev-parse pr) -f state=$1 -f context=gates -f description=$2" "$GH_LOG"
}

run_ci() {
  cd "$repo" || return
  run "$ci" "$@"
}

@test "green PR exits 0 and posts gates=success, even when the cwd's gates fail" {
  pr_commit "feat(cpu): add probe"
  gates 'exit 1'
  run_ci 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"gates ran"* ]]
  posted success "gates and 1 commit messages green"
}

@test "failing gates in the PR head exit 1 and post gates=failure naming the step" {
  gates 'echo "shellcheck: 1 files"; echo "shfmt: 1 files"; exit 1'
  pr_commit "fix(cpu): break gates"
  gates 'echo gates ran'
  run_ci 1
  [ "$status" -eq 1 ]
  posted failure "gates: shfmt failed"
}

@test "an older non-Conventional subject fails even if the head weakens commit-msg.js" {
  mkdir -p "$repo/teams/templates/hooks"
  echo 'process.exit(0)' >"$repo/teams/templates/hooks/commit-msg.js"
  pr_commit "Add stuff"
  bad=$(git -C "$repo" rev-parse --short=7 pr)
  pr_commit "feat(cpu): add probe"
  run_ci 1
  [ "$status" -eq 1 ]
  posted failure "commit $bad message is not Conventional"
}

@test "a non-Conventional subject already on base is not checked" {
  git -C "$repo" commit -q --allow-empty -m "Bad base subject"
  git -C "$repo" push -q origin pr:main
  pr_commit "feat(cpu): add probe"
  run_ci 1
  [ "$status" -eq 0 ]
  posted success "gates and 1 commit messages green"
}

@test "a fork PR is not run, exits 2 and posts nothing" {
  gates 'echo pwned'
  pr_commit "feat(cpu): add probe"
  STUB_FORK=true run_ci 1
  [ "$status" -eq 2 ]
  [[ "$output" != *pwned* ]]
  [[ "$output" == "pc-oc: ci: PR #1 head is a fork"* ]]
  run ! grep -q '^api ' "$GH_LOG"
}

@test "a failed fetch of the PR head exits 1 and posts gates=failure" {
  git -C "$repo" commit -q --allow-empty -m "feat(cpu): add probe"
  run_ci 1
  [ "$status" -eq 1 ]
  posted failure "git fetch of PR #1 head failed"
}

@test "a PR head that moved after gh pr view exits 1 and posts gates=failure" {
  pr_commit "feat(cpu): add probe"
  git -C "$repo" commit -q --allow-empty -m "feat(cpu): add more"
  run_ci 1
  [ "$status" -eq 1 ]
  posted failure "PR head moved off $(git -C "$repo" rev-parse --short=7 pr); rerun"
}

@test "a refused status post exits 1" {
  pr_commit "feat(cpu): add probe"
  STUB_API_FAIL=4 run_ci 1
  [ "$status" -eq 1 ]
  posted success "gates and 1 commit messages green"
  [[ "$output" == *"pc-oc: ci: posting gates=success on "*" failed"* ]]
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
