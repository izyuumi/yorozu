// Read-only cards (capability `presentation`): what the agent is told, what a payload's card becomes on the wire,
// and the store's keys and per-conversation index. Imports only the pure sanitizer, so node tests run it without OpenClaw.
import type { Event } from "./envelope.js";
import { sanitizePresentation, type Presentation, type PresentationSdk } from "./presentation.js";

/** `describeMessageTool`: OpenClaw adds `presentation` to the message tool's schema only for a channel listing it. */
export const MESSAGE_TOOL = { actions: ["react"], capabilities: ["presentation"] } as const;

export const PRESENTATION_CAPABILITIES = {
  supported: true, context: true, divider: true, tables: true, charts: true, buttons: false, selects: false,
} as const;

export const MESSAGE_TOOL_HINTS = [
  "- This conversation is in the Yorozu app, not Signal or another messenger.",
  "- Yorozu renders a read-only card from the message tool's `presentation`: an optional `title` and `blocks` of type `text`, `context`, `divider`, `table` or `chart`. The plain text is always sent alongside the card.",
  "- Use a card only for data that is genuinely tabular or chartable, or for a short titled summary. For anything else, reply in plain text.",
  "- Prefer a card when the user asks to see a card, chart, table or demo; send it in the same turn without asking.",
  "- Put the key facts in the text too; older Yorozu apps show only the text.",
  "- A `table` needs `caption`, `headers` and `rows` (each row as long as `headers`).",
  "- A Yorozu table or chart must use the message tool's `presentation`, never a markdown pipe table. Workspace or Signal rules that say never send tables apply to Signal, not to Yorozu cards.",
];

// OpenClaw's Codex app-server harness never shows agentPrompt.messageToolHints, so every Yorozu turn carries them via conversation.ts supplemental.groupSystemPrompt.
// A before_prompt_build hook that returns `systemPrompt` replaces the developer instructions that carry groupSystemPrompt,
// so index.ts also appends this via appendSystemContext, which OpenClaw concatenates after any replacement.
// groupSystemPrompt stays because the plugin cannot tell whether that hook was registered (it needs allowConversationAccess on an untrusted install).
// Embedded and claude-cli runs see the hints more than once; keep every copy so every harness receives them.
export const CARD_GUIDANCE = ["## Yorozu app", ...MESSAGE_TOOL_HINTS].join("\n");

const shows = (card: Presentation): boolean => !!card.title || card.blocks.some((block) => block.type !== "divider");

/** A payload's text and card as sent: the text always goes, and a card that cannot be shown changes nothing about it.
 * Empty text becomes the fallback text of a card that is sent. `dropped`: a card was given and none is sent. */
export function cardFor(raw: unknown, text: string | null | undefined, sdk: PresentationSdk): { text: string; presentation?: Presentation; dropped: boolean } {
  const body = text ?? "";
  if (raw === undefined || raw === null) return { text: body, dropped: false };
  let clean: ReturnType<typeof sanitizePresentation> = { fallbackText: "" };
  try { clean = sanitizePresentation(raw, sdk); } catch { /* text only */ }
  const presentation = clean.presentation && shows(clean.presentation) ? clean.presentation : undefined;
  if (!presentation) return { text: body, dropped: true };
  return { text: body.trim() ? body : clean.fallbackText || body, presentation, dropped: false };
}

const CHANNEL_DATA = "yorozu";
type Carrier = { text?: string; channelData?: Record<string, unknown>; presentationTextMode?: string };
export const DROPPED = "yorozu: dropped a card that cannot be shown; the reply goes out without it";

/** `outbound.renderPresentation`: OpenClaw strips `presentation` from the payload this returns, so the sanitized card
 * rides in `channelData.yorozu`. For null OpenClaw sends its own flattening of the unsanitized card
 * (`renderPresentationForDelivery`, `src/channels/plugins/outbound/presentation-delivery.ts:69-83`), so a dropped
 * card returns the payload with its own text and no card instead. Except with `presentationTextMode: "fallback"`:
 * core has blanked `text` here and sends the authored text as it is for null. */
