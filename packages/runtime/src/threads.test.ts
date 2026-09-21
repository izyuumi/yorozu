import { appendFileSync, mkdirSync, mkdtempSync, readFileSync, renameSync, rmSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { YorozuEvent } from "@yorozu/shared";
import { beforeEach, expect, test, vi } from "vitest";
import {
  appendThreadEvent,
  archiveThread,
  createThread,
  eventsAfter,
  fullToolResult,
  HISTORY_LIMIT,
  SYNC_LIMIT,
  listThreads,
  markThreadRead,
  pinThread,
  readThreadEvents,
  renameThread,
  setThreadEffort,
  setThreadModel,
  setThreadSession,
  stashToolResult,
  threadAgent,
  threadEffort,
  threadHistory,
  threadHome,
  threadModel,
  threadSummaries,
  threadsDir,
} from "./threads.js";

let dir: string;

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "yorozu-threads-"));
});

const HOME = "home";

const message = (id: string, text: string, threadId = HOME): YorozuEvent => ({
  id,
  threadId,
  ts: Number(id.slice(1)),
  agentId: "main",
  kind: "message",
  data: { role: "user", text },
});

const agentMessage = (id: string, text: string, threadId = HOME): YorozuEvent => ({
  id,
  threadId,
  ts: Number(id.slice(1)),
  agentId: "main",
  kind: "message",
  data: { role: "agent", text },
});

/** An index as an older Yorozu wrote it, with its pinned `home` thread in front. */
const writeLegacyIndex = (...rest: { id: string; title: string }[]): void =>
  writeFileSync(
    join(dir, "threads.json"),
    JSON.stringify([
      { id: HOME, title: "Home", createdAt: "2026-01-01T00:00:00.000Z", archived: false },
      ...rest.map((t) => ({ ...t, createdAt: "2026-01-02T00:00:00.000Z", archived: false })),
    ]),
  );

test("there are no threads at all until one is made", () => {
  expect(listThreads(dir)).toEqual([]);
  expect(threadSummaries(dir)).toEqual([]);
});

test("a legacy Home thread that was talked in becomes an ordinary thread", () => {
  writeLegacyIndex();
  appendThreadEvent(message("e1", "hi"), dir);

  expect(listThreads(dir)).toEqual([
    { id: HOME, title: "Home", createdAt: "2026-01-01T00:00:00.000Z", archived: false },
  ]);
  // Ordinary means archivable, which the pinned Home never was.
  expect(archiveThread(HOME, dir)).toBe(true);
  expect(listThreads(dir)[0]!.archived).toBe(true);
});

test("a legacy Home thread nothing was ever said in is dropped, for good", () => {
  writeLegacyIndex({ id: "t2", title: "Groceries" });

  expect(listThreads(dir).map((t) => t.id)).toEqual(["t2"]);
  // Migrated once: the rewritten index no longer mentions it.
  expect(readFileSync(join(dir, "threads.json"), "utf8")).not.toContain(`"${HOME}"`);
});

test("threads are listed and summarised most recently active first", () => {
  const older = createThread("Older", dir);
  const newer = createThread("Newer", dir);
  appendThreadEvent(message("e1", "hi", older.id), dir);
  appendThreadEvent(message("e2", "hi", newer.id), dir);
  // The two appends land in the same millisecond: age the older log by hand.
  const hourAgo = Date.now() / 1000 - 3600;
  utimesSync(join(threadsDir(dir), `${older.id}.jsonl`), hourAgo, hourAgo);

  expect(listThreads(dir).map((t) => t.title)).toEqual(["Newer", "Older"]);
  expect(threadSummaries(dir).map((t) => t.title)).toEqual(["Newer", "Older"]);
  // A thread with no log yet is only as recent as its own creation.
  expect(threadSummaries(dir)[1]!.lastActivity).toBeCloseTo(hourAgo * 1000, -4);
});

