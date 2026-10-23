/**
 * When a conversation last had a message, for `conv_list`'s `updatedAt` and order (owner, 2026-10-24): the newest user
 * or agent message's own time in the transcript. The session entry's `updatedAt` moves on any write to the entry (a
 * rename, a pin, a store migration), and so does the store's transcript write time, so neither orders the list.
 *
 * Reading a transcript is costly, so each conversation's time is kept with the transcript `rev` it was read at (keyed
 * state store, namespace `message-times`) and read again only when the transcript grew. A conversation imported from
 * Yorozu 0.5 (the Mac app's migration) holds its last 0.5 message's time the same way, set through the Gateway method
 * `yorozu.conversations.time`, until a new message comes.
 */
import { getSessionEntry, readTranscriptStatsSync } from "openclaw/plugin-sdk/session-store-runtime";
import { isId } from "./envelope.js";
import { yorozuRuntime } from "./runtime.js";

type Known = { rev: number; at: number };

const store = () =>
  yorozuRuntime.getRuntime().state.openKeyedStore<Known>({ namespace: "message-times", retention: "retained" });
const known = new Map<string, Known>();

/** Reads the kept times into memory once the account starts; `conv_list` is answered without waiting on the store. */
export async function loadMessageTimes(): Promise<void> {
  for (const { key, value } of await store().entries()) known.set(key, value);
}

/** The transcript's newest event `seq`: a client holding it has the whole history so far, and nothing new was written. */
export function revOf(agent: string, sessionKey: string, sessionId: string): number {
  try {
    return readTranscriptStatsSync({ agentId: agent, sessionId, sessionKey }).maxSeq;
  } catch {
    return 0;
  }
}

/** The conversation's last message time at `rev`; `read` reads the transcript when the kept one is for another `rev`. */
export function messageTime(convId: string, rev: number, read: () => number | undefined, fallback: number): number {
  const kept = known.get(convId);
  if (kept && kept.rev === rev) return kept.at;
  const at = read();
  if (at === undefined) return fallback;
  remember(convId, { rev, at });
  return at;
}

/** Gateway method `yorozu.conversations.time`: the time of the last message a conversation had before it was imported. */
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
