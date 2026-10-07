> **20:00 superseding update:** owner launched Live-R1; greeting failed. Source-confirmed CLI model-override defect repaired; 45 tests pass; separate `PROJECTX-Live-R1-transport-fix.app` staged. Waiting coordinated patched-app test, not initial owner launch. See [transport repair](LIVE_TRANSPORT_REPAIR.md). Prior evidence below retained.

# Native R1 consolidation — 2026-10-07

## Current live-repair status — 19:54 JST

**Waiting owner-independent launch of `build/PROJECTX-Live-R1.app`, then parent UI test.** 44 Swift tests pass; real dedicated-projectx Astra greeting and Sol substantive-answer probes succeeded through native attributed tools. App connection, remote topic reuse and strict steering remain unverified. Direct native WS enrollment is implemented but unpaired; default uses configured credentials. See [controlling final repair receipt](LIVE_VERIFICATION.md). Earlier counts and implementation limits below are the preserved consolidation checkpoint, superseded where this receipt explicitly records a change.

## Authority and stack

Implements owner decisions through **18:10 JST / message 1791364241989**. The 18:07 stack-discussion pause was respected on receipt, and work resumed after approval. `OWNER_DECISIONS.md` was preserved, not rewritten. This is one consolidated local implementation, not a claim that previously queued workers completed their assignments.

Approved runtime: SwiftUI/selective AppKit → Swift actor core → GRDB/SQLite; canonical hierarchical Markdown → separate rebuildable SQLite/FTS5 discovery; Swift OpenClaw-first harness adapter. No Python/HTTP/WebKit in the native app.

## Files and architecture

| File | Responsibility |
|---|---|
| `Sources/ProjectXApp/ProjectX.swift` | Three-pane native layout, single main composer, inspect-only topic pane, app lifecycle; direct Swift actor calls |
| `Sources/ProjectXCore/Models.swift` | Typed messages/topics/work/amendments/events/harness contracts |
| `Sources/ProjectXCore/Store.swift` | GRDB migrations, exclusive workspace lease, transactional state transitions, preserved messages, revision/suppression-safe completion, restart uncertainty |
| `Sources/ProjectXCore/Engine.swift` | Ordered secretary routing, one escalation, two asynchronous workers, serial background extraction, correction/steering/retry/forget |
| `Sources/ProjectXCore/Memory.swift` | Canonical Markdown, evidence/provenance, cross-topic FTS5 discovery, descriptor-confined read/CAS-write, conflict/index receipts, targeted forget |
| `Sources/ProjectXCore/Harness.swift` | Offline and labeled synthetic adapters; Swift configured-Gateway transport, persistent topic sessions, strict steering, cancellation/status checks, public event projection, bounded memory-tool bridge |
| `Tests/ProjectXCoreTests/` | Real local storage/filesystem + synthetic harness/transport regression tests |
| `scripts/build_native.sh`, `scripts/test_native.sh` | Project-local dependency/build/test caches, release `.app`, local ad-hoc signature, reproducible checks |

### Topic/session/task separation

Topics own stable UUIDs and Gateway keys `agent:<agent>:projectx:<topic UUID>`. Distinct work records hold task IDs, run IDs, revisions and results. Returning after completion starts new work in the **same** topic session; admitted amendments preserve the task. Per-topic active/uncertain exclusion and two total worker lanes prevent accidental concurrent turns in a growing session. New topic selection is broad-subject biased, bounded candidate retrieval with latest-user-topic default and one stronger-model clarification review. Background completion does not change the active user discussion.

No custom compaction, context-refresh scheduler or topic merge/split was introduced. Bounded app inputs do not truncate the existing harness session or guarantee its total history size.

### Corrections, steering and uncertainty

A correction commits suppression of the mistaken task **before** requesting cancellation. The intended-topic message is new; previous message bodies and topic placement are untouched. Acknowledged abort, cancellation-requested, uncertain, superseded and current completion remain distinct. A late handle, local exception or event cannot erase suppression or turn an unconfirmed remote stop into a confirmed cancellation.

Before a queued worker starts, amendments are attached to its existing task input/revision; no second task/session is created. Local queued cancellation is acknowledged transactionally before any harness invocation. Once active, steering uses strict `sessions_send(mode=steer)` through `tools.invoke`; there is **no idle `chat.send` fallback**. Admission is not incorporation. Latest revision plus admitted amendment receipts are required for a main final answer. Completion-before-receipt is reconciled transactionally. Unconfirmed final output stays inspect-only with a main explanatory notice, not a false success.

