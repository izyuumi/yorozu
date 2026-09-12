/**
 * The rolling summary of a thread: `<state dir>/threads/<id>.summary.md`, holding a compact
 * account of everything that has scrolled out of the `HISTORY_LIMIT` window. A turn's context
 * is the system prompt, then this, then the window — so a long thread keeps its beginning
 * without keeping every word of it. See docs/spec-v1.html section 3.
 *
 * It is regenerated incrementally: one cheap completion folds the newly evicted messages into
 * the summary already on disk, so the cost is per eviction rather than per turn. The file is
 * derived, never authoritative — delete it and the next eviction writes it again from the log.
 */

import { readFileSync, writeFileSync } from "node:fs";
import { stateDir } from "./memory.js";
import type { Message, Provider } from "./provider.js";
import { HISTORY_LIMIT, threadFile, threadHistory, threadMessages } from "./threads.js";

/** Roughly 600 tokens. The prompt asks for words, which is the unit a model can actually count. */
const SUMMARY_WORDS = 400;

const SUMMARY_SYSTEM = `You keep the running summary of a conversation between a user and their \
assistant, so that the parts that have scrolled out of view are not lost.

Rewrite the summary so it also covers the new messages. Keep it under ${SUMMARY_WORDS} words.
Keep decisions, facts about the user, names, numbers, dates, file paths and anything left \
unfinished. Drop pleasantries and anything superseded by a later message. Write plain prose or \
short bullets, in the third person, with no preamble and no heading.`;

/** How the summary file records how much of the thread it already covers. */
const MARKER = /^<!-- yorozu:through (\d+) -->\n/u;

export const summaryFile = (threadId: string, dir = stateDir()): string =>
  threadFile(threadId, ".summary.md", dir);

export interface ThreadSummaryFile {
  /** How many of the thread's messages, from the first, the text accounts for. */
  through: number;
  text: string;
}

/**
 * What is on disk for this thread. A missing file — never written, or deleted to reset the
 * summary — reads as nothing summarised yet, and so does one whose marker someone removed by
 * hand: without it there is no telling what the text covers, so it is rebuilt rather than
 * folded into.
 */
export function readSummary(threadId: string, dir = stateDir()): ThreadSummaryFile {
  let raw: string;
  try {
    raw = readFileSync(summaryFile(threadId, dir), "utf8");
  } catch {
    return { through: 0, text: "" };
  }
  const marker = MARKER.exec(raw);
  if (!marker) return { through: 0, text: "" };
  return { through: Number(marker[1]), text: raw.slice(marker[0].length).trim() };
}

/** The transcript of the messages being folded in, as the summariser is shown them. */
const transcript = (messages: Message[]): string =>
  messages.map((m) => `${m.role === "user" ? "User" : "Assistant"}: ${m.content}`).join("\n\n");

/**
 * Folds whatever has newly fallen out of the window into the thread's summary, with one
 * completion. Returns false when there was nothing to do: a thread still short enough to fit
 * in the window, or one whose evicted messages are all accounted for already.
 *
 * Throws what the provider throws. The file is written only once the new summary is in hand,
 * so a failed or empty completion leaves the summary that was there — the next turn tries
 * again with the same messages, and until then the thread is a window with an older summary
 * in front of it rather than a broken one.
 */
export async function updateSummary(
  threadId: string,
  provider: Provider,
  dir = stateDir(),
): Promise<boolean> {
  const all = threadMessages(threadId, dir);
  // Everything before the window is what the summary is for.
  const evictedCount = all.length - HISTORY_LIMIT;
  const { through, text: previous } = readSummary(threadId, dir);
  if (evictedCount <= through) return false;

  const prompt = [
    previous ? `The summary so far:\n\n${previous}` : "There is no summary yet.",
    `New messages, which are now out of view:\n\n${transcript(all.slice(through, evictedCount))}`,
  ].join("\n\n");

  let summary = "";
  for await (const event of provider.stream(
    [
      { role: "system", content: SUMMARY_SYSTEM },
      { role: "user", content: prompt },
    ],
    [],
  )) {
    if (event.type === "text") summary += event.text;
  }
  summary = summary.trim();
  if (!summary) return false;

  writeFileSync(
    summaryFile(threadId, dir),
    `<!-- yorozu:through ${evictedCount} -->\n${summary}\n`,
  );
  return true;
}

/**
 * The messages a turn in this thread runs on: the rolling summary, when there is one, and then
 * the window. The summary goes in as its own system message so it sits between the agent's
 * prompt and the conversation, and reads as background rather than as something anyone said.
 */
export function contextFor(threadId: string, dir = stateDir(), vision = false): Message[] {
  const { text } = readSummary(threadId, dir);
  const window = threadHistory(threadId, dir, vision);
  return text ? [{ role: "system", content: `Earlier in this thread: ${text}` }, ...window] : window;
}
