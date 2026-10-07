# Persistent topic/sub-chat binding — queued 17:21 decision review

Owner message 1791361273761: one growing sub-chat per topic, reused across later requests; active amendments stay on the same task. Topic/session identity and task/run identity are distinct. No custom compaction.

## Current native implementation reviewed

The newer native implementation already provides the requested binding, so no duplicate runtime implementation was added:

- `Store.swift` persists `Topic.sessionKey` with a UNIQUE constraint. Topic creation assigns `agent:<agent>:projectx:<topic UUID>` once.
- `Engine.swift` creates a new work/task identity for a later completed-topic request, but obtains the same stored Topic and its session key. Confirmed session readiness is recovered from that topic's persisted work, not another topic's work.
- `Harness.swift` uses the topic's key and topic-owned controller/workspace. Confirmed existing sessions are not recreated; each invocation has a separate run ID. There is no history-reset/custom-compaction call.
- Active/uncertain per-topic exclusion and existing steering/revision safeguards prevent a second task from silently replacing an ongoing amendment.

This is a durable **local binding** and tested adapter contract, not proof that a live remote Gateway retained the expected history.

## Added focused native tests

`Tests/ProjectXCoreTests/TopicBindingTests.swift` adds two cases:

1. Seed a completed task and handle, release the original Store, and reopen its real database with the exclusive workspace lease. Continue topic A, use topic B, then return to A. Assert A/B/A session keys, readiness true/false/true, three distinct new task IDs, and unchanged topic count.
2. Start a fresh adapter from the reopened binding. Assert the actual fixture RPC parameters use the old topic key with a new run and **no sessions.create request**.

The full suite also reran the existing same-topic follow-up, active/unadmitted steering, queued amendment, completion/receipt race, one-active-task exclusion, scoped memory writing and cross-topic memory/history-isolation cases.

## Actual verification

```sh
./scripts/test_native.sh
```

**35 native tests passed, 0 failures; process exit 0.** Receipt: `build/topic-binding-review-tests.log` (2026-10-07 19:02 JST). Real GRDB/SQLite/filesystem state is used; model and Gateway transports remain explicit fixtures. An initial shell wrapper hit zsh's reserved `status` variable after the tests finished; the corrected wrapper was rerun and exited cleanly.

No production/native runtime source edits were needed. Prior worker-memory and human-readable sub-chat-title implementations were reviewed rather than duplicated. No owner-active app/window/history was touched; no app launch, new live model/Gateway call, global configuration change or publishing.

**Live remote binding/history reuse remains unverified.** The exec-attribution prohibition stays controlling. These tests do not establish real strict-steering admission, provider context retention, or live tool confinement. Current native QA/disclosure work remains separate.