test("creating and archiving threads survives a reload", () => {
  const created = createThread("  Groceries  ", dir);
  expect(created.title).toBe("Groceries");
  expect(listThreads(dir).map((t) => t.id)).toEqual([created.id]);

  expect(archiveThread(created.id, dir)).toBe(true);
  expect(archiveThread(created.id, dir)).toBe(false);
  expect(archiveThread("nope", dir)).toBe(false);
  expect(threadSummaries(dir)).toEqual([
    {
      id: created.id,
      title: "Groceries",
      archived: true,
      pinned: false,
      lastActivity: expect.any(Number),
    },
  ]);

  // And back out again: the same frame with the flag off is what unarchives.
  expect(archiveThread(created.id, dir, false)).toBe(true);
  expect(archiveThread(created.id, dir, false)).toBe(false);
  expect(listThreads(dir)[0]!.archived).toBe(false);
});

test("a thread is created under the id the device minted, once", () => {
  const created = createThread("Groceries", dir, "draft-1");
  expect(created.id).toBe("draft-1");
  // A repeated frame — a reconnect, a second device — is not a second thread.
  expect(createThread("Groceries", dir, "draft-1").title).toBe("Groceries");
  expect(listThreads(dir)).toHaveLength(1);
});

test("a thread declares its agent at creation, and a thread from before the field is yorozu's", () => {
  const plain = createThread("Groceries", dir, "draft-1");
  expect(plain.agent).toBeUndefined();
  expect(threadAgent(plain.id, dir)).toBe("yorozu");
  expect(threadSummaries(dir)[0]).not.toHaveProperty("agent");

  const native = createThread("Fix the tests", dir, "draft-2", { agent: "claude-code", cwd: "/tmp/proj" });
  expect(native).toMatchObject({ agent: "claude-code", cwd: "/tmp/proj" });
  expect(threadAgent(native.id, dir)).toBe("claude-code");
  expect(threadSummaries(dir).find((t) => t.id === "draft-2")).toMatchObject({ agent: "claude-code", cwd: "/tmp/proj" });

  // An explicit `yorozu` is the default spelled out, and a cwd on it means nothing.
  const explicit = createThread(undefined, dir, "draft-3", { agent: "yorozu", cwd: "/tmp/proj" });
  expect(explicit).not.toHaveProperty("agent");
  expect(explicit).not.toHaveProperty("cwd");

  // A repeated frame with a different agent does not re-home an existing thread.
  expect(createThread("Groceries", dir, "draft-1", { agent: "codex" }).agent).toBeUndefined();

  expect(() => createThread("x", dir, "draft-4", { agent: "hermes" as never })).toThrow(/unknown agent "hermes"/);
  expect(listThreads(dir).map((t) => t.id).sort()).toEqual(["draft-1", "draft-2", "draft-3"]);

  // On disk, a record hand-edited to an agent the runtime no longer knows still loads — as yorozu's.
  const index = JSON.parse(readFileSync(join(dir, "threads.json"), "utf8")) as Record<string, unknown>[];
  index[0]!.agent = "hermes";
  writeFileSync(join(dir, "threads.json"), JSON.stringify(index));
  expect(threadAgent(index[0]!.id as string, dir)).toBe("yorozu");
});

test("a native thread remembers its agent's session, and never tells the phone", () => {
  const native = createThread("Fix", dir, "cc", { agent: "claude-code", cwd: "/tmp/proj" });
  expect(threadHome(native.id, dir)).toEqual({ cwd: "/tmp/proj" });
  expect(setThreadSession(native.id, "s-1", dir)).toBe(true);
  expect(setThreadSession(native.id, "s-1", dir)).toBe(false);
  expect(setThreadSession("nope", "s-1", dir)).toBe(false);
  expect(threadHome(native.id, dir)).toEqual({ cwd: "/tmp/proj", sessionId: "s-1" });
  expect(JSON.stringify(threadSummaries(dir))).not.toContain("s-1");
  expect(setThreadSession(native.id, undefined, dir)).toBe(true);
  expect(threadHome(native.id, dir)).toEqual({ cwd: "/tmp/proj" });
});

