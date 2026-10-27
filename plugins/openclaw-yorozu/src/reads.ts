/**
 * Read marks (#429): one `ReadCursor` per conversation in the plugin's keyed state store (namespace `read`), the
 * same on every device. A device sends its `read_cursor` when it opens a conversation, reads a new reply in it, or
 * marks it read or unread; `src/relay.ts` merges it here, sends the result to every device, and sends every stored
 * cursor to a device whose session opens.
 */
import type { ReadCursor } from "./envelope.js";
import { yorozuRuntime } from "./runtime.js";

const store = () =>
  yorozuRuntime.getRuntime().state.openKeyedStore<ReadCursor>({ namespace: "read", retention: "retained" });

export async function listCursors(): Promise<ReadCursor[]> {
  return (await store().entries()).map((entry) => entry.value);
}

/**
 * The cursor only moves forward, so a device behind another never un-reads what that one read; `unread` is the
 * sender's, the latest action on any device. Returns what is stored now.
 */
export async function mergeCursor(next: ReadCursor): Promise<ReadCursor> {
  const held = await store().lookup(next.convId);
  const merged = held && held.ts > next.ts ? { ...held, unread: next.unread } : next;
  if (!held || held.ts !== merged.ts || held.messageId !== merged.messageId || held.unread !== merged.unread) {
    await store().register(merged.convId, merged);
  }
  return merged;
}

/** A deleted conversation's cursor goes with it (#428). */
export async function forgetCursor(convId: string): Promise<void> {
  await store().delete(convId);
}
