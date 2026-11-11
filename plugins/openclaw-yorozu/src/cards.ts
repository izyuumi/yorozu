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
  "- This conversation is in the Yorozu app (iPhone, iPad, Mac), not Signal or another messenger.",
  "- Yorozu renders a read-only card from the message tool's `presentation`: an optional `title` and `blocks` of type `text`, `context`, `divider`, `table` or `chart`. The plain text is always sent alongside the card.",
  "- Use a card only for data that is genuinely tabular or chartable, or for a short titled summary. For anything else, reply in plain text.",
  "- When the user asks to see a card, chart, table or demo, send it in the same turn; do not ask first.",
];

const shows = (card: Presentation): boolean => !!card.title || card.blocks.some((block) => block.type !== "divider");

/** A payload's text and card as sent: the text always goes, and a card that cannot be shown never takes it along.
 * Empty text becomes the card's fallback text. `dropped`: a card was given and none is sent. */
export function cardFor(raw: unknown, text: string | null | undefined, sdk: PresentationSdk): { text: string; presentation?: Presentation; dropped: boolean } {
  const body = text ?? "";
  if (raw === undefined || raw === null) return { text: body, dropped: false };
  let clean: ReturnType<typeof sanitizePresentation> = { fallbackText: "" };
  try { clean = sanitizePresentation(raw, sdk); } catch { /* text only */ }
  const presentation = clean.presentation && shows(clean.presentation) ? clean.presentation : undefined;
  return { text: body.trim() ? body : clean.fallbackText || body, ...(presentation ? { presentation } : {}), dropped: !presentation };
}

/** The card goes on the last chunk of a reply; without one the events are returned as they are. */
export function withCard(events: Event[], presentation?: Presentation): Event[] {
  const last = events.at(-1);
  if (!presentation || last?.kind !== "reply") return events;
  return [...events.slice(0, -1), { kind: "reply", data: { ...last.data, presentation } }];
}

export const CARDS = { namespace: "presentations", maxEntries: 10_000, overflowPolicy: "evict-oldest" } as const;
export const CARD_INDEX = { namespace: "presentation-index", maxEntries: 10_000, overflowPolicy: "evict-oldest" } as const;
export const cardKey = (sessionId: string, eventId: string): string => `${sessionId}:${eventId}`;

export type Keyed<T> = {
  register(key: string, value: T): Promise<void>;
  lookup(key: string): Promise<T | undefined>;
  delete(key: string): Promise<boolean>;
};

/** Cards by `cardKey`, plus each conversation's list of keys. A card is read only through its conversation's list,
 * so deleting the conversation takes every card that can still be shown; writes run one at a time. */
export function cardStore(cards: () => Keyed<Presentation>, index: () => Keyed<string[]>) {
  let queue: Promise<unknown> = Promise.resolve();
  const serial = <T>(work: () => Promise<T>): Promise<T> => {
    const run = queue.then(work, work);
    queue = run.catch(() => {});
    return run;
  };
  return {
    put: (convId: string, key: string, card: Presentation): Promise<void> =>
      serial(async () => {
        const keys = (await index().lookup(convId)) ?? [];
        if (!keys.includes(key)) await index().register(convId, [...keys, key].slice(-CARDS.maxEntries));
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