test("a long tool result travels as its head, and the whole of it is kept for the asking", () => {
  const result = (output: string): YorozuEvent & { kind: "tool_result" } => ({
    id: "r1", threadId: "cc", ts: 1, agentId: "main", kind: "tool_result", data: { callId: "call/1", ok: true, output },
  });
  // At the cap it fits, whole and unflagged; one past it, the head goes and the flag is set.
  const fits = result("x".repeat(20));
  expect(stashToolResult(fits, dir, 20)).toBe(fits);
  expect(fullToolResult("cc", "call/1", dir)).toBeUndefined();

  const long = result("y".repeat(21));
  const sent = stashToolResult(long, dir, 20);
  expect(sent).toEqual({ ...long, data: { callId: "call/1", ok: true, output: "y".repeat(20), truncated: true } });
  expect(fullToolResult("cc", "call/1", dir)).toEqual(long);
  expect(fullToolResult("cc", "other", dir)).toBeUndefined();
  expect(fullToolResult("elsewhere", "call/1", dir)).toBeUndefined();
});

test("a thread is created unnamed and renamed in place", () => {
  const created = createThread(undefined, dir);
  expect(created.title).toBe("");

  expect(renameThread(created.id, "  Weekend plans  ", dir)).toBe(true);
  expect(renameThread(created.id, "Weekend plans", dir)).toBe(false);
  // Nothing to rename, and nothing to rename it to, are both refusals rather than writes.
  expect(renameThread(created.id, "   ", dir)).toBe(false);
  expect(renameThread("nope", "Anything", dir)).toBe(false);
  expect(listThreads(dir)[0]!.title).toBe("Weekend plans");
});

test("events append per thread and only history kinds are logged", () => {
  appendThreadEvent(message("e1", "hi"), dir);
  appendThreadEvent(
    { id: "e2", threadId: HOME, ts: 2, agentId: "main", kind: "thought", data: { text: "hm" } },
    dir,
  );
  appendThreadEvent(
    { id: "r1", threadId: HOME, ts: 2, agentId: "phone", kind: "reaction", data: { messageId: "e1", emoji: "👍" } },
    dir,
  );
  appendThreadEvent(
    { id: "e3", threadId: HOME, ts: 3, agentId: "main", kind: "sync_request", data: { lastSeen: {} } },
    dir,
  );
  appendThreadEvent(message("e4", "other", "t2"), dir);

  expect(readThreadEvents(HOME, dir).map((e) => e.id)).toEqual(["e1", "e2", "r1"]);
  expect(readThreadEvents("t2", dir).map((e) => e.id)).toEqual(["e4"]);
  expect(readThreadEvents("never-written", dir)).toEqual([]);
  expect(readFileSync(join(threadsDir(dir), "home.jsonl"), "utf8").split("\n")).toHaveLength(4);
});

test("a delta is everything after the last-seen id, from the start when it is unknown", () => {
  for (const id of ["e1", "e2", "e3"]) appendThreadEvent(message(id, id), dir);

  expect(eventsAfter(HOME, "e1", dir).map((e) => e.id)).toEqual(["e2", "e3"]);
  expect(eventsAfter(HOME, "e3", dir)).toEqual([]);
  expect(eventsAfter(HOME, undefined, dir).map((e) => e.id)).toEqual(["e1", "e2", "e3"]);
  expect(eventsAfter(HOME, "gone", dir).map((e) => e.id)).toEqual(["e1", "e2", "e3"]);
  expect(eventsAfter("t2", "e1", dir)).toEqual([]);
});

test("sync pages advance through a long thread without dropping searchable history", () => {
  for (let n = 0; n <= SYNC_LIMIT; n++) appendThreadEvent(message(`e${n}`, `m${n}`), dir);
  const first = eventsAfter(HOME, undefined, dir);
  expect(first).toHaveLength(SYNC_LIMIT);
  expect(first[0]!.id).toBe("e0");
  expect(eventsAfter(HOME, first.at(-1)!.id, dir).map((event) => event.id)).toEqual([`e${SYNC_LIMIT}`]);
});

