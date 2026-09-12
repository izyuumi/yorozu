/**
 * Threads: an append-only event log per thread in `<state dir>/threads/<id>.jsonl` plus a
 * `threads.json` index of what exists. The log is the history the agent is given back as
 * context and the source of every delta the phones sync from.
 * See docs/spec-v1.html sections 3 and 8.
 */

import { randomUUID } from "node:crypto";
import { appendFileSync, existsSync, mkdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import type { EventKind, ThreadSummary, YorozuEvent } from "@yorozu/shared";
import { stateDir } from "./memory.js";
import type { Message } from "./provider.js";

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

function saveThreads(threads: ThreadRecord[], dir: string): void {
  mkdirSync(dir, { recursive: true });
  writeFileSync(indexFile(dir), `${JSON.stringify(threads, null, 2)}\n`);
}

/**
 * When the thread was last written to, as epoch milliseconds. The log's mtime rather than its
 * last event: appends are the only writes, so it is the same answer without parsing the file.
 * A thread with no log yet is as old as it is.
 */
const lastActivity = (thread: ThreadRecord, dir: string): number => {
  try {
    return statSync(logFile(thread.id, dir)).mtimeMs;
  } catch {
    return Date.parse(thread.createdAt) || 0;
  }
};

/**
 * Every live and archived thread, most recently active first. A missing, broken or hand-edited
 * index reads as empty rather than throwing.
 *
 * Migration: Yorozu used to pin a thread called `home` that could not be archived. It is an
 * ordinary thread now if anything was ever said in it, and gone if nothing was.
 */
export function listThreads(dir = stateDir()): ThreadRecord[] {
  let stored: ThreadRecord[] = [];
  try {
    const parsed: unknown = JSON.parse(readFileSync(indexFile(dir), "utf8"));
    if (Array.isArray(parsed)) stored = parsed as ThreadRecord[];
  } catch {
    // First run, or a file someone broke by hand.
  }
  const threads = stored.flatMap((thread) =>
    thread.id !== "home"
      ? [thread]
      : hasLog(thread.id, dir)
        ? [{ ...thread, title: thread.title || "Home" }]
        : [],
  );
  if (JSON.stringify(threads) !== JSON.stringify(stored)) saveThreads(threads, dir);
  return threads.sort((a, b) => lastActivity(b, dir) - lastActivity(a, dir));
}

/** The thread a turn that has none of its own belongs to: the newest one, or a new one. */
export const currentThread = (dir = stateDir()): string =>
  listThreads(dir).find((thread) => !thread.archived)?.id ?? createThread(undefined, dir).id;

/**
 * A thread is created unnamed: nobody is asked for a title, the runtime writes one after the
 * first reply, and the lists draw a placeholder until then.
 *
 * `id` is the client's: a draft thread lives on the device until its first message, which is
 * sent straight after the `thread_create` and has to land in the thread it was typed in. An id
 * that already exists is returned as it stands rather than duplicated.
 */
export function createThread(title?: string, dir = stateDir(), id: string = randomUUID()): ThreadRecord {
  const existing = listThreads(dir).find((thread) => thread.id === id);
  if (existing) return existing;
  const thread: ThreadRecord = {
    id,
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

/** False when there is no such thread, or when it is archived already. */
export function archiveThread(id: string, dir = stateDir()): boolean {
  const threads = listThreads(dir);
  const thread = threads.find((candidate) => candidate.id === id);
  if (!thread || thread.archived) return false;
  thread.archived = true;
  saveThreads(threads, dir);
  return true;
}

/** What the phone's thread list renders. */
export const threadSummaries = (dir = stateDir()): ThreadSummary[] =>
  listThreads(dir).map((thread) => ({
    id: thread.id,
    title: thread.title,
    archived: thread.archived,
    lastActivity: lastActivity(thread, dir),
  }));

const logFile = (threadId: string, dir: string): string =>
  // The id is a UUID, but it arrives from the phone: keep it a file name regardless.
  join(threadsDir(dir), `${threadId.replace(/[^\w.-]/g, "_")}.jsonl`);

/** Whether anything was ever appended to the thread's log. */
const hasLog = (threadId: string, dir: string): boolean => {
  try {
    return statSync(logFile(threadId, dir)).size > 0;
  } catch {
    return false;
  }
};

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
