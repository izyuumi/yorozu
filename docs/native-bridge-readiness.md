# Native agent bridge pre-release audit — 2026-09-20

Live issues #4–#12 were read with `gh issue view --repo izyuumi/yorozu`. This records release readiness for #12; it does **not** claim #12 is complete. Current user instructions prohibit release and PAIOS edits, overriding the issue’s standing always-release preference. No issue closed, release published, bundle installed/launched, or PAIOS file changed.

Preserved local commits: `42f431f` (#4), `419ffc5` (#5), `4ac5c5a` (#6), and `36ae3df` (agent images). All remain ancestors of main. Unrelated worktrees remain untouched. New commits are sequential: `0e3bdd6` (#7), `b6e9bf0` (#8), `8d45e93` (#9), `8e9b098` (#10), `83bf186` (#11). This document is the #12 preflight commit; UI/performance fixes are committed separately.

## Acceptance ledger

Every live acceptance criterion is retained below. Automated logic coverage is distinguished from source inspection, rendered screenshots and unperformed device checks. Device/release checks are pending, never treated as passed by a fake SDK or simulator compilation.

### #4 — Claude Code thread: one turn, reply only

| Criterion | Evidence / remaining validation |
| --- | --- |
| Prompt in a `claude-code` thread produces a final agent message from Claude Code | native.test.ts run/final-message; serve.test.ts encrypted native turn |
| Claude Code's native session id is stored per thread; a later prompt resumes it and Claude Code remembers earlier turns | native.test.ts resume; serve.test.ts persisted session/resume |
| Working directory is the thread's `cwd` and never changes for the thread's life | threads.test.ts immutable metadata; native.test.ts cwd passthrough |
| Interrupt aborts the SDK query; the next prompt still resumes the same session | native.test.ts abort; serve.test.ts Stop/session retention |
| Unlimited concurrent `claude-code` threads each own their own process | serve.test.ts three concurrent threads, independent cancellation; runner creates one Query/connection per invocation, no global limit |
| Yorozu's own tool dispatch and `actionClass` gate are not involved in these threads | serve.test.ts native routing bypasses OpenClaw/rules; native permission tests |
| Tests cover run, resume, and abort with a fake SDK | native.test.ts fake Query suite |

### #5 — Project folder picker and agent badge in thread list

| Criterion | Evidence / remaining validation |
| --- | --- |
| New-thread flow: agent choice, then folder choice for coding agents, two taps for a recent folder | ChatModelTests coding-draft wire ordering; NewThreadSheet source audit. Two-tap UI needs interactive device check |
| Mac publishes its known project folders and recents to paired devices; folder contents never leave the Mac | projects.test.ts folders/recents/no contents; serve.test.ts project publication and invalid cwd |
| Thread row shows agent indicator and repo subtitle for non-Yorozu threads; Yorozu threads unchanged | ThreadListView/ThreadSummary source audit; EventTests native/ordinary wire forms. Visual/VoiceOver device check pending |
| Filter by agent in thread search | ChatModelTests searchLooksAtTheTitleThePreviewAndTheThreadItself tests Claude/Codex/ordinary agent and repo filtering; ThreadListView source audit |
| VoiceOver reads the agent and repo | ThreadListView accessibility label source audit. Physical VoiceOver check pending |
| Showcase scenes updated for iPhone and Mac | Existing iOS/Mac showcase source preserved; source builds pass. Alternate showcase bundles not launched |

### #6 — Claude Code trace with truncated tool results

| Criterion | Evidence / remaining validation |
| --- | --- |
| Thoughts, tool calls and results from the SDK stream map to existing trace events | native.test.ts stream mapping; Codex adapter tests; AgentTraceTests grouping |
| Results above the cap are truncated and marked; full content stays on the Mac | threads.test.ts boundary/stash and surrogate safety; serve.test.ts truncated delivery |
| Tapping a truncated result fetches and shows the full content; works after relay reconnect | serve.test.ts large Unicode chunks after sync (both agents); ChatModelTests reassembly/retry/reconnect cleanup |
| Truncated previews never appear in notification text beyond the existing preview limit | packages/shared/src/notify.test.ts: truncated results never notify; completed-reply UTF-8 byte limit tested |
| Tests cover mapping and truncation boundary | native.test.ts, threads.test.ts, AgentTraceTests |

### #7 — Claude Code approvals and questions passthrough

| Criterion | Evidence / remaining validation |
| --- | --- |
| SDK permission request becomes an approval card; Allow/Deny returns to the SDK and the turn continues or the tool is refused | native.test.ts allow/deny; both-agent encrypted-relay approval tests; native card screenshots |
| Pending approval holds the turn; lockscreen quick actions work | Pending callbacks tested; encrypted notification-source answer and DrainTests lockscreen path. Actual APNs/locked-iPhone check pending |
| Multiple-choice question becomes a question card; chosen option or free text returns to the SDK | native.test.ts option/free text; bypass-independent PreToolUse tests; serve.test.ts question round trip |
| No `actionClass` rules, floors or proposals are consulted or created for `claude-code` threads | serve.test.ts YOLO enabled yet native card still asks; rule store/proposals remain empty |
| Tests cover approve, deny, question answer, and abort while pending | native.test.ts pending approve/deny/question/abort; Codex mirrored cases |

### #8 — Per-thread bypass toggle for native agent threads

| Criterion | Evidence / remaining validation |
| --- | --- |
| Thread-level bypass flag persisted and synced to all devices | threads.test.ts flag persistence; serve.test.ts toggle sync |
| Toggle visible in thread settings on Mac and iPhone for coding-agent threads only | ChatView native-only Menu toggle; ChatModelTests ordinary/native guard. Mac/iOS builds pass; physical iPhone toggle check pending |
| On: SDK runs in bypass mode; off: approvals passthrough as before | native.test.ts SDK mode and Codex policy tests |
| Global YOLO does not affect coding-agent threads and vice versa | serve.test.ts native bypass/global YOLO isolation for both agents |
| Tests cover toggle on/off mid-thread | serve.test.ts toggles during resumed threads; native.test.ts and codex-native.test.ts |

### #9 — Interrupted-turn recovery for native agent threads

| Criterion | Evidence / remaining validation |
| --- | --- |
| Running native turns are recorded durably; on startup, unfinished ones become interrupted cards | threads.test.ts startup recovery and terminal-message handling; serve.test.ts durable marker/shutdown queue guard |
| No prompt is resent without the user tapping Continue | serve.test.ts restart without replay and stale Continue rejection |
| Continue resumes the same native session and the turn completes normally | serve.test.ts same-session Continue for both agents; pre-init crash explicitly nonresumable instead of starting a different session |
| Dismissing the card leaves the thread usable for new prompts | serve.test.ts dismiss followed by new prompt for both agents |
| Tests cover restart mid-turn and continue | threads.test.ts and serve.test.ts startup/Continue cases; ChatView recovery control source audit |

### #10 — Model and effort pill for native agent threads

| Criterion | Evidence / remaining validation |
| --- | --- |
| Model list published per agent alongside the existing model list | native.test.ts Claude catalog; codex-native.test.ts catalog/default; serve.test.ts agentModels publication |
| Pill and sheet show the agent's models only; effort levels map to the SDK's | ChatModelTests agent-specific choices; native Menu/Pickers source/build audit; physical picker/keyboard check pending |
| Selection persists per thread and applies to the next turn | serve.test.ts model/effort persistence; ChatModelTests draft ordering |
| Tests cover model and effort passthrough | native.test.ts and codex-native.test.ts SDK/API passthrough |

### #11 — Codex thread parity

| Criterion | Evidence / remaining validation |
| --- | --- |
| `codex` thread runs a turn and resumes the native thread on later prompts | codex-native.test.ts start/resume; mirrored serve.test.ts encrypted native turn |
| Approval and question events map to the same cards; answers return to Codex | codex-native.test.ts approval/question response; mirrored encrypted-relay tests |
| Per-thread bypass maps to Codex's bypass mode | codex-native.test.ts never/danger-full-access and on-request/workspace-write toggles |
| Trace, truncation, interrupted-turn card, and model/effort pill behave as for Claude Code | Mirrored serve.test.ts trace, large-result, recovery, catalog tests; shared Swift tests |
| Stop aborts via SDK and keeps the thread resumable | codex-native.test.ts turn/interrupt, pending-card abort and session retention |
| Tests mirror the Claude Code suite with a fake Codex SDK | Fake App Server connection mirrors fake Claude Query cases. See SDK limitation below |

### #12 — Release native agent bridge

| Criterion | Evidence / remaining validation |
| --- | --- |
| Mac build notarized, published, installed and running | PENDING — signed/notarized/published/installed/running release forbidden by current instruction |
| iOS build VALID in Internal TestFlight | PENDING — TestFlight upload/VALID validation forbidden by current instruction |
| On the physical iPhone: create a Claude Code thread, get a reply, answer one approval from the lockscreen | PENDING — requires physical iPhone: create Claude Code thread, receive reply, answer lockscreen approval |
| PAIOS project record updated with build number and evidence log | PENDING — PAIOS modification explicitly forbidden |

## Validation results

| Command / check | Result |
| --- | --- |
| `pnpm -r build` | All three TypeScript projects pass |
| `pnpm -r test`, then runtime rerun after adding parity/concurrency cases | Shared 29, relay 95, runtime 558 pass |
| Runtime optional browser integration | One pre-existing opt-in test skipped because `YOROZU_BROWSER` is unset; unrelated to native-agent acceptance. No browser bundle launched |
| `env -u SDKROOT swift test --package-path packages/shared-swift` | 165 tests pass |
| `env -u SDKROOT swift test --package-path apps/mac` | 7 tests pass |
| `env -u SDKROOT swift build --package-path apps/mac -c release` | Pass; source build only |
| `xcodebuild … -scheme YorozuKeyboardUITests -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build-for-testing` | Pass; UI interactions not executed |
| `xcodebuild … -scheme YorozuIOS -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build` | Pass; unsigned device build only |
| Independent standards and acceptance reviews | Both green after fixing all reported material findings |
| Offscreen screenshot harness and Time Profiler | Four screenshots; zero ≥250 ms recorded hangs. [Performance evidence](native-ui-performance.md) |

Logs are local `/tmp/yorozu-all-build.log`, `/tmp/yorozu-all-tests.log`, `/tmp/yorozu-final-runtime.log`, `/tmp/yorozu-final-swift.log`, `/tmp/yorozu-mac-tests.log`, `/tmp/yorozu-mac-build.log`, `/tmp/yorozu-ios-ui-build.log`, `/tmp/yorozu-ios-device-build.log`, `/tmp/yorozu-harness.log`. No release scripts ran. Existing compiler warnings are not errors.

## Native protocol decisions

Installed `@openai/codex-sdk` 0.154.0 exposes one-way exec turns without the interactive approval/question response channel required by #11. The bridge uses Codex’s official stdio [App Server protocol](https://developers.openai.com/codex/app-server/) through a small dependency-free connection adapter. Start/resume, model/list, approval/questions, native bypass, turn/interrupt and event mapping are covered with a fake connection. Thus “via SDK” is implemented via the supported native protocol, not claimed as TS-SDK support. Metadata-only smoke checks returned live Claude and Codex catalogs; no real coding turn was submitted.

Claude’s [PreToolUse decision hook](https://code.claude.com/docs/en/hooks#pretooluse-decision-control) supplies AskUserQuestion answers independently of bypass; relying only on canUseTool loses questions when permission checks are skipped. Session IDs stay on the Mac. Interrupted runs with no session ID explain that Continue is unavailable and allow Dismiss/new prompt.

## Release hold

All four #12 criteria remain unchecked. Before later release authorization, physical iPhone must validate create-thread/folder selection, live reply and resumption, native permission Allow/Deny from the lockscreen, model/effort and bypass sync with Mac, interrupted-turn Continue/Dismiss, large-result retrieval after reconnect, and sustained scrolling/typing under streaming. Check VoiceOver, Reduce Motion and keyboard/IME behavior on device. These are limitations of current evidence, not silent acceptance waivers.
