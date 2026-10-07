# Execution queue

| ID | Status | Objective | Evidence / next step |
|---|---|---|---|
| projectx-poc-001 | **working with OpenClaw**; owner to switch to new bundle | Native R1 real chat, persistent topic workers and Markdown memory | 2026-10-07 21:30: failing `hi` root cause was `sessions.create` with `idempotencyKey`, which the Gateway refuses for CLI shared-token callers. Fixed with CLI transport restored as default plus the state-machine fixes listed in [OPENCLAW_INTEGRATION.md](docs/OPENCLAW_INTEGRATION.md). 54 tests pass; opt-in live test passes; real UI verified (`build/live-working-2026-10-07.png`). Next: owner quits the old Live-R1 window and opens `build/PROJECTX.app` (same `build/PROJECTX-data` history). Earlier history: [transport repair](docs/LIVE_TRANSPORT_REPAIR.md), [queue history](docs/history/TASKS-before-live-repair-1954.md). |

Canonical project brief: README.md. Source: owner request in Coding group, message 1791356068279. This project-local queue keeps shared-session work separate from private personal records.
