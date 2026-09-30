# Routing

One row per deliverable type or path pattern → the one team that owns it. The lead routes every ticket by this table; a ticket with no row is a question for the human, and the answer becomes a row. `security` and `qa` are never routed to; they verify.

| Deliverable or path | Team |
|---|---|
| `cpu/**` | platform |
| `ram/**` | platform |
| `tests/cpu/**` | platform |
| `tests/ram/**` | platform |
| `gpu/**` | gpu |
| `tests/gpu/**` | gpu |
| `os/**` | os |
| `toolchain/**` | os |
| `lib/**` | os |
| `systemd/**` | os |
| `etc/sudoers.d/pc-oc` | os |
| `pc-oc` (entry point) | os |
| `.shellcheckrc` | os |
| `lefthook.yml` | os |
| `.github/**` | os |
| `tests/os/**` | os |
| `tests/toolchain/**` | os |
| `tests/lib/**` | os |
| `bench/**` | bench |
| `results/**` | bench |
| `sources/**` (citation manifest) | bench |
| `reports/**` | bench |
| `tests/bench/**` | bench |
| `bios/**` (runbooks, `menu-paths.tsv`, `readings/TEMPLATE.md`) | writer |
| `README.md` | writer |
| `AGENTS.md`, `CONTEXT.md`, `CONVENTIONS.md` | lead or human, never a team |
