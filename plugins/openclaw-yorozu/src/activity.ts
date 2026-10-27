import { getSessionEntry, readTranscriptStatsSync } from "openclaw/plugin-sdk/session-store-runtime";
import { isId } from "./envelope.js";
import { yorozuRuntime } from "./runtime.js";

type Known = { rev: number; at: number };

const store = () =>
  yorozuRuntime.getRuntime().state.openKeyedStore<Known>({ namespace: "message-times", retention: "retained" });
const known = new Map<string, Known>();

export async function loadMessageTimes(): Promise<void> {
  for (const { key, value } of await store().entries()) known.set(key, value);
}

export function revOf(agent: string, sessionKey: string, sessionId: string): number {
  try {
    return readTranscriptStatsSync({ agentId: agent, sessionId, sessionKey }).maxSeq;
  } catch {
    return 0;
  }
}

export function messageTime(convId: string, rev: number, read: () => number | undefined, fallback: number): number {
  const kept = known.get(convId);
  if (kept && kept.rev === rev) return kept.at;
  const at = read();
  if (at === undefined) return fallback;
  remember(convId, { rev, at });
  return at;
}

export async function holdTime(agent: string, params: Record<string, unknown>): Promise<{ held: boolean }> {
  const { convId, at } = params;
  if (typeof convId !== "string" || !isId(convId)) throw new Error("convId must be a conversation id");
  if (typeof at !== "number" || !Number.isSafeInteger(at) || at <= 0) throw new Error("at must be epoch milliseconds");
  const sessionKey = `agent:${agent}:yorozu:direct:owner:thread:${convId}`;
  const entry = getSessionEntry({ agentId: agent, sessionKey });
  if (!entry?.sessionId) return { held: false };
  await remember(convId, { rev: revOf(agent, sessionKey, entry.sessionId), at });
  return { held: true };
}

function remember(convId: string, value: Known): Promise<void> {
  known.set(convId, value);
  return store()
    .register(convId, value)
    .catch(() => {});
}
