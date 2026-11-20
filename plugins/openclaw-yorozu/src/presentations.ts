import { CARD_INDEX, CARDS, cardStore, type StoredCard } from "./cards.js";
import { yorozuRuntime } from "./runtime.js";

const state = () => yorozuRuntime.getRuntime().state;
const store = cardStore(
  () => state().openKeyedStore<StoredCard>(CARDS),
  () => state().openKeyedStore<string[]>(CARD_INDEX),
);

export const storeCard = (convId: string, key: string, card: StoredCard): Promise<void> => store.put(convId, key, card);
export const cardKeys = (convId: string): Promise<string[]> => store.keys(convId);
export const storedCard = (key: string): Promise<StoredCard | undefined> => store.get(key);
export const forgetCards = (convId: string): Promise<void> => store.forget(convId);
