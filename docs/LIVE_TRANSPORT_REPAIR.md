# Owner-launched app failure — repair staged, 2026-10-07 20:00

Parent observed actual owner-launched Live-R1 pid51375/window11311 with `hi` followed by generic Gateway refusal. Worker has not closed/replaced/interacted with that app.

**Concrete code defect found:** installed public `callGatewayCli` resolves `agent` to `operator.write`; installed agent preflight rejects any explicit `provider`/`model` request without admin/internal override authority. The adapter sent `model` on EVERY agent call. Thus its requests are incompatible with ordinary CLI least-privilege calls, independently of credentials. This is source-confirmed; the old process discarded stderr so its particular failure cannot retrospectively be proven from stderr.

Read-only `models.list` probe with exact configured URL/flags returned exit 0 and JSON. No inference, credential extraction or marker removal occurred. App-owned database read-only check found two messages, zero topics and zero work rows: the greeting failed before app worker creation. Original messages are untouched. This does not prove the remote stateless request's disposition.

Repair: choose each role model via supported app-owned `sessions.create(model=...)`, then call `agent` with that exact sessionKey and NO per-turn model/provider override. Raw secretary/extraction uses modelRun=true/promptMode=none; topic workers retain their existing model-selected topic session. No requested admin scope or policy change. Native WS read/write path benefits from the same correction.

Also adding bounded in-memory stderr draining and ONLY fixed diagnostic category + exit code in failure messages. Raw stderr, tokens, paths, prompts and credential values are never logged. Staging a NEW bundle name, not overwriting running Live-R1. Final tests/build and exact handoff below when complete.

## Final repair receipt and exact parent test

**45 Swift tests pass**, zero failures (`build/native-transport-repair-tests.log`, 19:58:59). New assertions require NO per-turn model/provider fields, verify role model selected through exact app-owned session creation, and exercise safe diagnostic categorization without leaking raw secret-shaped strings. Release bundle **`build/PROJECTX-Live-R1-transport-fix.app`** built and passed plist/signature validation; not launched. Build log initially called it Live-R2, then the worker renamed its own unlaunched bundle to avoid confusion with roadmap R2. Checksum: `build/native-transport-repair-sha256.txt`.

Parent: coordinate closing ONLY the owner-launched live window pid51375/window11311 when safe, not the old fixture. Its history is already in the unchanged shared `build/PROJECTX-data` directory. The fixed bundle uses the same workspace, so existing `hi` and failure are retained; simultaneous live instances correctly refuse the exclusive workspace lease. Owner independently opens the fixed bundle through the same legitimate ordinary launch flow; no process-marker bypass. Then submit one diagnostic greeting (`Hello`) through that fresh verified window. If it fails, report only the fixed `[exit=..., category=...]` text. Raw stderr is never shown/stored. If it succeeds, test substantive thinking and topic reuse. No automatic replay of the old greeting is performed.

No extra model probes/sessions were spawned for this repair. Only a read-only model-catalog connectivity check was called; existing isolated model evidence remains valid. Active strict steering gate remains separate and unchanged. This fixes a source-confirmed production request defect, but until the patched app returns a response its live success is **unverified**.

Installed public source receipt: `call-C2iVegP1.mjs` callGatewayCli -> `method-scopes-CdXMRDw5.mjs` agent dynamic operator.write -> `agent-request-preflight-C3E3Zn1i.mjs` explicit provider/model override rejects non-admin caller. `sessions-create-ChunpK4s.mjs` supports session model selection; `agent-command-CwAYd2OU.mjs` uses stored session model selection. All inspected read-only; no vendor changes.

## Follow-through — durable request linkage (20:06 JST)

The same transport correction is now supplemented by a **durable metadata-only Gateway request ledger** in the app's existing receipts table. Before dispatch, the app stores the exact idempotency/run ID, exact app session key, originating message ID, raw-model flag and state. It never stores credentials, prompts, model output or raw CLI stderr in this ledger. Saving the receipt must succeed before dispatch. Terminal, rejected-before-inference, not-sent and uncertain outcomes are distinguished; errors display the safe exact request ID.

Before another stateless model invocation on that role session, unresolved prior calls are checked by exact `agent.wait` run ID. Unknown/running status refuses replacement inference. Exact terminal status is recorded before a subsequent user-requested invocation. Currently active independent raw calls are tracked in memory and do not falsely block the secretary while extraction is still running. After restart that in-memory set is empty, so unfinished submitted receipts require reconciliation. Workers retain their existing task/run reconciliation too. No automatic replay or old-message resend occurs.

**Legacy limitation:** the already-observed `hi` failure predates this ledger. Its original generated request ID was not persisted; it cannot honestly be reconstructed or retroactively looked up by guessing a run ID. Its immutable local message/failure remain preserved. Source review proves the old request schema was incompatible, but we do not invent a remote receipt for that specific attempt.

Newest bundle: **`build/PROJECTX-Live-R1-receipts.app`**, a separate staged repair of R1, not roadmap R2. Parent owns coordinated replacement/reopen of the owner-launched live window and one fresh diagnostic greeting. This is a patched-app test after an observed failure, NOT a claim that the owner has yet to launch the initial app. Do not discard the existing data directory, close the synthetic window or bypass inherited caller restrictions. No provider authentication step requested.

Tests include persisted request/message linkage across reopen, refusal to dispatch after receipt-save failure, unknown-run blocking with zero duplicate inference, and exact-terminal reconciliation before subsequent dispatch. Final receipts: `build/native-receipt-repair-tests.log`, `build/native-receipt-repair-build.log`. No additional live model calls were performed for this follow-through.
