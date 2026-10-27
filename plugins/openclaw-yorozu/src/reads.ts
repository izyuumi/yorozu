import type { ReadCursor } from "./envelope.js";
import { yorozuRuntime } from "./runtime.js";

const store = () =>
  yorozuRuntime.getRuntime().state.openKeyedStore<ReadCursor>({ namespace: "read", retention: "retained" });

export async function listCursors(): Promise<ReadCursor[]> {
  return (await store().entries()).map((entry) => entry.value);
}

export async function mergeCursor(next: ReadCursor): Promise<ReadCursor> {
  const held = await store().lookup(next.convId);
  const merged = held && held.ts > next.ts ? { ...held, unread: next.unread } : next;
  if (!held || held.ts !== merged.ts || held.messageId !== merged.messageId || held.unread !== merged.unread) {
    await store().register(merged.convId, merged);
  }
  return merged;
}

export async function forgetCursor(convId: string): Promise<void> {
  await store().delete(convId);
}