Failure/lost connection creates a main notification. User-requested retry checks the prior run; unknown/running refuses dispatch. A terminal error needs a numeric terminal timestamp, not an observation timeout. Successful reconciliation can deliver the prior result without launching again. Restart marks formerly active work uncertain and does not auto-replay. A successful wait response without a safely attributable final output remains **unknown** in the current Gateway adapter; it does not guess the last reply in a growing chat.

Follow-up QA fixed active intended-topic correction: after stopping/suppressing mistaken work, re-read the intended task and automatically use the existing steering path for working, queued or amendment-pending work. An **uncertain** intended task stays uncertain: its correction is saved as `pending_reconciliation`, without claiming steering or launching a duplicate. A user-requested retry after confirmed stop includes saved instructions. A task already being cancelled is not resurrected. Unsupported/idle strict steering remains pending rather than silently starting replacement work.

### Memory and worker writes

Markdown metadata retains source IDs, exact evidence, attributed knowledge type/status and prior-body lineage. Generated knowledge is not a user belief or a verified fact. User facts require a matching direct-user quote; recognized pasted/reported content cannot pass as a direct belief. Cross-attribution/type overwrites are refused. This is bounded schema/evidence validation, not semantic entailment proof.

Worker capability is **actual application-mediated full Markdown editing**, not a read-only description or queued suggestion: `memory.search`, `memory.read`, `memory.write`. Requests execute against a fixed app-owned memory root and return the real result in the same growing harness session. There is no generic filesystem/chat edit operation. Expected SHA-256 is mandatory for replacement; nil means creation only. UUID/path checks, `openat`/`O_NOFOLLOW`, regular-file/single-link checks, `flock`, atomic rename, protected provenance/lineage and index refresh are implemented. At most six operations per invocation. Failed or conflicted writes are not reported as success. A successful file write with index failure reports `indexed=false`, avoiding write replay.

This supports worker-directed file contents while native harness permission stays read-only. It is **not unrestricted native filesystem authority**, nor a claim the Gateway effective tool surface has been verified. Generic native tools and unrelated files are not authorized. Live verification of that confinement is a release gate; prompt instructions alone are not an OS sandbox.

Index discovery stores only ID/title/summary/relative path and FTS5 terms. Selected content is always reread from Markdown. App writes refresh; restart rebuilds external edits; no watcher. Memory is global, with topic IDs only provenance. Forget fences previously queued extraction, deletes the target file/index, and preserves original chat. Processed extraction receipts are never replayed on rebuild/startup. No suppression ledger or memory dashboard.

Residual limits: cooperative writer locking cannot eliminate the final race with an external editor ignoring the lock; lexical FTS misses paraphrases and some non-space-delimited text; malformed/symlink memory fails closed; large lineage or contexts fail boundedly; secret filters are heuristic. Existing Python metadata differs from Swift metadata; no silent migration/import is performed.

## Verification evidence

Environment: Apple Swift 6.4 (`swiftlang-6.4.0.34.1`), arm64 host, Xcode `/Applications/Xcode.app/Contents/Developer`. GRDB 7.8.0 pinned to `18497b68fdbb3a09528d260a0a0e1e7e61c8c53d`. Swift package/macOS target 14+; tested only on this current host.

**33 Swift XCTest cases pass**, using native code, real GRDB/SQLite/FTS5 and filesystem writes. Coverage:

- Durable topic/session identity; per-directory lease and per-topic exclusion.
- Main reply while workers run, two worker lanes plus queued third, main-vs-inspection progress placement.
- Same-session continuation after completion; separate task identities.
- Same-task steering, stale/unadmitted results, completion/receipt race and deduplication.
- One ambiguity escalation then clarification without dispatch.
- Wrong-topic cancellation/suppression with immutable historical placement; unacknowledged cancellation honesty; late-handle/start/failure races.
- Failure notification, uncertain retry refusal, stopped-run retry in the same sub-chat, restart uncertainty/no replay.
- Actual worker-requested full Markdown writes through a transport fixture, same-session tool-result continuation, path traversal/symlink/hardlink/history-operation refusal, stale-hash conflict, lineage and derived-index refresh.
- Automatic quoted-source and generated topic retention, attribution/credential checks, cross-topic memory without foreign-topic conversation, conversational forget preserving chat, no rebuild/startup replay.
- Environment attribution guard, exact session-creation/worker wire contract, strict-steer refusal/no alternate dispatch, cancellation receipt and nonterminal timeout handling, reasoning/tool-argument/credential exclusions.
- Offline honesty and fixture/live workspace separation.

