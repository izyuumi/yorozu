/**
 * Threads: an append-only event log per thread in `<state dir>/threads/<id>.jsonl` plus a
 * `threads.json` index of what exists. The log is the history the agent is given back as
 * context and the source of every delta the phones sync from.
 * See docs/spec-v1.html sections 3 and 8.
 */

import { randomUUID } from "node:crypto";
import { appendFileSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import type { EventKind, ThreadSummary, YorozuEvent } from "@yorozu/shared";
import { stateDir } from "./memory.js";
import type { Message } from "./provider.js";

/** Always exists, always pinned, never archives. */
export const HOME_THREAD = "home";

/** How much of a thread's log is replayed to the model as context. */
export const HISTORY_LIMIT = 40;

/** Cap on one `sync_delta`, for a device that is far behind or brand new. */
export const SYNC_LIMIT = 200;

export interface ThreadRecord {
  id: string;
  /** Empty until the runtime auto-titles the thread or the user renames it. */
  title: string;
  /** ISO 8601. */
  createdAt: string;
  archived: boolean;
}

/** Kinds that belong to a thread's history. Control traffic is not logged. */
const LOGGED: ReadonlySet<EventKind> = new Set<EventKind>([
  "message",
  "thought",
  "tool_call",
  "tool_result",
  "approval_card",
  "approval_answer",
]);

export const threadsDir = (dir = stateDir()): string => join(dir, "threads");

const indexFile = (dir: string): string => join(dir, "threads.json");

const home = (): ThreadRecord => ({
  id: HOME_THREAD,
  title: "Home",
  createdAt: new Date().toISOString(),
  archived: false,
});

function saveThreads(threads: ThreadRecord[], dir: string): void {
  mkdirSync(dir, { recursive: true });
  writeFileSync(indexFile(dir), `${JSON.stringify(threads, null, 2)}\n`);
}

/**
 * Every thread, Home first. A missing, broken or hand-edited index is repaired rather than
 * thrown over: Home is re-seeded and un-archived on the way out.
 */
export function listThreads(dir = stateDir()): ThreadRecord[] {
  let stored: ThreadRecord[] = [];
  try {
    const parsed: unknown = JSON.parse(readFileSync(indexFile(dir), "utf8"));
    if (Array.isArray(parsed)) stored = parsed as ThreadRecord[];
  } catch {
    // First run, or a file someone broke by hand.
  }
  const rest = stored.filter((thread) => thread.id !== HOME_THREAD);
  const threads = [{ ...(stored.find((t) => t.id === HOME_THREAD) ?? home()), archived: false }, ...rest];
  if (JSON.stringify(threads) !== JSON.stringify(stored)) saveThreads(threads, dir);
  return threads;
}

/**
 * A thread is created unnamed: nobody is asked for a title, the runtime writes one after the
 * first reply, and the lists draw a placeholder until then.
 */
export function createThread(title?: string, dir = stateDir()): ThreadRecord {
  const thread: ThreadRecord = {
    id: randomUUID(),
    title: title?.trim() ?? "",
    createdAt: new Date().toISOString(),
    archived: false,
  };
  saveThreads([...listThreads(dir), thread], dir);
  return thread;
}

/**
 * False when there is no such thread, or when the title is the one it already has. The same
 * call serves the user's rename and the runtime's auto-title; what keeps auto-title off a
 * title the user chose is that it only ever runs while the title is still empty.
 */
export function renameThread(id: string, title: string, dir = stateDir()): boolean {
  const threads = listThreads(dir);
  const thread = threads.find((candidate) => candidate.id === id);
  const trimmed = title.trim();
  if (!thread || !trimmed || thread.title === trimmed) return false;
  thread.title = trimmed;
  saveThreads(threads, dir);
  return true;
}

/** False when there is no such thread, or when it is Home: Home never archives. */
export function archiveThread(id: string, dir = stateDir()): boolean {
  if (id === HOME_THREAD) return false;
  const threads = listThreads(dir);
  const thread = threads.find((candidate) => candidate.id === id);
  if (!thread || thread.archived) return false;
  thread.archived = true;
  saveThreads(threads, dir);
  return true;
}

/** What the phone's thread list renders. */
export const threadSummaries = (dir = stateDir()): ThreadSummary[] =>
  listThreads(dir).map(({ id, title, archived }) => ({
    id,
    title,
    archived,
    pinned: id === HOME_THREAD,
  }));

const logFile = (threadId: string, dir: string): string =>
  // The id is ours (a UUID or `home`), but it arrives from the phone: keep it a file name.
  join(threadsDir(dir), `${threadId.replace(/[^\w.-]/g, "_")}.jsonl`);

/** Appends to the thread's log. Control events (sync, thread admin) are not history. */
export function appendThreadEvent(event: YorozuEvent, dir = stateDir()): void {
  if (!LOGGED.has(event.kind)) return;
  mkdirSync(threadsDir(dir), { recursive: true });
  appendFileSync(logFile(event.threadId, dir), `${JSON.stringify(event)}\n`);
}

/** The thread's events, oldest first. Unreadable lines are skipped. */
export function readThreadEvents(threadId: string, dir = stateDir()): YorozuEvent[] {
  const file = logFile(threadId, dir);
  if (!existsSync(file)) return [];
  const events: YorozuEvent[] = [];
  for (const line of readFileSync(file, "utf8").split("\n")) {
    if (!line.trim()) continue;
    try {
      events.push(JSON.parse(line) as YorozuEvent);
    } catch {
      // A half-written last line must not lose the thread.
    }
  }
  return events;
}

/**
 * Everything the device has not seen. An unknown `afterEventId` — a fresh install, or a log
 * that has rotated past it — means the tail of the thread rather than nothing.
 */
export function eventsAfter(
  threadId: string,
  afterEventId?: string,
  dir = stateDir(),
): YorozuEvent[] {
  const events = readThreadEvents(threadId, dir);
  const at = afterEventId ? events.findLastIndex((event) => event.id === afterEventId) : -1;
  return (at >= 0 ? events.slice(at + 1) : events).slice(-SYNC_LIMIT);
}

/**
 * The thread's messages as model context, oldest first.
 *
 * Compaction is the last `HISTORY_LIMIT` messages and nothing cleverer.
 * TODO: summarise what falls off the front instead of dropping it — the spec wants a rolling
 * summary plus the recent tail, which needs a provider call and a place to cache the summary.
 */
export function threadHistory(threadId: string, dir = stateDir()): Message[] {
  return readThreadEvents(threadId, dir)
    .filter((event) => event.kind === "message")
    .slice(-HISTORY_LIMIT)
    .map((event) => ({
      role: event.data.role === "user" ? ("user" as const) : ("assistant" as const),
      content: event.data.text,
    }));
}
