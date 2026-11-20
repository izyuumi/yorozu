# 0019. Plugin card store and history

- Status: Accepted
- Date: 2026-11-21 (recorded from code comments)

## Context

OpenClaw's transcript does not keep cards, so the plugin stores them in OpenClaw's keyed plugin state and puts them back on history pages. The store can be slow or fail; neither may cost a reply or resurrect deleted data.

## Decision

- Keys:
  - `cardKey`: a card whose reply took a transcript assistant event's ids; history puts it on that event's last chunk.
  - `turnCardKey`: a card whose reply matched no transcript event (a card-only payload, a `message` tool send).
  - `StoredCard.reply`, on a turn-keyed card only: every chunk of the live reply that carried it, in order; history shows them again under the same ids, the card on the last. `mirrorText`: the text before attachment-failure lines, when those changed the stored chunks, so history can still match core's mirror.
- Limits:
  - `CONV_CARDS_MAX` cards per conversation, so its index row stays small; the oldest goes first.
  - OpenClaw's keyed plugin state rejects a value over 1 MiB as JSON and a key over 512 bytes. A row over either is not written at all (`CardTooLarge`): a card whose index row could not be written would never be read or deleted.
- `cardStore`:
  - Cards by key, plus each conversation's list of keys. A card is read only through its conversation's list, so deleting the conversation takes every card that can still be shown.
  - Each operation has `CARD_WAIT_MS` from the call, its wait in the write queue included, and fails with `CardStoreTimeout` after it. The deadline bounds promises that reject or never settle; it cannot interrupt a synchronous store call. Writes run one at a time; one whose time ran out while it waited fails without running. Callers decide what a failure costs.
  - A timed-out operation is abandoned: when the store answers later, it makes no further write. So a stalled put cannot write its stale list over a later put's, and cannot re-create a deleted list. A write already handed to the store cannot be taken back.
  - A conversation forgotten in this process (the newest `FORGOTTEN_MAX`) stores no more cards (`CardForgotten`): a card of a turn still running when its conversation was deleted does not bring the conversation's cards back.
- Delivery (`deliver`):
  - A transcript message's ids go only to a payload with text or a file of its own. With a card, only to a message saying the payload's text: a card-only payload, or one whose text no message says, must not take the ids of some other reply's text.
  - The card is stored after the reply and not awaited: a slow or failing store costs the history card, never the reply.
  - With a transcript message's ids, history puts the card on that message. Without, the card is kept by its turn with the reply that carried it.
  - Core mirrors text before attachment-failure lines; history replaces its chunks with the live reply's.
- History:
  - Cache maps: `cards` (card key of each agent message's last chunk, by item id), `turns` (key prefix of a turn's other cards, by the `seq` of the turn's last items), `turnOf` (that prefix by each item's `seq`), `replies` (by prefix: agent messages, chunk count, full text and card key).
  - A card store that fails or does not answer in time still allows a page of transcript items.
  - `liveReplyIds`: the ids of the turn's first unused transcript assistant message with text; with `text`, only one whose text is that text. A card goes only on the message that says what its reply says.
  - `sameText` compares as history shows text (`MEDIA:` lines out), whitespace aside, since joined chunks may lack whitespace the chunker cut at. Empty text matches nothing.
  - A turn runs from the owner's message to the next user-role message or reset. A message id seen twice (a retried run) names its last turn only, so a card comes back once.
- Conversations and sessions:
  - Threads hang off the owner's routed session key, which bindings and identity links can change.
  - A conversation already gone from the session store may still have cards.
  - Delete forgets cards first: a card store that fails or times out fails the delete, which leaves a conversation that can be deleted again, never cards without one.

## Consequences

- History shows the same cards as the live reply, keyed to the same ids.
- A store outage degrades history only.

## Where in the code

- `plugins/openclaw-yorozu/src/cards.ts` — `cardKey`, `turnCardKey`, `StoredCard`, `CONV_CARDS_MAX`, `STORE_VALUE_MAX_BYTES`, `STORE_KEY_MAX_BYTES`, `cardStore`
- `plugins/openclaw-yorozu/src/presentations.ts` — `store`, `storeCard`
- `plugins/openclaw-yorozu/src/conversation.ts` — `deliver`, `sendConversationPayload`
- `plugins/openclaw-yorozu/src/history.ts` — cache maps, history page, `liveReplyIds`, `sameText`, transcript build
- `plugins/openclaw-yorozu/src/sessions.ts` — `setThreadBase`, conversation patch and delete
- `plugins/openclaw-yorozu/test/presentations.test.ts` — transcript mirror simulation
