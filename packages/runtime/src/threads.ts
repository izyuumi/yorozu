/**
 * Threads: an append-only event log per thread in `<state dir>/threads/<id>.jsonl` plus a
 * `threads.json` index of what exists. The log is the history the agent is given back as
 * context and the source of every delta the phones sync from.
 * See docs/spec-v1.html sections 3 and 8.
 */

import { randomUUID } from "node:crypto";
import { appendFileSync, existsSync, mkdirSync, readFileSync, renameSync, statSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import {
  THREAD_AGENTS,
  TOOL_RESULT_PREVIEW_CHARS,
  type EventKind,
  type ReasoningEffort,
  type ThreadAgent,
  type ThreadSummary,
  type YorozuEvent,
} from "@yorozu/shared";
import { stateDir } from "./memory.js";
import type { Message } from "./provider.js";
import { syncPage } from "./thread-sync.js";

/** How much of a thread's log is replayed to the model as context. */
export const HISTORY_LIMIT = 40;

/** Cap on one thread's share of a `sync_delta`, for a device that is far behind or brand new. */
export const SYNC_LIMIT = 200;

/**
 * Most event JSON one `sync_delta` carries. The frame is sealed and base64url'd on top of this,
 * and the hosted relay refuses a WebSocket message over 1 MiB — which closed the Mac's socket,
 * and a phone that then reconnected asked for the same page again. Never empty: an event
 * bigger than this still travels, alone.
 */
export const SYNC_PAGE_BYTES = 512 * 1024;

export interface ThreadRecord {
  bypass?: boolean;
  nativeTurn?: { id: string; state: "running" | "interrupted"; userEventId?: string; recoveryAttempts?: number; recoveryActive?: boolean };
  id: string;
  /** Empty until the runtime auto-titles the thread or the user renames it. */
  title: string;
  /** ISO 8601. */
  createdAt: string;
  archived: boolean;
  /** Pinned threads lead the phone's list. Absent on every thread written before the flag. */
  pinned?: boolean;
  /**
   * The `<providerId>/<model>` spec this thread's turns lead with. Absent — the usual case —
   * means the configured chain and nothing thread-specific. See `setThreadModel`.
   */
  model?: string;
  /** Requested reasoning depth. Absent leaves the provider default in charge. */
  effort?: ReasoningEffort;
  /**
   * Which agent answers this thread, fixed for its life. Absent — every thread from before the
   * field, and every ordinary one since — means `yorozu`. See `threadAgent`.
   */
  agent?: Exclude<ThreadAgent, "yorozu">;
  /** A native agent's working directory, chosen at creation. Absent on a `yorozu` thread. */
  cwd?: string;
  /**
   * The native agent's own session id, from the thread's last turn, so the next one resumes
   * it. Never leaves the Mac. Absent until the agent has answered once.
   */
  nativeSessionId?: string;
  /**
   * When the thread was last read, on any device, epoch milliseconds. Absent means never.
   *
   * Read state lives here rather than on each device: a phone could only ever answer "did a
   * reply arrive while I had this open", which is a different question on every device and the
   * wrong one on any device that was asleep. See `markThreadRead`.
   */
  lastReadAt?: number;
}

/** Kinds that belong to a thread's history. Control traffic is not logged. */
const LOGGED: ReadonlySet<EventKind> = new Set<EventKind>([
  "message",
  "thought",
  "tool_call",
  "tool_result",
  "approval_card",
  "approval_answer",
  "approval_status",
  "question_card",
  "question_answer",
  "progress_card",
]);

export const threadsDir = (dir = stateDir()): string => join(dir, "threads");

const indexFile = (dir: string): string => join(dir, "threads.json");

function saveThreads(threads: ThreadRecord[], dir: string): void {
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  const temporary = indexFile(dir) + ".tmp";
  writeFileSync(temporary, `${JSON.stringify(threads, null, 2)}\n`, { flush: true, mode: 0o600 });
  renameSync(temporary, indexFile(dir));
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

/** Validate persisted metadata before any caller can rewrite the index. */
function validThread(value: unknown): value is ThreadRecord {
  if (!value || typeof value !== "object") return false;
  const t = value as Record<string, unknown>;
  const turn = t.nativeTurn as ThreadRecord["nativeTurn"];
  return typeof t.id === "string" && t.id.length > 0 && typeof t.title === "string"
    && typeof t.createdAt === "string" && Number.isFinite(Date.parse(t.createdAt))
    && typeof t.archived === "boolean"
    && ["model", "effort", "agent", "cwd", "nativeSessionId"].every((key) => t[key] === undefined || typeof t[key] === "string")
    && ["pinned", "bypass"].every((key) => t[key] === undefined || typeof t[key] === "boolean")
    && (t.lastReadAt === undefined || typeof t.lastReadAt === "number" && Number.isFinite(t.lastReadAt))
    && (turn === undefined || !!turn && typeof turn === "object"
      && typeof turn.id === "string" && ["running", "interrupted"].includes(turn.state)
      && (turn.userEventId === undefined || typeof turn.userEventId === "string" && turn.userEventId.length <= 128)
      && (turn.recoveryAttempts === undefined || Number.isSafeInteger(turn.recoveryAttempts) &&
        turn.recoveryAttempts >= 0 && turn.recoveryAttempts <= 3)
      && (turn.recoveryActive === undefined || typeof turn.recoveryActive === "boolean"));
}

/**
 * Every live and archived thread, most recently active first. Only an absent index
 * is a first run. Corruption stops writes: logs cannot reconstruct native session ids,
 * working directories or approval bypass, so guessing metadata would silently change agents.
 * The original index stays untouched for repair or restoration from backup.
 */
export function listThreads(dir = stateDir()): ThreadRecord[] {
  let stored: ThreadRecord[];
  try {
    let raw: string;
    try {
      raw = readFileSync(indexFile(dir), "utf8");
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
      return [];
    }
    const parsed: unknown = JSON.parse(raw);
    if (!Array.isArray(parsed) || !parsed.every(validThread)
      || new Set(parsed.map((t) => t.id)).size !== parsed.length) throw new Error("invalid thread metadata");
    stored = parsed;
  } catch (cause) {
    throw new Error(`Cannot read thread index ${indexFile(dir)}; restore or repair it before continuing`, { cause });
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
export function createThread(
  title?: string,
  dir = stateDir(),
  id: string = randomUUID(),
  home: { agent?: ThreadAgent; cwd?: string } = {},
): ThreadRecord {
  const agent = home.agent ?? "yorozu";
  if (!THREAD_AGENTS.includes(agent)) throw new Error(`unknown agent "${String(agent)}"`);
  const existing = listThreads(dir).find((thread) => thread.id === id);
  if (existing) return existing;
  const cwd = home.cwd?.trim();
  // A native agent runs in its thread's folder and nowhere else, so a record without one is
  // not written: it would send the agent to whatever directory the sidecar was started in.
  if (agent !== "yorozu" && !cwd) throw new Error(`a ${agent} thread needs a project folder`);
  const thread: ThreadRecord = {
    id,
    title: title?.trim() ?? "",
    createdAt: new Date().toISOString(),
    archived: false,
    // Only a native agent has a home of its own; a `yorozu` thread is the default, unspelled.
    ...(agent !== "yorozu" ? { agent, ...(cwd ? { cwd } : {}) } : {}),
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

/**
 * Archives a thread, or brings it back with `archived` false. Returns false when there is no
 * such thread, or when it is in the state asked for already.
 */
export const archiveThread = (id: string, dir = stateDir(), archived = true): boolean =>
  setFlag(id, dir, "archived", archived);

export const setThreadBypass = (id: string, bypass: boolean, dir = stateDir()): boolean =>
  threadAgent(id, dir) !== "yorozu" && setFlag(id, dir, "bypass", bypass);

/** Pins a thread to the top of the list, or unpins it. False when nothing changed. */
export const pinThread = (id: string, pinned: boolean, dir = stateDir()): boolean =>
  setFlag(id, dir, "pinned", pinned);

/**
 * Runs this thread on one model rather than the configured chain: `spec` is a
 * `<providerId>/<model>` from `providers.json`, and null puts it back on the default. The spec
 * is not validated here — a provider that has since been renamed or deleted is a chain that
 * falls through to the default one, which is the same thing that happens to a spec that fails.
 *
 * False when there is no such thread, or when it is on that model already.
 */
export function setThreadModel(id: string, spec: string | null, dir = stateDir()): boolean {
  const threads = listThreads(dir);
  const thread = threads.find((candidate) => candidate.id === id);
  const model = spec?.trim() || undefined;
  if (!thread || thread.model === model) return false;
  if (model) thread.model = model;
  else delete thread.model;
  saveThreads(threads, dir);
  return true;
}

/** Sets one thread's reasoning depth, or clears it when effort is null. */
export function setThreadEffort(
  id: string,
  effort: ReasoningEffort | null,
  dir = stateDir(),
): boolean {
  const threads = listThreads(dir);
  const thread = threads.find((candidate) => candidate.id === id);
  if (!thread || thread.effort === (effort ?? undefined)) return false;
  if (effort) thread.effort = effort;
  else delete thread.effort;
  saveThreads(threads, dir);
  return true;
}

/**
 * Records that `id` was read up to `at`. The later of the two marks wins, so two devices
 * reporting out of order cannot walk the mark backwards. `reset` assigns `at` outright
 * instead, which is what makes "Mark as unread" — an `at` deliberately behind the newest
 * reply — actually stick.
 *
 * False when there is no such thread, or when the mark did not move: an idempotent frame from
 * a second device should not rewrite the index or claim it changed anything.
 */
export function markThreadRead(id: string, at: number, dir = stateDir(), reset = false): boolean {
  const threads = listThreads(dir);
  const thread = threads.find((candidate) => candidate.id === id);
  if (!thread) return false;
  const next = reset ? at : Math.max(thread.lastReadAt ?? 0, at);
  if (thread.lastReadAt === next) return false;
  thread.lastReadAt = next;
  saveThreads(threads, dir);
  return true;
}

/** The spec a thread's turns lead with, or undefined for the configured chain. */
export const threadModel = (id: string, dir = stateDir()): string | undefined =>
  listThreads(dir).find((thread) => thread.id === id)?.model;

/** The reasoning depth a thread requests, or undefined for the provider default. */
export const threadEffort = (id: string, dir = stateDir()): ReasoningEffort | undefined =>
  listThreads(dir).find((thread) => thread.id === id)?.effort;

/**
 * Who answers `id`. A thread with no agent field, a thread that does not exist, and a record
 * naming an agent this runtime does not know all read as `yorozu`: today's behaviour, and the
 * only one that can never be the wrong one to fall back on.
 */
export function threadAgent(id: string, dir = stateDir()): ThreadAgent {
  const agent = listThreads(dir).find((thread) => thread.id === id)?.agent;
  return agent && THREAD_AGENTS.includes(agent) ? agent : "yorozu";
}

/**
 * The folder and native session a native agent's next turn picks up from. `cwd` is absent only
 * on a record from before folders were required; the caller refuses to run without one rather
 * than letting the agent fall back to the sidecar's own directory.
 */
export function threadHome(id: string, dir = stateDir()): { cwd?: string; sessionId?: string } {
  const thread = listThreads(dir).find((candidate) => candidate.id === id);
  return {
    ...(thread?.cwd ? { cwd: thread.cwd } : {}),
    ...(thread?.nativeSessionId ? { sessionId: thread.nativeSessionId } : {}),
  };
}

/** Records the native session the thread's next turn resumes. False when nothing changed. */
export function setThreadSession(id: string, sessionId: string | undefined, dir = stateDir()): boolean {
  const threads = listThreads(dir);
  const thread = threads.find((candidate) => candidate.id === id);
  if (!thread || thread.nativeSessionId === sessionId) return false;
  if (sessionId) thread.nativeSessionId = sessionId;
  else delete thread.nativeSessionId;
  saveThreads(threads, dir);
  return true;
}

/**
 * Sets one boolean on one thread and writes the index back, but only when the value is new:
 * both flags are toggles a second device may already have set, and an idempotent frame should
 * not rewrite the file or claim it changed anything.
 */
function setFlag(id: string, dir: string, flag: "archived" | "pinned" | "bypass", value: boolean): boolean {
  const threads = listThreads(dir);
  const thread = threads.find((candidate) => candidate.id === id);
  if (!thread || (thread[flag] ?? false) === value) return false;
  thread[flag] = value;
  saveThreads(threads, dir);
  return true;
}

/** How much of the newest message the list's one-line preview is given. */
const PREVIEW_LIMIT = 140;

/**
 * What a list row needs from the thread's log, in one pass over it: the newest thing said in
 * it — agent's or user's — flattened to one line for the preview, and when the agent last
 * spoke, which is half of whether the thread is unread.
 *
 * Both are undefined in a thread nothing has been said in yet, so the row draws nothing rather
 * than "" and the thread reads as read rather than as unread-since-the-epoch.
 */
function logSummary(threadId: string, dir: string, minTs = 0): { preview?: string; lastAgentAt?: number; awaitingApproval?: true } {
  const events = readThreadEvents(threadId, dir).filter((event) => event.ts >= minTs);
  const last = events.findLast((event) => event.kind === "message");
  const lastAgent = events.findLast(
    (event) => event.kind === "message" && event.data.role === "agent",
  );
  const line = last?.kind === "message" ? last.data.text.replace(/\s+/gu, " ").trim() : "";
  // The same answer state the chat's cards draw from: a card is open until its answer is logged.
  const answered = new Set(events.flatMap((e) => (e.kind === "approval_answer" ? [e.data.actionId] : [])));
  const awaiting = events.some((e) => e.kind === "approval_card" && !answered.has(e.data.actionId));
  return {
    ...(line ? { preview: line.slice(0, PREVIEW_LIMIT) } : {}),
    ...(lastAgent ? { lastAgentAt: lastAgent.ts } : {}),
    ...(awaiting ? { awaitingApproval: true } : {}),
  };
}

/** What the phone's thread list renders. */
export const threadSummaries = (dir = stateDir(), minTs = 0): ThreadSummary[] =>
  listThreads(dir).map((thread) => {
    const { preview, lastAgentAt, awaitingApproval } = logSummary(thread.id, dir, minTs);
    return {
      id: thread.id,
      title: thread.title,
      archived: thread.archived,
      lastActivity: lastActivity(thread, dir),
      ...(preview === undefined ? {} : { lastMessage: preview }),
      pinned: thread.pinned ?? false,
      ...(thread.model ? { model: thread.model } : {}),
      ...(thread.effort ? { effort: thread.effort } : {}),
      ...(thread.agent ? { bypass: thread.bypass ?? false } : {}),
      ...(thread.nativeTurn?.state === "interrupted" &&
        ((thread.nativeTurn.recoveryAttempts ?? 0) >= 3 || !thread.nativeTurn.userEventId)
        ? { interruptedTurnId: thread.nativeTurn.id, canResume: !!thread.nativeTurn.userEventId } : {}),
      ...(thread.nativeTurn?.userEventId &&
        (thread.nativeTurn.state === "running" && thread.nativeTurn.recoveryActive === true ||
          thread.nativeTurn.state === "interrupted" && (thread.nativeTurn.recoveryAttempts ?? 0) < 3)
        ? { recoveryState: "recovering" as const } : {}),
      // Absent on a yorozu thread: that is the default, and what older phones already assume.
      ...(thread.agent && THREAD_AGENTS.includes(thread.agent) ? { agent: thread.agent } : {}),
      ...(thread.agent && thread.cwd ? { cwd: thread.cwd } : {}),
      // The two the dot is drawn from. Absent rather than 0 when there is nothing to say, so a
      // thread nobody has read and nobody has been answered in is not permanently bold.
      ...(thread.lastReadAt === undefined ? {} : { lastReadAt: thread.lastReadAt }),
      ...(lastAgentAt === undefined ? {} : { lastAgentAt }),
      ...(awaitingApproval ? { awaitingApproval } : {}),
    };
  });

/**
 * One of a thread's files: its log, or the rolling summary beside it. The id is a UUID, but it
 * arrives from the phone: keep it a file name regardless.
 */
export const threadFile = (threadId: string, suffix: string, dir = stateDir()): string =>
  join(threadsDir(dir), `${threadId.replace(/[^\w.-]/g, "_")}${suffix}`);

const logFile = (threadId: string, dir: string): string => threadFile(threadId, ".jsonl", dir);

/** Whether anything was ever appended to the thread's log. */
const hasLog = (threadId: string, dir: string): boolean => {
  try {
    return statSync(logFile(threadId, dir)).size > 0;
  } catch {
    return false;
  }
};

/**
 * A tool result too long to travel whole. The head goes in the log and to the phones, flagged;
 * the whole event is kept beside the log, so `tool_result_request` can answer with it under the
 * same id. Returns the event to log and send — the original when it fits.
 */
export function stashToolResult(
  event: YorozuEvent & { kind: "tool_result" },
  dir = stateDir(),
  limit = TOOL_RESULT_PREVIEW_CHARS,
): YorozuEvent & { kind: "tool_result" } {
  if (event.data.output.length <= limit) return event;
  mkdirSync(threadsDir(dir), { recursive: true, mode: 0o700 });
  writeFileSync(resultFile(event.threadId, event.data.callId, dir), JSON.stringify(event), { mode: 0o600 });
  const end = /[\uD800-\uDBFF]/.test(event.data.output[limit - 1]!) ? limit - 1 : limit;
  return { ...event, data: { ...event.data, output: event.data.output.slice(0, end), truncated: true } };
}

/** The whole of a stashed tool result, or undefined when none was kept for that call. */
export function fullToolResult(
  threadId: string,
  callId: string,
  dir = stateDir(),
): (YorozuEvent & { kind: "tool_result" }) | undefined {
  try {
    return JSON.parse(readFileSync(resultFile(threadId, callId, dir), "utf8")) as YorozuEvent & { kind: "tool_result" };
  } catch {
    return undefined;
  }
}

const resultFile = (threadId: string, callId: string, dir: string): string =>
  threadFile(threadId, `.result-${callId.replace(/[^\w.-]/g, "_")}.json`, dir);

/** Appends to the thread's log. Control events (sync, thread admin) are not history. */
export function appendThreadEvent(event: YorozuEvent, dir = stateDir()): void {
  if (!LOGGED.has(event.kind)) return;
  mkdirSync(threadsDir(dir), { recursive: true, mode: 0o700 });
  appendFileSync(logFile(event.threadId, dir), `${JSON.stringify(event)}\n`,
    { mode: 0o600, flush: event.kind === "approval_status" });
}

/** The thread's events, oldest first. Unreadable lines are skipped. */
export function readThreadEvents(threadId: string, dir = stateDir()): YorozuEvent[] {
  const file = logFile(threadId, dir);
  if (!existsSync(file)) return [];
  const events: YorozuEvent[] = [];
  for (const line of readFileSync(file, "utf8").split("\n")) {
    if (!line.trim()) continue;
    try {
      const event = JSON.parse(line) as YorozuEvent;
      // Kinds this build no longer knows (old reactions) stay in the file and out of the sync.
      if (LOGGED.has(event.kind)) events.push(event);
    } catch {
      // A half-written last line must not lose the thread.
    }
  }
  return events;
}

/**
 * Everything the device has not seen. An unknown `afterEventId` — a fresh install, or a log
 * that has rotated past it — starts from the oldest retained event. Returning the first page
 * lets a client advance its cursor until it has the complete searchable thread.
 */
export function eventsAfter(
  threadId: string,
  afterEventId?: string,
  dir = stateDir(),
  minTs = 0,
  include?: (event: YorozuEvent) => boolean,
): YorozuEvent[] {
  return syncPage(logFile(threadId, dir), afterEventId, minTs, SYNC_LIMIT, include);
}

/**
 * Every message in the thread as model context, oldest first — the whole log, however long.
 * `threadHistory` is the window of it a turn is given; summary.ts reads the rest, which is
 * what it rolls up.
 */
export function threadMessages(threadId: string, dir = stateDir(), vision = false): Message[] {
  return readThreadEvents(threadId, dir)
    .filter((event) => event.kind === "message")
    .map((event) => {
      const role = event.data.role === "user" ? ("user" as const) : ("assistant" as const);
      const attachments = event.data.attachments ?? [];
      if (attachments.length === 0) return { role, content: event.data.text };
      // A model that can see gets the bytes. One that cannot is told what came with the
      // message, because the text alone often does not stand up on its own — "what is wrong
      // with this?" needs at least the file's name to be answerable.
      const images = vision ? attachments.filter((item) => item.mime.startsWith("image/")) : [];
      const named = attachments.filter((item) => !vision || !item.mime.startsWith("image/"));
      const notes = named.map((item) => `[attached: ${item.name} (${item.mime})]`).join("\n");
      const content = [event.data.text, notes].filter(Boolean).join("\n\n");
      if (images.length > 0) {
        return {
          role,
          content,
          images: images.map(({ mime, data }) => ({ mime, data })),
        };
      }
      return { role, content };
    });
}

/**
 * The window of the thread a turn is given: the last `HISTORY_LIMIT` messages. What fell off
 * the front is not dropped — `contextFor` in summary.ts puts a rolling summary of it in front
 * of this.
 */
export const threadHistory = (threadId: string, dir = stateDir(), vision = false): Message[] =>
  threadMessages(threadId, dir, vision).slice(-HISTORY_LIMIT);

/** Written before launching the SDK so a replacement host can recover the same turn. */
export function setNativeTurn(id: string, turn: ThreadRecord["nativeTurn"], dir = stateDir()): void {
  const threads = listThreads(dir);
  const thread = threads.find((t) => t.id === id);
  if (!thread || !thread.agent) return;
  if (turn) thread.nativeTurn = turn;
  else delete thread.nativeTurn;
  saveThreads(threads, dir);
}

export function recoverNativeTurns(dir = stateDir()): void {
  const threads = listThreads(dir);
  let changed = false;
  for (const thread of threads) {
    if (thread.agent && thread.nativeTurn) {
      const events = readThreadEvents(thread.id, dir);
      if (!thread.nativeTurn.userEventId) {
        const match = /^native:(.+):final$/.exec(thread.nativeTurn.id);
        if (match && events.some((event) => event.id === match[1] && event.kind === "message" && event.data.role === "user")) {
          thread.nativeTurn.userEventId = match[1];
          changed = true;
        }
      }
      const finished = events.some((event) => event.id === thread.nativeTurn!.id && event.kind === "message" && event.data.done);
      const wasRunning = thread.nativeTurn.state === "running";
      if (finished) delete thread.nativeTurn;
      else if (wasRunning) thread.nativeTurn.state = "interrupted";
      else continue;
      if (!wasRunning) { changed = true; continue; }
      // SDK callbacks died with the process: historical cards must not keep live buttons.
      const answered = new Set(events.flatMap((e) => e.kind === "approval_answer" ? [e.data.actionId] : e.kind === "question_answer" ? [e.data.questionId] : []));
      for (const event of events) {
        const base = { id: randomUUID(), threadId: thread.id, ts: Date.now(), agentId: "main" };
        if (event.kind === "approval_card" && event.data.nativeAgent && !answered.has(event.data.actionId)) {
          appendThreadEvent({ ...base, kind: "approval_answer", data: { actionId: event.data.actionId, answer: "no" } }, dir);
        } else if (event.kind === "question_card" && !answered.has(event.data.questionId)) {
          appendThreadEvent({ ...base, kind: "question_answer", data: { questionId: event.data.questionId, answer: "Interrupted" } }, dir);
        }
      }
      changed = true;
    }
  }
  if (changed) saveThreads(threads, dir);
}
