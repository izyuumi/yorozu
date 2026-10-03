# Secretary 0.6 acceptance audit

Reconciled 2026-10-03 from the accepted conversation audit supplied by the owning
task. This is an acceptance checklist, not a claim of complete implementation.
The installed baseline remains `fb90c0a` / Mac build 10264 until an explicitly
verified internal update is installed while user work is idle.

The core journey is: delegate task A, discuss unrelated B while A runs, steer A,
observe the changed result, and receive that result once in its original context.
Changing an activity indicator or labeling a subprocess a worker does not satisfy
this journey. A provider receipt is evidence of receipt, not evidence that a
requested change was applied.

## Evidence as of the first checkpoint

`8ce3527e79802bf76dc092a7582a20b643000b29` is signed and pushed to the internal
`integration-0.6-worker` branch, draft PR300. GitHub verifies its signature. Actual
Claude Code Opus 5.5 reviewed the production delta and strengthened test delta,
with no remaining blockers, standard speed and fast mode off.

Five focused Swift tests pass. Removing the quiet-mode early return makes two
expectations fail; restoring it passes. Eight isolated native fixture captures
cover working, details, approval, error in English/Japanese, completed,
unconfirmed Stop, and running after an earlier unconfirmed Stop. These are native
synthetic fixtures, not proof from the user's installed live task. Raw tool
payloads are hidden by default; More exposes retained diagnostics. Retired
approval cards no longer leave a false waiting label in any ChatView.

## Accepted requirements

| ID | Requirement | Current evidence / remaining acceptance |
|---|---|---|
| R01 | One continuing conversation across topics | Main thread exists. Nonblocking cross-topic continuity remains missing. |
| R02 | Every execution is a specialized independent worker | Current Rust bridge is serial. Require two actual workers plus a main reply before either finishes. |
| R03 | Bounded recursive delegation and upward reporting | Unverified. Require parent IDs, cancellation, child failure propagation and exactly-once results. |
| R04 | Real Steer, no Queue/Steer choice | Existing secretary declines live steering. Require same-run provider receipt, changed file result, disconnect test and no uncertain replay. |
| R05 | Distinguish new topic from targeted correction | Missing integrated proof. Ambiguous targets must be clarified; never inject a new topic into an arbitrary worker. |
| R06 | Quiet tools, three dots, useful milestones and final | Source implemented in `8ce3527`; focused tests and native fixture evidence above. Actual isolated app journey and disconnect remain to verify. |
| R07 | Persistent advanced diagnostics and model settings | Diagnostics implemented. Complete provider/model settings journey remains unverified. |
| R08 | Task conversations and progress details | Existing History is not yet an integrated secretary task view. Direct user chat inside workers is deferred. |
| R09 | Routine autonomy by default within granted access | Do not equate this with bypassPermissions. Required approvals and setup/OS boundaries remain mandatory. Fresh-profile behavior unverified. |
| R10 | Learn corrected stable preferences | Unverified. Latest correction must win across topics/relaunch; memory cannot grant authority. |
| R11 | Durable accepted IDs, truthful terminal/Stop/reconnect | Baseline covers specific journeys. App quit can leave an unconfirmed hold; explicit safe reconciliation still missing. |
| R12 | Preserve history, connections, settings and languages | Prior baseline preservation verified by release owner. Every new install requires fresh idle snapshot and post-install checks. |
| R13 | Bounded relevant memory, SQLite operations + Markdown knowledge | No established integrated FTS/Markdown synchronization. Do not resume the paused migration or overwrite user notes. |
| R14 | Supported account access before API keys | Official Codex account path works in baseline. Clean-profile onboarding and expired-login journeys remain unverified. |
| R15 | Separate provider, model and worker identity; one Yorozu | Main secretary exists; complete removal of backend-agent choices from new-work flow unverified. Preserve legacy history. |
| R16 | Opt-in managed CLI updates, idle checks and rollback | Unverified. No authority to mutate installed CLIs merely to check this row. |
| R17 | Native responsive layout and consistent EN/JP | Narrow baseline and indicator fixtures verified. Full window/large-text/settings/error matrix unverified. |
| R18 | Correct composer, drafts, replies, rich attachments | Older slices/prototypes exist. Current caret/IME/paste/drop/attachment-only journey remains unverified. |
| R19 | Responsive long-history send/render | Baseline redraw improvement reported (608 to 178 ms worst case). User's exact freeze not sampled; preserve baseline and replay representative JP history. |
| R20 | Host-only permission setup, quiet client launch | Baseline PR290 fix retained. Fresh OS dialog matrix unverified; never silently grant permissions. |
| R21 | Dedicated computer-use worker, bounded context and evidence | Prior adapters do not prove integrated live journey. Require safe native task, blocked permission and cancellation proof. |
| R22 | Mac-first shared desktop, no competing clickers | Scope constraint. No new Cua Spaces dependency or cursor-arbitration product. |
| R23 | Real schedules, scoped discussion, details and history | Prototype only is not acceptance. Authorized backend integration remains unverified; no fabricated live schedules. |
| R24 | Results anchored once to original tasks | Multiworker/out-of-order/reconnect projection unverified. |
| R25 | Work independent of UI availability | Distinguish window close, app quit and crash. Baseline quit can hold uncertain work; never falsely complete or blindly replay. |
| R26 | Signed incremental pushes, actual final Opus review | First checkpoint meets source/signature/review requirements. Exact-commit CI and release are separate gates. |
| R27 | Internal-only same-app update preserving data | New source not installed. Never stop live work for deployment; public 0.5 feed/main untouched. |
| R28 | Standard development service tier | Opus reviews standard/fast off. No ultrafast requested. |
| R29 | Distinct approved native icon | Held separately; disputed mark must not ship to fill this row. |
| R30 | Preserve native palette scope | Website palette is not permission to restyle native app or PRIVATE DESK. |

## Exclusions and release gates

Do not implement speculative backend rewrites, standalone Rust SDK extraction,
unrequested voice APIs, personal vault conventions, or ELM business terms as
mandatory 0.6 features. Protected recovery experiments remain excluded.

Each source slice needs a coherent signed commit, exact-source tests and CI,
actual Opus 5.5 final review, and native evidence for changed visible behavior.
An internal update additionally needs idle/live-task checks, preservation backup,
artifact verification, and post-install confirmation. Preserve the current app
while any user execution is active. Incomplete accepted rows stay explicitly
unfinished; no blanket 0.6-complete claim.