**60 Python prototype unittest cases also pass**, plus Python compilation. Those tests are preserved design evidence, not substitutes for Swift tests. Both sets used repository-local temporary directories for this consolidation.

Release `.app`: `build/PROJECTX.app`; plist lint and `codesign --verify --strict` pass with a local ad-hoc signature. `otool -L` shows native Apple/Swift/SQLite libraries; no Python runtime dependency. No Python/web payload is bundled. GRDB privacy resource bundle is included. Logs and executable SHA-256 are in `build/`.

**Build evidence is not usable acceptance:** the follow-up explicitly launched only the synthetic fixture and inspected its exact native window through Cua. `build/uiqa-initial.png` confirms the initial layout and small mode label. The parent/owner began using that window; this worker issued no input and stopped UI inspection to avoid contention. The owner then reported odd replies: they were scripted fixture replies, not an LLM. The disclosure was too subtle and is now fixed in a separately staged bundle with an unmistakable title/banner and acknowledgment-gated test input. That new UI still needs coordinated visual confirmation. See `QA_1843.md`.

## Remaining live gates — controlling, not reauthentication

The existing exec restriction in `GATEWAY_REVIEW.md` remains controlling. Swift checks both `OPENCLAW_SHELL=exec` and presence of `OPENCLAW_SUBAGENT_EXEC` before Gateway subprocesses; inherited environment is preserved. No live model calls, marker removal, HTTP alternate path or native/terminal UI escape occurred. The only native launch was explicitly `PROJECTX_MODE=fixture`, with inherited attribution environment preserved. Existing configured authentication was already proven working.

Outstanding live acceptance, in a legitimately authorized attributed caller context:

1. Exact Swift app secretary → worker roundtrip, selected configured models and persisted same-topic continuation.
2. Effective worker native-tool confinement; no private bootstrap/session import or unrelated tools/files. Read-only native permission plus prompts are not a proof of narrow tool confinement.
3. Actual strict-steer exposure/admission/incorporation and race behavior; no global tool-policy change is authorized by this implementation.
4. Actual `chat.abort` acknowledgment; `agent.wait` run-ID/terminal payload semantics, including recovery of a completed answer. Unknown response shapes remain blocked rather than guessed.
5. Committed public progress/event delivery. Current polling snapshots at most 40 messages every two seconds, exclude the pre-run baseline, and can miss ephemeral or burst events; this is not token streaming.
6. Live semantic routing/extraction quality, model-role quality/cost, data migration if desired, and native visual/interaction acceptance.

No credentials, account/config changes, publishing, remote Git changes or private PAIOS/session imports were performed. No commits were made. The task’s earlier accidental empty `/tmp/projectx-noop` file was disclosed to the parent; no private data was written there and it is not a runtime dependency.

## Original checkpoint receipt — retained historical evidence

- Release build finished successfully; `plutil -lint` and `codesign --verify --strict` passed.
- Executable SHA-256: `b4cdac2c2b358b58f1b6781d440cce68944a392dc53ab80cb88ecb70fec17d40`.
- Latest native test receipt: 26 XCTest cases, 0 failures (2026-10-07 18:39 JST); logs in `build/swift-test.log`.
- Python prototype receipt: 60 cases, 0 failures; logs in `build/python-prototype-tests.log`.
- Bundle audited: arm64 Mach-O, SwiftUI/native Apple/SQLite links, GRDB privacy resource; no Python/web payload. Not launched.

## 18:43–18:55 follow-up

Current bounded QA: **33 Swift tests pass**, including working/queued/pending/uncertain correction forwarding and explicit fixture-disclosure/input-consent cases. Latest new bundle is staged as `build/PROJECTX-QA-fixed.app`; the owner-active older `build/PROJECTX.app` was not replaced. Original checkpoint remains `build/checkpoints/r1-1843/`. Build now refuses to overwrite a running app. See `QA_1843.md` for the synthetic-mode confusion correction, actual observed UI evidence, active-window ownership and remaining acceptance gates.