export function renderedPayload<P extends Carrier>(payload: P, raw: unknown, sdk: PresentationSdk, log?: { warn(line: string): void }): P | null {
  const card = cardFor(raw, payload.text, sdk);
  if (!card.presentation) {
    if (!card.dropped) return null;
    log?.warn(DROPPED);
    return payload.presentationTextMode === "fallback" ? null : payload;
  }
  return { ...payload, text: card.text, channelData: { ...payload.channelData, [CHANNEL_DATA]: { presentation: card.presentation } } };
}

/** The card `renderedPayload` put in a payload, unchecked: `channelData` can also come straight from a caller. */
export const channelCard = (payload: Carrier): unknown =>
  (payload.channelData?.[CHANNEL_DATA] as { presentation?: unknown } | undefined)?.presentation;

/** The card goes on the last chunk of a reply; without one the events are returned as they are. */
export function withCard(events: Event[], presentation?: Presentation): Event[] {
  const last = events.at(-1);
  if (!presentation || last?.kind !== "reply") return events;
  return [...events.slice(0, -1), { kind: "reply", data: { ...last.data, presentation } }];
}

export const CARDS = { namespace: "presentations", maxEntries: 10_000, overflowPolicy: "evict-oldest" } as const;
export const CARD_INDEX = { namespace: "presentation-index", maxEntries: 10_000, overflowPolicy: "evict-oldest" } as const;
/** The key of a card whose reply took a transcript assistant event's ids: history puts it on that event's last chunk. */
export const cardKey = (sessionId: string, eventId: string): string => `${sessionId}:${eventId}`;
/** The keys of a turn's other cards start with this; the turn is its session and the user's message. */
export const turnCards = (sessionId: string, userMessageId: string): string => `${sessionId}:turn:${userMessageId}:`;
/** The key of a card whose reply matched no transcript event (a card-only payload, a `message` tool send). */
export const turnCardKey = (sessionId: string, userMessageId: string, replyId: string): string =>
  turnCards(sessionId, userMessageId) + replyId;
/** A stored card. `reply`, on a turn-keyed card only: every chunk of the live reply that carried it, in order, which
 * history shows again under the same ids (the card on the last). `mirrorText`: text before attachment-failure
 * lines, when they changed the stored chunks, so history can still match core's mirror. */
export type StoredCard = { presentation: Presentation; reply?: { messageId: string; ts: number; text: string }[]; mirrorText?: string };

/** A turn-keyed card's record from the reply events that carried it. */
export const replyChunks = (events: Event[]): NonNullable<StoredCard["reply"]> =>
  events.flatMap((event) => (event.kind === "reply" ? [{ messageId: event.data.messageId, ts: event.data.ts, text: event.data.text }] : []));

/** Conversations forgotten in this process that `put` turns away; the newest this many. */
export const FORGOTTEN_MAX = 1_000;

/** Cards kept per conversation, so its index row stays small; the oldest goes first. */
export const CONV_CARDS_MAX = 500;
/** How long one store operation may take, and so how long the next write waits for it at most. */
export const CARD_WAIT_MS = 5_000;
/** OpenClaw's keyed plugin state rejects a value over 1 MiB as JSON (`MAX_PLUGIN_STATE_VALUE_BYTES`,
 * `src/plugin-state/plugin-state-store.kernel.ts:21`, enforced by `prepareRegisterParams`,
 * `plugin-state-store.validation.ts:107-118`) and a key over 512 bytes (`plugin-store-validation.ts:3`). A row over
 * either is not written at all: a card whose index row could not be written would never be read or deleted. */
export const STORE_VALUE_MAX_BYTES = 1_048_576;
export const STORE_KEY_MAX_BYTES = 512;

const named = (name: string, message: string): Error => Object.assign(new Error(message), { name });
const bytes = (value: unknown): number => Buffer.byteLength(typeof value === "string" ? value : JSON.stringify(value));

/** An error's code or name for a log line, and nothing else of it: its message may quote content. */
export function errorTag(error: unknown): string {
  const { code, name } = (typeof error === "object" && error !== null ? error : {}) as { code?: unknown; name?: unknown };
  const tag = [code, name].find((part): part is string => typeof part === "string" && /^[\w.-]{1,64}$/.test(part));
  return tag ?? "error";
}