test("sync keeps messages between repeated progress cards across page boundaries", () => {
  const card: YorozuEvent = {
    id: "progress", threadId: HOME, ts: 1, agentId: "main", kind: "progress_card",
    data: { cardId: "progress", title: "Working", steps: [{ label: "Task", state: "running" }] },
  };
  const messages = Array.from({ length: SYNC_LIMIT - 1 }, (_, n) => message(`e${n}`, `m${n}`));
  for (const event of [...messages, card, message("e200", "must not disappear"), { ...card, ts: 2 }]) {
    appendThreadEvent(event, dir);
  }
  const first = eventsAfter(HOME, undefined, dir);
  const second = eventsAfter(HOME, first.at(-1)!.syncCursor ?? first.at(-1)!.id, dir);
  expect([...first, ...second].map((event) => event.id)).toContain("e200");
});

test("sync cursors keep their position when the same card is updated after a page", () => {
  const card: YorozuEvent = {
    id: "progress", threadId: HOME, ts: 1, agentId: "main", kind: "progress_card",
    data: { cardId: "progress", title: "Working", steps: [{ label: "Task", state: "running" }] },
  };
  appendThreadEvent(card, dir);
  const first = eventsAfter(HOME, undefined, dir);
  appendThreadEvent(message("e2", "must not disappear"), dir);
  appendThreadEvent(card, dir);
  const second = eventsAfter(HOME, first[0]!.syncCursor ?? first[0]!.id, dir);
  expect(second.map((event) => event.id)).toEqual(["e2", "progress"]);
  expect(second.at(-1)!.syncCursor).not.toBe(first[0]!.syncCursor);
  expect(eventsAfter(HOME, second.at(-1)!.syncCursor, dir)).toEqual([]);
});

test("sync rejects cursors whose log prefix was rewritten", () => {
  appendThreadEvent(message("e1", "first"), dir);
  appendThreadEvent(message("e2", "last"), dir);
  const cursor = eventsAfter(HOME, undefined, dir).at(-1)!.syncCursor;
  expect(cursor).toBeTypeOf("string");
  // Same file, same byte offsets and same final event: the earlier content changed.
  const file = join(threadsDir(dir), "home.jsonl");
  writeFileSync(file, readFileSync(file, "utf8").replace("first", "other"));
  expect(eventsAfter(HOME, cursor, dir).map((event) => event.id)).toEqual(["e1", "e2"]);
});

test("pairing cutoff is applied before the sync page limit", () => {
  for (let n = 0; n < SYNC_LIMIT + 10; n++) appendThreadEvent(message(`e${n}`, `old ${n}`), dir);
  appendThreadEvent({ ...message("e1000", "new"), ts: 1_000 }, dir);

  expect(eventsAfter(HOME, undefined, dir, 1_000).map((event) => event.id)).toEqual(["e1000"]);
});

test("history is the thread's messages, compacted to the last HISTORY_LIMIT", () => {
  for (let n = 1; n <= HISTORY_LIMIT + 5; n++) appendThreadEvent(message(`e${n}`, `m${n}`), dir);
  appendThreadEvent(
    { id: "reply", threadId: HOME, ts: 99, agentId: "main", kind: "message", data: { role: "agent", text: "ok" } },
    dir,
  );

  const history = threadHistory(HOME, dir);
  expect(history).toHaveLength(HISTORY_LIMIT);
  // 45 user messages plus the reply, compacted to the last 40.
  expect(history[0]).toEqual({ role: "user", content: "m7" });
  expect(history.at(-1)).toEqual({ role: "assistant", content: "ok" });
  expect(threadHistory("t2", dir)).toEqual([]);
});

