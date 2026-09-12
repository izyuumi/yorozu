import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { YorozuEvent } from "@yorozu/shared";
import { beforeEach, expect, test } from "vitest";
import {
  appendThreadEvent,
  archiveThread,
  createThread,
  eventsAfter,
  HOME_THREAD,
  HISTORY_LIMIT,
  listThreads,
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

const message = (id: string, text: string, threadId = HOME_THREAD): YorozuEvent => ({
  id,
  threadId,
  ts: Number(id.slice(1)),
  agentId: "main",
  kind: "message",
  data: { role: "user", text },
});

test("Home exists from the first read and cannot be archived", () => {
  expect(listThreads(dir)).toEqual([
    { id: HOME_THREAD, title: "Home", createdAt: expect.any(String), archived: false },
  ]);
  expect(archiveThread(HOME_THREAD, dir)).toBe(false);
  // Even if the index is edited by hand to claim otherwise.
  const file = join(dir, "threads.json");
  const stored = JSON.parse(readFileSync(file, "utf8")) as { archived: boolean }[];
  stored[0]!.archived = true;
  writeFileSync(file, JSON.stringify(stored));
  expect(listThreads(dir)[0]!.archived).toBe(false);
});

test("creating and archiving threads survives a reload", () => {
  const created = createThread("  Groceries  ", dir);
  expect(created.title).toBe("Groceries");
  expect(listThreads(dir).map((t) => t.id)).toEqual([HOME_THREAD, created.id]);

  expect(archiveThread(created.id, dir)).toBe(true);
  expect(archiveThread(created.id, dir)).toBe(false);
  expect(archiveThread("nope", dir)).toBe(false);
  expect(threadSummaries(dir)).toEqual([
    { id: HOME_THREAD, title: "Home", archived: false, pinned: true },
    { id: created.id, title: "Groceries", archived: true, pinned: false },
  ]);
});

test("a thread is created unnamed and renamed in place", () => {
  const created = createThread(undefined, dir);
  expect(created.title).toBe("");

  expect(renameThread(created.id, "  Weekend plans  ", dir)).toBe(true);
  expect(renameThread(created.id, "Weekend plans", dir)).toBe(false);
  // Nothing to rename, and nothing to rename it to, are both refusals rather than writes.
  expect(renameThread(created.id, "   ", dir)).toBe(false);
  expect(renameThread("nope", "Anything", dir)).toBe(false);
  expect(listThreads(dir)[1]!.title).toBe("Weekend plans");
});

test("events append per thread and only history kinds are logged", () => {
  appendThreadEvent(message("e1", "hi"), dir);
  appendThreadEvent(
    { id: "e2", threadId: HOME_THREAD, ts: 2, agentId: "main", kind: "thought", data: { text: "hm" } },
    dir,
  );
  appendThreadEvent(
    { id: "e3", threadId: HOME_THREAD, ts: 3, agentId: "main", kind: "sync_request", data: { lastSeen: {} } },
    dir,
  );
  appendThreadEvent(message("e4", "other", "t2"), dir);

  expect(readThreadEvents(HOME_THREAD, dir).map((e) => e.id)).toEqual(["e1", "e2"]);
  expect(readThreadEvents("t2", dir).map((e) => e.id)).toEqual(["e4"]);
  expect(readThreadEvents("never-written", dir)).toEqual([]);
  expect(readFileSync(join(threadsDir(dir), "home.jsonl"), "utf8").split("\n")).toHaveLength(3);
});

test("a delta is everything after the last-seen id, the tail when it is unknown", () => {
  for (const id of ["e1", "e2", "e3"]) appendThreadEvent(message(id, id), dir);

  expect(eventsAfter(HOME_THREAD, "e1", dir).map((e) => e.id)).toEqual(["e2", "e3"]);
  expect(eventsAfter(HOME_THREAD, "e3", dir)).toEqual([]);
  expect(eventsAfter(HOME_THREAD, undefined, dir).map((e) => e.id)).toEqual(["e1", "e2", "e3"]);
  expect(eventsAfter(HOME_THREAD, "gone", dir).map((e) => e.id)).toEqual(["e1", "e2", "e3"]);
  expect(eventsAfter("t2", "e1", dir)).toEqual([]);
});

test("history is the thread's messages, compacted to the last HISTORY_LIMIT", () => {
  for (let n = 1; n <= HISTORY_LIMIT + 5; n++) appendThreadEvent(message(`e${n}`, `m${n}`), dir);
  appendThreadEvent(
    { id: "reply", threadId: HOME_THREAD, ts: 99, agentId: "main", kind: "message", data: { role: "agent", text: "ok" } },
    dir,
  );

  const history = threadHistory(HOME_THREAD, dir);
  expect(history).toHaveLength(HISTORY_LIMIT);
  // 45 user messages plus the reply, compacted to the last 40.
  expect(history[0]).toEqual({ role: "user", content: "m7" });
  expect(history.at(-1)).toEqual({ role: "assistant", content: "ok" });
  expect(threadHistory("t2", dir)).toEqual([]);
});
