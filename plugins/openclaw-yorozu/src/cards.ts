import type { Event } from "./envelope.js";
import { sanitizePresentation, type Presentation, type PresentationSdk } from "./presentation.js";

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

export const CARD_GUIDANCE = ["## Yorozu app", ...MESSAGE_TOOL_HINTS].join("\n");

const shows = (card: Presentation): boolean => !!card.title || card.blocks.some((block) => block.type !== "divider");

export function cardFor(raw: unknown, text: string | null | undefined, sdk: PresentationSdk): { text: string; presentation?: Presentation; dropped: boolean } {
  const body = text ?? "";
  if (raw === undefined || raw === null) return { text: body, dropped: false };
  let clean: ReturnType<typeof sanitizePresentation> = { fallbackText: "" };
  try { clean = sanitizePresentation(raw, sdk); } catch {}
  const presentation = clean.presentation && shows(clean.presentation) ? clean.presentation : undefined;
  if (!presentation) return { text: body, dropped: true };
  return { text: body.trim() ? body : clean.fallbackText || body, presentation, dropped: false };
}

const CHANNEL_DATA = "yorozu";
type Carrier = { text?: string; channelData?: Record<string, unknown>; presentationTextMode?: string };
export const DROPPED = "yorozu: dropped a card that cannot be shown; the reply goes out without it";

export function renderedPayload<P extends Carrier>(payload: P, raw: unknown, sdk: PresentationSdk, log?: { warn(line: string): void }): P | null {
  const card = cardFor(raw, payload.text, sdk);
  if (!card.presentation) {
    if (!card.dropped) return null;
    log?.warn(DROPPED);
    return payload.presentationTextMode === "fallback" ? null : payload;
  }
  return { ...payload, text: card.text, channelData: { ...payload.channelData, [CHANNEL_DATA]: { presentation: card.presentation } } };
}

export const channelCard = (payload: Carrier): unknown =>
  (payload.channelData?.[CHANNEL_DATA] as { presentation?: unknown } | undefined)?.presentation;

export function withCard(events: Event[], presentation?: Presentation): Event[] {
  const last = events.at(-1);
  if (!presentation || last?.kind !== "reply") return events;
  return [...events.slice(0, -1), { kind: "reply", data: { ...last.data, presentation } }];
}

export const CARDS = { namespace: "presentations", maxEntries: 10_000, overflowPolicy: "evict-oldest" } as const;
export const CARD_INDEX = { namespace: "presentation-index", maxEntries: 10_000, overflowPolicy: "evict-oldest" } as const;
export const cardKey = (sessionId: string, eventId: string): string => `${sessionId}:${eventId}`;
export const turnCards = (sessionId: string, userMessageId: string): string => `${sessionId}:turn:${userMessageId}:`;
export const turnCardKey = (sessionId: string, userMessageId: string, replyId: string): string =>
  turnCards(sessionId, userMessageId) + replyId;
export type StoredCard = { presentation: Presentation; reply?: { messageId: string; ts: number; text: string }[]; mirrorText?: string };

export const replyChunks = (events: Event[]): NonNullable<StoredCard["reply"]> =>
  events.flatMap((event) => (event.kind === "reply" ? [{ messageId: event.data.messageId, ts: event.data.ts, text: event.data.text }] : []));

export const FORGOTTEN_MAX = 1_000;

export const CONV_CARDS_MAX = 500;
export const CARD_WAIT_MS = 5_000;
export const STORE_VALUE_MAX_BYTES = 1_048_576;
export const STORE_KEY_MAX_BYTES = 512;

const named = (name: string, message: string): Error => Object.assign(new Error(message), { name });
const bytes = (value: unknown): number => Buffer.byteLength(typeof value === "string" ? value : JSON.stringify(value));

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
    job.catch(() => {});
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