test("a summary carries the newest message, on one line, for the list's preview", () => {
  const thread = createThread("Groceries", dir);
  appendThreadEvent(message("e1", "milk", thread.id), dir);
  appendThreadEvent(message("e2", "  and\n  eggs  ", thread.id), dir);

  expect(threadSummaries(dir)[0]!.lastMessage).toBe("and eggs");

  // Long ones are cut to something a row can draw rather than shipped whole.
  appendThreadEvent(message("e3", "x".repeat(500), thread.id), dir);
  expect(threadSummaries(dir)[0]!.lastMessage).toHaveLength(140);

  // A thread nothing was said in has no preview at all, rather than an empty one.
  const empty = createThread("Empty", dir);
  const summary = threadSummaries(dir).find((t) => t.id === empty.id);
  expect(summary!.lastMessage).toBeUndefined();
});

test("pinning is a flag on the thread, and idempotent", () => {
  const thread = createThread("Groceries", dir);
  expect(threadSummaries(dir)[0]!.pinned).toBe(false);

  expect(pinThread(thread.id, true, dir)).toBe(true);
  // A second device sending the same frame changes nothing and says so.
  expect(pinThread(thread.id, true, dir)).toBe(false);
  expect(pinThread("nope", true, dir)).toBe(false);
  expect(threadSummaries(dir)[0]!.pinned).toBe(true);

  expect(pinThread(thread.id, false, dir)).toBe(true);
  expect(listThreads(dir)[0]!.pinned).toBe(false);
});

test("a thread's model is a spec on the thread, and the default is its absence", () => {
  const thread = createThread("Groceries", dir);
  expect(threadModel(thread.id, dir)).toBeUndefined();
  // A thread on the default chain says nothing about a model at all, rather than "".
  expect(threadSummaries(dir)[0]!.model).toBeUndefined();

  expect(setThreadModel(thread.id, "claude/claude-opus-5", dir)).toBe(true);
  expect(setThreadModel(thread.id, "claude/claude-opus-5", dir)).toBe(false);
  expect(setThreadModel("nope", "claude/claude-opus-5", dir)).toBe(false);
  expect(threadModel(thread.id, dir)).toBe("claude/claude-opus-5");
  expect(threadSummaries(dir)[0]!.model).toBe("claude/claude-opus-5");

  // Back to the default: the field goes, so a thread on the chain looks like one that was
  // never pinned to anything.
  expect(setThreadModel(thread.id, null, dir)).toBe(true);
  expect(setThreadModel(thread.id, null, dir)).toBe(false);
  expect(listThreads(dir)[0]).not.toHaveProperty("model");
  // An empty spec is how a picker says "Default" over the wire, and means the same thing.
  setThreadModel(thread.id, "codex/gpt-5.6", dir);
  expect(setThreadModel(thread.id, "  ", dir)).toBe(true);
  expect(threadModel(thread.id, dir)).toBeUndefined();
});

test("a thread's reasoning effort persists and can return to provider default", () => {
  const thread = createThread("Groceries", dir);
  expect(threadEffort(thread.id, dir)).toBeUndefined();

  expect(setThreadEffort(thread.id, "high", dir)).toBe(true);
  expect(setThreadEffort(thread.id, "high", dir)).toBe(false);
  expect(setThreadEffort("nope", "low", dir)).toBe(false);
  expect(threadEffort(thread.id, dir)).toBe("high");
  expect(threadSummaries(dir)[0]!.effort).toBe("high");

  expect(setThreadEffort(thread.id, null, dir)).toBe(true);
  expect(threadEffort(thread.id, dir)).toBeUndefined();
  expect(listThreads(dir)[0]).not.toHaveProperty("effort");
});

test("an attachment reaches a vision model as bytes and a text-only one as its name", () => {
  const attachment = { name: "receipt.png", mime: "image/png", data: "aGk=" };
  appendThreadEvent(
    {
      id: "e1",
      threadId: HOME,
      ts: 1,
      agentId: "phone",
      kind: "message",
      data: { role: "user", text: "what is this?", attachment },
    },
    dir,
  );

  expect(threadHistory(HOME, dir, true)).toEqual([
    { role: "user", content: "what is this?", images: [{ mime: "image/png", data: "aGk=" }] },
  ]);
  expect(threadHistory(HOME, dir, false)).toEqual([
    { role: "user", content: "what is this?\n\n[attached: receipt.png (image/png)]" },
  ]);
});

