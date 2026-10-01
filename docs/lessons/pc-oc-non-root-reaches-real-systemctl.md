---
trigger: pc-oc\s+(apply|revert)|/pc-oc"?\s+(apply|revert)
on: command
scope: all
---
Symptom: `pc-oc apply|revert …` run non-root with a mock systemctl or nvidia-smi on PATH calls the real /usr/bin tool; polkit prompts appear, and three failures lock the user out (pam_faillock), as in run oc-max on 2026-10-01.
Fix: never call pc-oc's apply or revert outside `unshare -rm` with the mock bind-mounted over /usr/bin/<tool>; to exercise a component non-root, run `<c>/apply.sh` directly with the mock first on PATH.
Why: pc-oc exports PATH=/usr/bin unconditionally (docs/adr/0001), so PATH mocks are dropped at the entry point.
