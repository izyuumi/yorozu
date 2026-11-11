import { CARD_INDEX, CARDS, cardKey, cardStore } from "./cards.js";
import type { Presentation } from "./presentation.js";
import { yorozuRuntime } from "./runtime.js";

const state = () => yorozuRuntime.getRuntime().state;
const store = cardStore(
  () => state().openKeyedStore<Presentation>(CARDS),
  () => state().openKeyedStore<string[]>(CARD_INDEX),
);

/** Keeps a reply's card for its history item: by session and transcript event, listed under the conversation. */
export const storeCard = (convId: string, ref: { sessionId: string; eventId: string }, card: Presentation): Promise<void> =>
  store.put(convId, cardKey(ref.sessionId, ref.eventId), card);

// A store that cannot be read costs the card, never the history page.
export const cardKeys = (convId: string): Promise<Set<string>> => store.keys(convId).catch(() => new Set<string>());
export const storedCard = (key: string): Promise<Presentation | undefined> => store.get(key).catch(() => undefined);

export const forgetCards = (convId: string): Promise<void> => store.forget(convId);
