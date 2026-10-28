import type { ReplyTo } from "./envelope.js";
import { yorozuRuntime } from "./runtime.js";

const QUOTE_CHARS = 280;

const store = () =>
  yorozuRuntime.getRuntime().state.openKeyedStore<ReplyTo>({
    namespace: "replies",
    maxEntries: 10_000,
    overflowPolicy: "evict-oldest",
  });
const known = new Map<string, ReplyTo>();

export async function loadReplies(): Promise<void> {
  for (const { key, value } of await store().entries()) known.set(key, value);
}

export const replyOf = (messageId: string): ReplyTo | undefined => known.get(messageId);

export function noteReply(messageId: string, replyTo: ReplyTo): ReplyTo {
  const kept = { messageId: replyTo.messageId, ...(replyTo.text ? { text: replyTo.text.slice(0, QUOTE_CHARS) } : {}) };
  known.set(messageId, kept);
  void store()
    .register(messageId, kept)
    .catch(() => {});
  return kept;
}
