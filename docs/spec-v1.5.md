# Yorozu v1.5

## Problem Statement

Yorozu can already run a personal assistant on a Mac and control it from an iPhone, but four gaps keep it from working as a dependable daily driver. The phone must remain foregrounded to learn that work finished or needs approval. Long threads silently lose context beyond the latest 40 messages. The Codex provider cannot use Yorozu tools. Approval behavior is broad, partly inferred from history, and unable to represent precise reusable authority or batches.

## Solution

Version 1.5 makes remote work dependable without changing Yorozu's local-first, blind-relay architecture:

- APNs wakes the iPhone for replies, approvals, task completion, and failures and deep-links to the relevant thread or approval.
- Each thread maintains a rebuildable rolling summary of context that leaves the active message window.
- Yorozu exposes its existing tool catalog to Codex through a local MCP bridge; the runtime remains the sole dispatcher and approval gate.
- The approval engine stores explicit global rules, proposes narrowly scoped rules after repeated approvals, supports exact batches, retains hard confirmation floors, and lets unrelated branches continue while one branch waits.
- The standard iOS composer remains compatible with Apple's free native dictation. No custom voice pipeline is added.

## User Stories

1. As an iPhone user, I want a notification when Yorozu finishes work, so that I do not need to keep the app open.
2. As an iPhone user, I want approval requests delivered promptly, so that blocked work can resume.
3. As an iPhone user, I want notifications for task failures, so that silent failures do not go unnoticed.
4. As an iPhone user, I want tapping a notification to open its exact thread or approval, so that I can act immediately.
5. As a privacy-conscious user, I want the relay and APNs payload to reveal no conversation content, so that the blind-relay promise remains true.
6. As a multi-device user, I want notification registrations to be revocable per device, so that removed devices stop receiving wakes.
7. As a user in a long conversation, I want Yorozu to remember earlier decisions after they leave the active window, so that I do not repeat myself.
8. As a user, I want summaries to preserve preferences, commitments, unresolved work, corrections, and tool outcomes, so that continuity remains accurate.
9. As a user, I want recent verbatim messages alongside older summarized context, so that current nuance is not compressed prematurely.
10. As a user, I want the original transcript to remain authoritative, so that a bad summary never destroys history.
11. As a user, I want summaries to be rebuildable, so that format or model improvements can repair old summaries.
12. As a user, I want summary failure to leave my thread usable, so that compaction never blocks conversation.
13. As a Codex user, I want Codex to call the same tools as other providers, so that provider choice does not remove agent capability.
14. As a user, I want every Codex tool call to pass through Yorozu's dispatcher, so that logging and approvals remain consistent.
15. As a user, I want provider fallback to retain existing behavior, so that MCP failure before output can advance the chain safely.
16. As a user, I want read-only actions to proceed without prompts, so that ordinary work stays fast.
17. As a user, I want exact approval cards, so that I see recipient, account, amount, content, operation, and consequences before committing.
18. As a user, I want to allow one action, a bounded task, or a reusable rule, so that authority matches intent.
19. As a user, I want reusable rules to cover narrowly scoped external actions, so that routine work can run unattended.
20. As a user, I want rules to apply across all agents, so that delegation does not change authorization.
21. As a user, I want accepted rules to persist until revoked, so that Yorozu does not nag me periodically.
22. As a user, I want Yorozu to propose a reusable rule after repeated matching approvals, so that it learns without silently granting itself authority.
23. As a user, I want to review or edit a proposed rule before activation, so that inferred scope cannot become authority by itself.
24. As a user, I want deny rules to win ambiguous conflicts, so that uncertainty fails safe.
25. As a user, I want to approve an exact visible batch, so that repetitive work needs one informed decision.
26. As a user, I want changed or added batch items to require approval, so that consent cannot be stretched after the fact.
27. As a user, I want capped routine purchases to use reusable merchant or category rules, so that low-risk shopping can be automated.
28. As a user, I want subscriptions, transfers, securities trades, and crypto transactions to require final confirmation, so that consequential financial actions remain deliberate.
29. As a user, I want changed price, quantity, recipient, or account details to invalidate approval, so that I approve the transaction actually submitted.
30. As a user, I want the whole turn to pause while an approval is pending, so that nothing lands while I am reading the card. (Revised 2026-09-18: replaces "independent branches continue"; with approvals answerable from the lock screen the wait is seconds, and a paused world is easier to trust.)
31. As a user, I want an audit trail showing which rule authorized each automatic action, so that I can understand and revoke behavior.
32. As an iPhone user, I want Apple's native dictation to work in the composer, so that voice entry is available without a custom service or fee.

## Implementation Decisions

