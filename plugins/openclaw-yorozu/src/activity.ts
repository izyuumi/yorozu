import { readTranscriptStatsSync } from "openclaw/plugin-sdk/session-store-runtime";
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

function remember(convId: string, value: Known): Promise<void> {
  known.set(convId, value);
  return store()
    .register(convId, value)
    .catch(() => {});
}
