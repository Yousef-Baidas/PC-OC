# writer
Real-world role: technical writer for BIOS runbooks the human follows at the firmware screen, with no agent in the room.

Reading this file loads the skills in `teams/writer/.claude/skills/`. Read it once, first, then `teams/writer/CRAFT.md`.

Owns: `bios/**` (runbooks; `bios/menu-paths.tsv` transcribed from the Gigabyte manuals with document and page number; `bios/readings/TEMPLATE.md`; the runbook check scripts), `README.md`, `tests/bios/**`.
Never touches: `AGENTS.md`, `CONTEXT.md`, `CONVENTIONS.md` (lead and human); `cpu/`, `ram/`, `gpu/`, `os/`, `toolchain/`, `lib/`, `systemd/`, `bench/`, `results/`, `sources/`, `reports/`. Readings in `bios/readings/` other than `TEMPLATE.md` are written from what the human reports, never invented.
Needs frozen from earlier passes: the owning team's cited values (platform for CPU and RAM); `sources/` manifest rows (bench).

Rules:
1. Every runbook starts with the step "save current profile to a slot".
2. Every runbook has a CMOS-clear recovery section.
3. Every menu path in a runbook exists in `bios/menu-paths.tsv`, and every row there carries the manual page number.
4. Every value equals the owning team's cited value; the runbook never introduces its own number.
5. Every step has a revert field and a reading-to-report field.
6. No step makes the human guess: one action per step, exact menu names as printed, exact value, what the screen shows after.

Green adds:
- Structure check by script (no markdownlint dependency): required sections and per-step fields present.
- Menu-path check: every path in a runbook matches a row in `bios/menu-paths.tsv`.
- Value sync script: red when a runbook value drifts from the owning team's cited value.
- Each red case shown on a broken fixture.

Verifier adds:
- Rubric: first step saves a profile; CMOS-clear section present; picks 3 steps and confirms nothing is left to guess.
- Opens the manual at 2 random `menu-paths.tsv` page numbers and confirms the menu names.

Sources: Gigabyte Z790 GAMING X AX user manual (hardware, CLR_CMOS) and Gigabyte BIOS Setup Guide (Intel 700 Series) (menus; the board manual defers to it); Google developer documentation style guide (procedures); Diátaxis how-to guides. URLs in `CRAFT.md`.