- Preserve the current JSONL transcript as thread truth. Store summary checkpoints separately with the covered event boundary, summary version, and generation metadata.
- Build prompt context from the latest valid summary plus verbatim messages after its boundary. Keep the current recent-message window as the uncompressed tail.
- Update summaries incrementally when messages age out of the tail. Summary generation failure leaves the prior summary and complete transcript intact.
- Summary content prioritizes decisions, preferences, corrections, entities, commitments, open questions, task state, and meaningful tool results. It excludes hidden reasoning and redundant conversational filler.
- Expose the existing Yorozu tool definitions through a local stdio MCP server used only by the Codex adapter.
- Codex MCP calls become normal runtime tool-call events. The runtime, not Codex, executes tools, applies approval policy, records outcomes, and returns tool results.
- Do not build a second tool catalog or a Codex-specific permission system.
- Register APNs device tokens through the encrypted paired channel. Store token ownership per paired device and remove it when that device is revoked.
- Push payloads contain opaque routing identifiers and event class only. Message text, tool arguments, approval details, and summaries remain end-to-end encrypted and absent from relay-visible payloads.
- Notification classes are reply, approval-required, task-complete, and task-failed. Tapping routes to the exact thread and, when relevant, approval card.
- Approval rules are global across agents and match structured action scope rather than agent identity or chat prose.
- Supported decisions are allow once, allow for bounded task, always allow under an explicit rule, deny once, and persistent deny.
- Reusable external-action rules must be narrowly scoped. Blanket authorization across every external action is unsupported.
- After approximately three matching explicit approvals, Yorozu may propose a reusable rule. The proposal never activates until the user accepts or edits it.
- Accepted rules persist until revoked. Settings exposes scope, recent usage, edit, and immediate revoke.
- Most-specific matching rule wins. At equal specificity, deny wins. Non-overridable safety floors win over stored rules.
- Routine purchases may use merchant or category rules with amount caps. Subscriptions, transfers, securities trades, and crypto transactions always require final confirmation.
- Any change to price, quantity, recipient, account, or batch membership invalidates the applicable approval.
- Approval cards describe the concrete commit payload and consequences, not underlying browser or tool mechanics.
- A batch approval is bound to the exact displayed item set. It cannot authorize later additions or mutations.
- A pending approval suspends the turn. Nothing else executes until the card is answered.
- Visiting a URL (`fetch`, `browser.open`) is its own action class, `visit-url`: allowed by default, fenceable by a `never` rule, and always confirmed fresh when the URL itself looks like it acts on arrival (a token or code in the query, or a confirm/verify/unsubscribe/activate/reset/magic/login/auth path).
- Every decision and automatic execution records actor, action class, structured scope, matched rule, reason, timestamp, and outcome without secrets.
- Use the native iOS text-input dictation path only. No microphone capture, transcription model, audio storage, or third-party voice service is added.

## Testing Decisions

- Test externally observable behavior at existing high seams; do not introduce a new test framework.
- Runtime integration tests exercise a full turn with an existing summary plus recent messages, a Codex MCP tool call through the runtime dispatcher, structured approval evaluation, exact batches, rule proposals, and the `visit-url` default, fence and fresh-confirmation cases.
- Thread tests prove summary boundaries never omit or duplicate messages, old summaries rebuild, transcript truth survives failed generation, and recent messages remain verbatim.
- Approval tests cover specificity, deny-on-tie, global use across delegated agents, persistent rules, proposal-without-auto-activation, financial floors, mutated transactions, batch binding, audit records, and revocation.
- Relay tests prove a registered device receives an opaque wake event, revoked devices do not, and payloads expose no conversation or approval content.
- Swift integration tests prove notification routing to the correct thread or approval. Native
  dictation remains Apple's system-keyboard behavior; Yorozu keeps a standard editable composer
  and adds no app-owned dictation behavior to test.
- End-to-end proof backgrounds an iPhone, completes a task, receives a push, opens the correct thread, and separately has Codex complete one real Yorozu tool call under the shared approval engine.

## Out of Scope

- Vector embeddings, sqlite-vec, semantic memory retrieval, and embedding model management.
- Stripe billing and hosted provider cards.
- Custom voice recording, transcription UI, speech models, or audio-message support.
- Changing the blind relay into a trusted application server.
- Automatically activating inferred approval rules.
- Replacing the existing transcript, provider chain, or tool implementations.
- iOS Live Activities — built, then dropped in t50: the four APNs alert classes already deliver every moment worth surfacing, so the lock-screen activity, its push-token plumbing, and the widget extension were not worth their weight.

## Further Notes

- Delivery order: rolling summaries, Codex MCP tools, approval hardening, then APNs. APNs has Apple entitlement, provisioning, token lifecycle, and server-auth dependencies.
- Version 1.5 should remain a local-first upgrade. The relay learns only the minimum metadata required to wake a paired device.
