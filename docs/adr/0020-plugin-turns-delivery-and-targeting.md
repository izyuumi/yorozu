# 0020. Plugin turns, outbound delivery, message-tool targeting and update notices

- Status: Accepted
- Date: 2026-11-21 (recorded from code comments)

## Context

The plugin turns each inbound message into an OpenClaw turn, delivers the turn's reply, and also handles explicit-target sends (cron, the message tool). The channel has one peer, the owner; a conversation is the thread id of a send.

## Decision

- Turns:
  - A turn's end reads as the app reads it: a reply is done, a reported failure failed, a retry still running, nothing gone.
  - The turn that `sendPayload` stores cards under is set from its agent run's start, so a message waiting in OpenClaw's queue behind a running turn does not take that turn's cards. One run per session at a time.
  - Failures before the run (route, attachments, media) are reported by `handleMessage`'s outer catch: nothing else reports them, and `onMessage` doesn't await it.
- Explicit-target delivery:
  - `outbound.renderPresentation` / `sendPayload` handle explicit-target sends only (cron, a message tool send naming a target); a turn's own reply goes through `deliver`. OpenClaw calls `sendPayload` only for a payload with presentation, interactive, channelData, location, audioAsVoice or videoAsNote; plain text and media still use `sendText` and `sendMedia`.
  - `outboundLog` is unset until `startAccount` runs; a dropped card then goes without its log line.
  - `sendConversationPayload` returns the id of its first reply, or "" when nothing was sent. With the card in `channelData.yorozu`: chunked text, files and the card on the last chunk, and during that conversation's running turn the card is stored under the turn for history. Without a card: exactly what OpenClaw does for a channel with no `sendPayload` — one `sendText` per text chunk, or one `sendMedia` per file with the text on the first. Nothing sendable sends nothing and does not throw; OpenClaw records a result without an id as not delivered.
  - Text is chunked with `planOutboundTextMessageUnits`, using the channel's chunker and limit as the outbound adapter declares them.
  - "no conversation reference found" is one of OpenClaw's permanent delivery errors, so a send without a conversation is not queued for retries.
- Message-tool targeting:
  - `resolveOwnerRoute` gives the agent and thread keys OpenClaw routes Yorozu to; bindings and identity links can differ from the config.
  - Core takes a message-tool send with no target through this plugin only on a host that sets `channels.yorozu` (present and not disabled, core's `isConfiguredChannel`). Without it, such a send from a Yorozu turn goes to core's private source-reply sink.
  - Explicit `owner` resolves on every host. Without a thread the adapter throws `yorozu: no conversation reference found; …` (permanent, not retried); an explicit UUID threadId is delivered.
  - A send with no `threadId` of its own belongs to the conversation of the Yorozu turn making the call. Without a known conversation (another channel's turn, a cron run without one, no turn) the adapter rejects it for missing threadId.
  - `resolveAutoThreadId` infers a missing threadId only for a configured Yorozu turn. The `channels.yorozu` gate exists because core reuses that hook when matching a finished send against the turn's reply route, omitting the provider in its toolContext. With an implicit-thread send and a channel hint, the match succeeds only on configured hosts; explicit own and other threads match or reject on both. An explicit UUID threadId bypasses the hook when sending.
  - An empty messaging target counts as present under `??`; declining inference is safe because it cannot choose a conversation.
  - In a Yorozu turn (OpenClaw 2026.9.8), core's message tool hands `resolveAutoThreadId` the turn's `reply.to` as the channel id and its `messageThreadId` as the thread.
  - Only explicit `[[reply_to…]]` tags and the message tool's `replyTo` quote a message.
- Update notices:
  - `autoUpdateBlockers` reports why OpenClaw will not update this Gateway by itself, with the same conditions its auto-updater checks. `openclaw gateway install` puts the service markers into the launchd, systemd or Scheduled Task environment.
  - A notice is posted into the most recent conversation and mirrored into its transcript, so a device that connects later finds it in history. `post` returns false when there is no conversation.

## Consequences

- Explicit-target sends behave exactly like OpenClaw's default when no card is involved.
- Message-tool sends never land in the wrong conversation.

## Where in the code

- `plugins/openclaw-yorozu/src/conversation.ts` — `handleMessage`, `NO_CONVERSATION`, `sendConversationPayload`
- `plugins/openclaw-yorozu/src/channel.ts` — `startAccount`, `messaging.targetResolver`, `threading`, `outbound.renderPresentation`, `sendPayload`
- `plugins/openclaw-yorozu/src/target.ts` — module, `channelConfigured`, `currentConversation`
- `plugins/openclaw-yorozu/src/updates.ts` — `autoUpdateBlockers`, `post`
- `plugins/openclaw-yorozu/test/target.test.ts`, `plugins/openclaw-yorozu/test/conversation-owner.test.ts`
