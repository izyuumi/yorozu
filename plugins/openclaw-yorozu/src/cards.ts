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
  "- When the user asks to see a card, chart, table or demo, send it in the same turn; do not ask first.",
  "- Put the key facts in the text too; older Yorozu apps show only the text.",
];

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
type Carrier = { text?: string; channelData?: Record<string, unknown> };

/** `outbound.renderPresentation`: OpenClaw strips `presentation` from the payload this returns, so the sanitized card
 * rides in `channelData.yorozu`. Null when there is nothing to show; OpenClaw then sends its own text fallback. */
export function renderedPayload<P extends Carrier>(payload: P, raw: unknown, sdk: PresentationSdk): P | null {
  const card = cardFor(raw, payload.text, sdk);
  if (!card.presentation) return null;
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
export const cardKey = (sessionId: string, eventId: string): string => `${sessionId}:${eventId}`;
/** Cards kept per conversation, so its index row stays small; the oldest goes first. */
export const CONV_CARDS_MAX = 500;
/** How long the next store write waits for the one before it. */
export const CARD_WAIT_MS = 5_000;

export type Keyed<T> = {
  register(key: string, value: T): Promise<void>;
  lookup(key: string): Promise<T | undefined>;
  delete(key: string): Promise<boolean>;
};

/** Cards by `cardKey`, plus each conversation's list of keys. A card is read only through its conversation's list,
 * so deleting the conversation takes every card that can still be shown. Writes run one at a time, and one that has
 * not finished after `waitMs` no longer holds up the next: a stuck put never blocks a delete. */
export function cardStore(cards: () => Keyed<Presentation>, index: () => Keyed<string[]>, waitMs: number = CARD_WAIT_MS) {
  let queue: Promise<void> = Promise.resolve();
  const serial = <T>(work: () => Promise<T>): Promise<T> => {
    const run = queue.then(work);
    queue = queue.then(() => {
      let timer: ReturnType<typeof setTimeout> | undefined;
      const timeout = new Promise<void>((done) => { timer = setTimeout(done, waitMs); });
      return Promise.race([run.then(() => {}, () => {}), timeout]).finally(() => clearTimeout(timer));
    });
    return run;
  };
  return {
    put: (convId: string, key: string, card: Presentation): Promise<void> =>
      serial(async () => {
        const keys = (await index().lookup(convId)) ?? [];
        if (!keys.includes(key)) {
          const kept = [...keys, key];
          for (const old of kept.splice(0, Math.max(0, kept.length - CONV_CARDS_MAX))) await cards().delete(old);
          await index().register(convId, kept);
        }
        await cards().register(key, card);
      }),
    keys: async (convId: string): Promise<Set<string>> => new Set(await index().lookup(convId)),
    get: (key: string): Promise<Presentation | undefined> => cards().lookup(key),
    forget: (convId: string): Promise<void> =>
      serial(async () => {
        for (const key of (await index().lookup(convId)) ?? []) await cards().delete(key);
        await index().delete(convId);
      }),
  };
}
