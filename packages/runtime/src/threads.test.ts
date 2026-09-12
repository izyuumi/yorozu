import { mkdtempSync, readFileSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { YorozuEvent } from "@yorozu/shared";
import { beforeEach, expect, test } from "vitest";
import {
  appendThreadEvent,
  archiveThread,
  createThread,
  eventsAfter,
  HISTORY_LIMIT,
  listThreads,
  pinThread,
  readThreadEvents,
  renameThread,
  threadHistory,
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
    { id: "e3", threadId: HOME, ts: 3, agentId: "main", kind: "sync_request", data: { lastSeen: {} } },
    dir,
  );
  appendThreadEvent(message("e4", "other", "t2"), dir);

  expect(readThreadEvents(HOME, dir).map((e) => e.id)).toEqual(["e1", "e2"]);
  expect(readThreadEvents("t2", dir).map((e) => e.id)).toEqual(["e4"]);
  expect(readThreadEvents("never-written", dir)).toEqual([]);
  expect(readFileSync(join(threadsDir(dir), "home.jsonl"), "utf8").split("\n")).toHaveLength(3);
});

test("a delta is everything after the last-seen id, the tail when it is unknown", () => {
  for (const id of ["e1", "e2", "e3"]) appendThreadEvent(message(id, id), dir);

  expect(eventsAfter(HOME, "e1", dir).map((e) => e.id)).toEqual(["e2", "e3"]);
  expect(eventsAfter(HOME, "e3", dir)).toEqual([]);
  expect(eventsAfter(HOME, undefined, dir).map((e) => e.id)).toEqual(["e1", "e2", "e3"]);
  expect(eventsAfter(HOME, "gone", dir).map((e) => e.id)).toEqual(["e1", "e2", "e3"]);
  expect(eventsAfter("t2", "e1", dir)).toEqual([]);
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