test("a non-image attachment is named rather than sent, vision or not", () => {
  appendThreadEvent(
    {
      id: "e1",
      threadId: HOME,
      ts: 1,
      agentId: "phone",
      kind: "message",
      // No text at all: the note is then the whole message, so the turn is not empty.
      data: { role: "user", text: "", attachment: { name: "q3.pdf", mime: "application/pdf", data: "aGk=" } },
    },
    dir,
  );

  for (const vision of [true, false]) {
    expect(threadHistory(HOME, dir, vision)).toEqual([
      { role: "user", content: "[attached: q3.pdf (application/pdf)]" },
    ]);
  }
});

test("mixed attachments send every image and name every remaining file", () => {
  appendThreadEvent(
    {
      id: "e1",
      threadId: HOME,
      ts: 1,
      agentId: "phone",
      kind: "message",
      data: {
        role: "user",
        text: "compare these",
        attachments: [
          { name: "a.png", mime: "image/png", data: "MQ==" },
          { name: "b.jpg", mime: "image/jpeg", data: "Mg==" },
          { name: "notes.pdf", mime: "application/pdf", data: "Mw==" },
        ],
      },
    },
    dir,
  );

  expect(threadHistory(HOME, dir, true)).toEqual([
    {
      role: "user",
      content: "compare these\n\n[attached: notes.pdf (application/pdf)]",
      images: [
        { mime: "image/png", data: "MQ==" },
        { mime: "image/jpeg", data: "Mg==" },
      ],
    },
  ]);
});

test("read state is the runtime's, and only moves forward unless it is reset", () => {
  const thread = createThread("Groceries", dir);
  // Absent rather than 0 on both counts, so a thread nobody has been answered in is not
  // permanently unread.
  expect(threadSummaries(dir)[0]!.lastReadAt).toBeUndefined();
  expect(threadSummaries(dir)[0]!.lastAgentAt).toBeUndefined();

  // The agent speaking is what makes a thread unread. The user's own message is not.
  appendThreadEvent(message("e1", "buy milk", thread.id), dir);
  expect(threadSummaries(dir)[0]!.lastAgentAt).toBeUndefined();
  appendThreadEvent(agentMessage("e2", "Added.", thread.id), dir);
  expect(threadSummaries(dir)[0]!.lastAgentAt).toBe(2);

  expect(markThreadRead(thread.id, 100, dir)).toBe(true);
  expect(threadSummaries(dir)[0]!.lastReadAt).toBe(100);

  // A second device reporting an older read, or the same one twice, moves nothing and says so —
  // so neither is worth a fresh list to every device.
  expect(markThreadRead(thread.id, 50, dir)).toBe(false);
  expect(markThreadRead(thread.id, 100, dir)).toBe(false);
  expect(threadSummaries(dir)[0]!.lastReadAt).toBe(100);
  expect(markThreadRead(thread.id, 200, dir)).toBe(true);
  expect(markThreadRead("nope", 200, dir)).toBe(false);

  // "Mark as unread" is the one thing allowed to walk the mark backwards.
  expect(markThreadRead(thread.id, 1, dir, true)).toBe(true);
  expect(threadSummaries(dir)[0]!.lastReadAt).toBe(1);
});

import { recoverNativeTurns, setNativeTurn } from "./threads.js";

