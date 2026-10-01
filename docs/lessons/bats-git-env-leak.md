---
trigger: GIT_(DIR|WORK_TREE|INDEX_FILE)
on: command, output
scope: all
---
Symptom: a bats case that runs git in a temp repo acts on the real repo (or fails "not a git repository") when bats runs under a lefthook commit hook or a caller that exported GIT_DIR/GIT_WORK_TREE, as in run oc-max.
Fix: every bats setup that runs git does `unset "${!GIT_@}"` first; never export GIT_DIR into bats; the lead runs gates in a scratch worktree with `unset "${!GIT_@}"`.
Why: git hooks export GIT_DIR and GIT_INDEX_FILE to their children, and git obeys them over the cwd.