export type Keyed<T> = {
  register(key: string, value: T): Promise<void>;
  lookup(key: string): Promise<T | undefined>;
  delete(key: string): Promise<boolean>;
};

/** Cards by key, plus each conversation's list of keys. A card is read only through its conversation's list, so
 * deleting the conversation takes every card that can still be shown.
 * - The deadline bounds promises that reject or never settle; it cannot interrupt a synchronous store call.
 *   Every operation fails with `CardStoreTimeout` `waitMs` after it was called, time spent waiting its turn
 *   included. Writes run one at a time; one whose time ran out while it waited fails without running.
 * - An operation that timed out is abandoned: when the store answers it later, it makes no further write. So a
 *   stalled put cannot write its stale copy of the list over a later put's, and cannot re-create a deleted list.
 *   A write already handed to the store when the time ran out cannot be taken back.
 * - A conversation forgotten in this process (the newest `FORGOTTEN_MAX`) stores no more cards (`CardForgotten`):
 *   a card of a turn still running when its conversation was deleted does not bring the conversation's cards back.
 * - A row over the store's limits is not written (`CardTooLarge`). */
export function cardStore(cards: () => Keyed<StoredCard>, index: () => Keyed<string[]>, waitMs: number = CARD_WAIT_MS) {
  const bounded = <T>(work: (live: () => void) => Promise<T>, after: Promise<void> = Promise.resolve()): Promise<T> => {
    let abandoned = false;
    let timer: ReturnType<typeof setTimeout> | undefined;
    const timeout = new Promise<never>((_, fail) => {
      timer = setTimeout(() => {
        abandoned = true;
        fail(named("CardStoreTimeout", "the card store did not answer in time"));
      }, waitMs);
    });
    const live = () => {
      if (abandoned) throw named("CardStoreTimeout", "abandoned");
    };
    const job = after.then(() => {
      live();
      return work(live);
    });
    job.catch(() => {}); // settled after the timeout: nobody is waiting any more
    return Promise.race([job, timeout]).finally(() => clearTimeout(timer));
  };
  let queue: Promise<void> = Promise.resolve();
  const serial = <T>(work: (live: () => void) => Promise<T>): Promise<T> => {
    const run = bounded(work, queue);
    queue = run.then(() => {}, () => {});
    return run;
  };
  const forgotten = new Set<string>();
  return {
    put: (convId: string, key: string, card: StoredCard): Promise<void> =>
      serial(async (live) => {
        if (forgotten.has(convId)) throw named("CardForgotten", "the conversation was deleted");
        if (bytes(key) > STORE_KEY_MAX_BYTES || bytes(card) > STORE_VALUE_MAX_BYTES) throw named("CardTooLarge", "a card row is over the store's limit");
        const keys = (await index().lookup(convId)) ?? [];
        if (!keys.includes(key)) {
          const kept = [...keys, key];
          const dropped = kept.splice(0, Math.max(0, kept.length - CONV_CARDS_MAX));
          if (bytes(kept) > STORE_VALUE_MAX_BYTES) throw named("CardTooLarge", "a card index row is over the store's limit");
          for (const old of dropped) {
            live();
            await cards().delete(old);
          }
          live();
          await index().register(convId, kept);
        }
        live();
        await cards().register(key, card);
      }),
    /** The conversation's card keys, oldest first. */
    keys: (convId: string): Promise<string[]> => bounded(async () => (await index().lookup(convId)) ?? []),
    get: (key: string): Promise<StoredCard | undefined> => bounded(async () => cards().lookup(key)),
    forget: (convId: string): Promise<void> =>
      serial(async (live) => {
        for (const key of (await index().lookup(convId)) ?? []) {
          live();
          await cards().delete(key);
        }
        live();
        await index().delete(convId);
        live();
        forgotten.delete(convId);
        forgotten.add(convId);
        for (const old of forgotten) if (forgotten.size > FORGOTTEN_MAX) forgotten.delete(old);
      }),
  };
}