test("restart reconciles a committed final reply and retires dead native prompts", () => {
  createThread("Work", dir, "cc", { agent: "claude-code" });
  setNativeTurn("cc", { id: "final", state: "running" }, dir);
  const base = { threadId: "cc", ts: 1, agentId: "main" };
  appendThreadEvent({ ...base, id: "card", kind: "approval_card", data: { actionId: "a", nativeAgent: "claude-code", actionClass: "Bash", target: "pwd" } }, dir);
  appendThreadEvent({ ...base, id: "final", kind: "message", data: { role: "agent", text: "done", done: true } }, dir);
  recoverNativeTurns(dir);
  expect(listThreads(dir)[0]?.nativeTurn).toBeUndefined();
  expect(readThreadEvents("cc", dir).at(-1)).toMatchObject({ kind: "approval_answer", data: { actionId: "a", answer: "no" } });
  recoverNativeTurns(dir);
  expect(readThreadEvents("cc", dir)).toHaveLength(3);
});

 test("tool previews never split a surrogate pair before Swift decodes them", () => {
  const dir = mkdtempSync(join(tmpdir(), "yorozu-unicode-"));
  const event = { id: "unicode", threadId: "t", ts: 1, agentId: "main", kind: "tool_result" as const,
    data: { callId: "unicode", ok: true, output: "a" + "🙂".repeat(3000) } };
  const preview = stashToolResult(event, dir);
  expect(preview.data.output.isWellFormed()).toBe(true);
  expect(preview.data.output.length).toBe(4095);
  expect(fullToolResult("t", "unicode", dir)).toEqual(event);
});


test.each(['{broken', '{}', '[null]', '[{"id":"t"}]'])("a damaged index (%s) cannot be replaced by a new thread", (contents) => {
  const file = join(dir, "threads.json");
  writeFileSync(file, contents);
  expect(() => createThread("New", dir)).toThrow(/thread index/i);
  expect(readFileSync(file, "utf8")).toBe(contents);
});

test("an unreadable index is not a first run", () => {
  const file = join(dir, "threads.json");
  mkdirSync(file);
  expect(() => listThreads(dir)).toThrow(/thread index/i);
  rmSync(file, { recursive: true });
  expect(listThreads(dir)).toEqual([]);
});

test("sync seeks through long history without reparsing it for each page", () => {
  mkdirSync(threadsDir(dir));
  const events = Array.from({ length: 5000 }, (_, n) => message(`e${n}`, "日本語🙂".repeat(40)));
  writeFileSync(join(threadsDir(dir), "home.jsonl"), events.map((event) => JSON.stringify(event)).join("\n") + "\n");
  let page = eventsAfter(HOME, undefined, dir);
  const parse = vi.spyOn(JSON, "parse");
  try {
    let count = page.length;
    while (page.length) {
      page = eventsAfter(HOME, page.at(-1)!.syncCursor, dir);
      count += page.length;
    }
    expect(count).toBe(events.length);
    expect(parse.mock.calls.length).toBe(events.length - SYNC_LIMIT);
  } finally { parse.mockRestore(); }
});

test("sync handles repeated ids, large UTF-8 lines, broken tails and changed files", () => {
  mkdirSync(threadsDir(dir));
  const file = join(threadsDir(dir), "home.jsonl");
  const large = message("e2", "日本語🙂".repeat(20000));
  const initial = [message("e1", "first"), large, message("e1", "last"), message("e3", "tail")];
  writeFileSync(file, initial.map((event) => JSON.stringify(event)).join("\n") + "\n{broken");
  expect(eventsAfter(HOME, undefined, dir)).toMatchObject(initial);
  expect(eventsAfter(HOME, "e1", dir)).toMatchObject([initial[3]]);
  appendFileSync(file, "\n" + JSON.stringify(message("e4", "appended")) + "\n");
  expect(eventsAfter(HOME, "e3", dir).map((event) => event.id)).toEqual(["e4"]);
  const replacement = JSON.stringify(message("e5", "rewritten")) + "\n";
  writeFileSync(file, replacement);
  expect(eventsAfter(HOME, "e4", dir).map((event) => event.id)).toEqual(["e5"]);
  writeFileSync(file + ".new", replacement.replace('e5', 'e6'));
  renameSync(file + ".new", file);
  expect(eventsAfter(HOME, "e5", dir).map((event) => event.id)).toEqual(["e6"]);
  writeFileSync(file, replacement.replace('e5', 'e7'));
  expect(eventsAfter(HOME, "e6", dir).map((event) => event.id)).toEqual(["e7"]);
  rmSync(file);
  expect(eventsAfter(HOME, "e7", dir)).toEqual([]);
});
