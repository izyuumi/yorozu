# 0018. Plugin card pipeline, prompt guidance and sanitizer

- Status: Accepted
- Date: 2026-11-21 (recorded from code comments)

## Context

Agents produce cards through OpenClaw's `presentation` payloads and the message tool. The plugin must tell the agent about cards on every harness, sanitize every card before it crosses the wire, and keep replies without cards byte-identical to before cards existed.

## Decision

- `cards.ts` holds what the agent is told, what a payload's card becomes on the wire, and the store's keys and per-conversation index. It imports only the pure sanitizer, so node tests run it without OpenClaw.
- OpenClaw adds `presentation` to the message tool's schema only for a channel listing it (`describeMessageTool`).
- `cardFor`: the text always goes, and a card that cannot be shown changes nothing about it. Empty text becomes the fallback text of a card that is sent. `dropped` means a card was given and none is sent. A dropped card's fallback text is not sent in its place: empty text stays nothing.
- `renderedPayload` (`outbound.renderPresentation`): OpenClaw strips `presentation` from the payload this returns, so the sanitized card rides in `channelData.yorozu`. For null, OpenClaw sends its own flattening of the unsanitized card (`renderPresentationForDelivery`), so a dropped card returns the payload with its own text and no card instead. Except with `presentationTextMode: "fallback"`: core has blanked `text` there and sends the authored text as is for null.
- `channelCard` reads the card back unchecked, so `sendPayload` sanitizes it again: `channelData` can also come straight from a caller.
- OpenClaw hands a message-tool card to `deliver` as it came; that is the only place it is checked.
- `presentationSdk` uses OpenClaw's own block rules and fallback text, behind the sanitizer's allowlist.
- Sanitizer:
  - `prepareToolPresentation` repairs a card before core normalizes the message tool, since core silently drops invalid tables.
  - SDK output is rebuilt through the same allowlist, then validated before native rendering.
  - Strings: iterate only the bounded prefix, and repair lone surrogates before crossing the wire.
  - Invalid scalar presence is preserved, notably an invalid optional row-header index.
  - Array lookahead counts only; it never traverses the overflow entry.
  - The omission summary uses only preflight primitives, never SDK renderers or object coercion, and keeps the explicit omission note even when the title consumes its whole cap.
  - An object over the limit is cut to fit (trailing blocks become a note), not dropped.
  - Preflight applies the SDK's string trim rule before calling the pinned normalizer. Core ignores a table's extra title.
- Prompt guidance:
  - OpenClaw's Codex app-server harness never shows `agentPrompt.messageToolHints`, so every Yorozu turn carries the card guidance through `supplemental.groupSystemPrompt`.
  - A `before_prompt_build` hook that returns `systemPrompt` replaces the developer instructions that carry `groupSystemPrompt`, so the plugin also appends the guidance through `appendSystemContext`, which OpenClaw concatenates after any replacement.
  - `groupSystemPrompt` stays because the plugin cannot tell whether that hook was registered: it needs `allowConversationAccess` on an untrusted install.
  - Embedded and claude-cli runs see the hints more than once. Every copy is kept so every harness receives them.
  - The hook is registered last: if OpenClaw throws when it refuses this gated hook, table repair and pairing methods still register.
  - The tests record the OpenClaw 2026.9.8 merge order this assumes: developer instructions = `prependSystemContext` + (first `systemPrompt`, or the built instructions) + every `appendSystemContext`. They do not run OpenClaw's merger; isolated-host runs are the evidence for that.
- Golden wire: the literals in `genui-golden.test.ts` were produced by the code before capability `presentation`, and the file uses nothing that code lacks. A reply or history page without a card must stay byte-identical.

## Consequences

- No unsanitized card can reach a device, whichever path produced it.
- Card guidance may appear more than once in a prompt, by design.

## Where in the code

- `plugins/openclaw-yorozu/src/cards.ts` — `MESSAGE_TOOL`, `CARD_GUIDANCE`, `cardFor`, `renderedPayload`, `channelCard`
- `plugins/openclaw-yorozu/src/channel.ts` — `presentationSdk`, `sendPayload`
- `plugins/openclaw-yorozu/src/conversation.ts` — `deliver`
- `plugins/openclaw-yorozu/src/presentation.ts` — `string`, `copy`, `omitted`, `native`, `prepareToolPresentation`
- `plugins/openclaw-yorozu/index.ts` — `registerFull` (`before_prompt_build` hook)
- `plugins/openclaw-yorozu/test/presentations.test.ts`, `presentation.test.ts`, `tool-presentation.test.ts`, `genui-golden.test.ts`
