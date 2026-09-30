---
trigger: EnterWorktree|git rev-parse --show-toplevel|shell cwd is /home/tuff/PC-OC\b
on: command, output
scope: all
---
Symptom: in-process workers start in the lead's checkout, not their worktree; they commit onto local proteus/<run>, and EnterWorktree from a worker pins the lead session to that worker's worktree, which blocks every lead git command.
Fix: cwd resets to the lead checkout on every call, so a bare `cd` does not persist; every worker shell call starts `cd <worktree> && …`, and `git rev-parse --show-toplevel` must print the worktree before any edit or commit; never call EnterWorktree or ExitWorktree. Lead: ExitWorktree action=keep, park strays on a local rescue branch, reset proteus/<run> to origin.
Why: teammates share the session's working directory and worktree state; the brief's "run in the worktree" is not enforced by the harness.
