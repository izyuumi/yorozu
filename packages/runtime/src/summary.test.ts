import { existsSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { YorozuEvent } from "@yorozu/shared";
import { beforeEach, expect, test } from "vitest";
import type { Message, Provider } from "./provider.js";
import { contextFor, readSummary, summaryFile, updateSummary } from "./summary.js";
import { appendThreadEvent, HISTORY_LIMIT } from "./threads.js";

let dir: string;

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "yorozu-summary-"));
});

const THREAD = "t1";

/** `n` messages in the thread, alternating user and agent, numbered so they can be told apart. */
function say(count: number, from = 0): void {
  for (let i = from; i < from + count; i++) {
    const event: YorozuEvent = {
      id: `e${i}`,
      threadId: THREAD,
      ts: i,
      agentId: "main",
      kind: "message",
      data: { role: i % 2 === 0 ? "user" : "agent", text: `message ${i}` },
    };
    appendThreadEvent(event, dir);
  }
}

/** A provider that answers every completion with `text`, and records what it was asked. */
function summariser(text: string): Provider & { prompts: Message[][] } {
  const prompts: Message[][] = [];
  return {
    prompts,
    auth: async () => ({ ok: true }),
    async *stream(messages) {
      prompts.push(messages);
      yield { type: "text", text };
      yield { type: "done", reason: "stop" };
    },
  };
}

const failing = (): Provider => ({
  auth: async () => ({ ok: false, reason: "429" }),
  // eslint-disable-next-line require-yield
  async *stream() {
    throw new Error("/chat/completions 429: rate limit exceeded");
  },
});

test("a thread that still fits in the window is not summarised at all", async () => {
  say(HISTORY_LIMIT);
  const provider = summariser("nothing to say");

  expect(await updateSummary(THREAD, provider, dir)).toBe(false);
  expect(provider.prompts).toHaveLength(0);
  expect(existsSync(summaryFile(THREAD, dir))).toBe(false);
  // And with no summary, the context is the window and nothing in front of it.
  expect(contextFor(THREAD, dir)).toHaveLength(HISTORY_LIMIT);
});

test("the first eviction writes a summary of exactly what fell out of the window", async () => {
  say(HISTORY_LIMIT + 3);
  const provider = summariser("They talked about the first three things.");

  expect(await updateSummary(THREAD, provider, dir)).toBe(true);
  expect(readSummary(THREAD, dir)).toEqual({
    through: 3,
    text: "They talked about the first three things.",
  });

  // Only the evicted messages are summarised: what is still in the window is still in context.
  const [{ content }] = provider.prompts[0]!.slice(-1);
  expect(content).toContain("message 0");
  expect(content).toContain("message 2");
  expect(content).not.toContain("message 3");
  // One completion, and no tools: this is the cheap call, not a turn.
  expect(provider.prompts).toHaveLength(1);
});

test("a second eviction folds the new messages into the summary already on disk", async () => {
  say(HISTORY_LIMIT + 3);
  await updateSummary(THREAD, summariser("First three."), dir);

  say(2, HISTORY_LIMIT + 3);
  const provider = summariser("First three, then two more.");
  expect(await updateSummary(THREAD, provider, dir)).toBe(true);

  const [{ content }] = provider.prompts[0]!.slice(-1);
  // The old summary goes in, and only the messages it does not already account for.
  expect(content).toContain("First three.");
  expect(content).toContain("message 3");
  expect(content).toContain("message 4");
  expect(content).not.toContain("message 2");
  expect(readSummary(THREAD, dir)).toEqual({ through: 5, text: "First three, then two more." });

  // Nothing has moved since, so the next turn spends nothing.
  const idle = summariser("unused");
  expect(await updateSummary(THREAD, idle, dir)).toBe(false);
  expect(idle.prompts).toHaveLength(0);
});

test("the summary leads the turn's context, ahead of the window", async () => {
  say(HISTORY_LIMIT + 3);
  await updateSummary(THREAD, summariser("They talked about the first three things."), dir);

  const context = contextFor(THREAD, dir);
  expect(context[0]).toEqual({
    role: "system",
    content: "Earlier in this thread: They talked about the first three things.",
  });
  // The window is unchanged behind it: the newest message is still the last thing in context.
  expect(context).toHaveLength(HISTORY_LIMIT + 1);
  expect(context.at(-1)?.content).toBe(`message ${HISTORY_LIMIT + 2}`);
});

test("a provider that fails leaves the summary that was there", async () => {
  say(HISTORY_LIMIT + 3);
  await updateSummary(THREAD, summariser("First three."), dir);
  const before = readFileSync(summaryFile(THREAD, dir), "utf8");

  say(2, HISTORY_LIMIT + 3);
  await expect(updateSummary(THREAD, failing(), dir)).rejects.toThrow("429");

  expect(readFileSync(summaryFile(THREAD, dir), "utf8")).toBe(before);
  // So the thread still has its old summary in front of the window rather than nothing.
  expect(contextFor(THREAD, dir)[0]?.content).toContain("First three.");

  // And the messages the failed call would have folded in are still owed, so the next turn
  // tries again rather than losing them.
  const provider = summariser("First three, then two more.");
  expect(await updateSummary(THREAD, provider, dir)).toBe(true);
  expect(readSummary(THREAD, dir).through).toBe(5);
});

test("deleting the file resets the summary, and the log rebuilds it", async () => {
  say(HISTORY_LIMIT + 3);
  await updateSummary(THREAD, summariser("First three."), dir);

  writeFileSync(summaryFile(THREAD, dir), "");
  expect(readSummary(THREAD, dir)).toEqual({ through: 0, text: "" });

  // Rebuilt from the whole of what has fallen out of the window, not just what is new.
  const provider = summariser("All three, again.");
  expect(await updateSummary(THREAD, provider, dir)).toBe(true);
  const [{ content }] = provider.prompts[0]!.slice(-1);
  expect(content).toContain("message 0");
  expect(readSummary(THREAD, dir).through).toBe(3);
});
