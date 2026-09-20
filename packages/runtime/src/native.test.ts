import { expect, test, vi } from "vitest";
import { claudeCodeRunner, type QueryFn } from "./native.js";

/** A stand-in for the SDK's Query: the messages it will yield, plus close(). */
function fakeQuery(messages: unknown[] | ((options: Record<string, unknown>) => unknown[])) {
  const calls: Record<string, unknown>[] = [];
  const closes: number[] = [];
  const query = vi.fn((params: { prompt: string; options?: Record<string, unknown> }) => {
    const options = params.options ?? {};
    calls.push({ prompt: params.prompt, ...options });
    const list = typeof messages === "function" ? messages(options) : messages;
    const iterator = (async function* () {
      for (const message of list) {
        const abort = options.abortController as AbortController | undefined;
        if (abort?.signal.aborted) throw Object.assign(new Error("aborted"), { name: "AbortError" });
        yield message;
      }
    })();
    return Object.assign(iterator, { close: () => void closes.push(1), interrupt: vi.fn() });
  }) as unknown as QueryFn & { mock: { calls: unknown[] } };
  return { query, calls, closes };
}

const init = (session_id: string) => ({ type: "system", subtype: "init", session_id, cwd: "/tmp/proj" });
const said = (session_id: string, text: string) => ({
  type: "assistant", session_id, message: { content: [{ type: "text", text }] },
});
const result = (session_id: string, text: string) => ({ type: "result", subtype: "success", session_id, result: text });

test("a turn runs in the thread's folder and hands back the session to resume", async () => {
  const { query, calls, closes } = fakeQuery([init("s-1"), said("s-1", "hello from claude"), result("s-1", "hello from claude")]);
  const runner = claudeCodeRunner(query);
  const updates: string[] = [];
  const first = await runner.run({
    threadId: "cc", cwd: "/tmp/proj", text: "fix the tests", signal: new AbortController().signal,
    effort: "high", onUpdate: (text) => updates.push(text),
  });
  expect(first).toEqual({ text: "hello from claude", sessionId: "s-1" });
  expect(calls[0]).toMatchObject({ prompt: "fix the tests", cwd: "/tmp/proj", effort: "high" });
  expect(calls[0]).not.toHaveProperty("resume");
  // The agent keeps its own tools and settings: Yorozu names none of them.
  expect(calls[0]).not.toHaveProperty("tools");
  expect(calls[0]).not.toHaveProperty("mcpServers");
  expect(closes).toHaveLength(1);

  // The next prompt resumes that session, in the same folder, and is told the new one.
  const second = await runner.run({ threadId: "cc", cwd: "/tmp/proj", text: "now the lint", sessionId: "s-1", signal: new AbortController().signal });
  expect(calls[1]).toMatchObject({ resume: "s-1", cwd: "/tmp/proj" });
  expect(second.sessionId).toBe("s-1");
});

test("streamed deltas redraw the whole reply so far", async () => {
  const delta = (text: string) => ({ type: "stream_event", session_id: "s-2", event: { type: "content_block_delta", delta: { type: "text_delta", text } } });
  const { query } = fakeQuery([init("s-2"), { type: "stream_event", session_id: "s-2", event: { type: "message_start" } }, delta("hel"), delta("lo"), result("s-2", "hello")]);
  const updates: string[] = [];
  const done = await claudeCodeRunner(query).run({ threadId: "cc", text: "hi", signal: new AbortController().signal, onUpdate: (text) => updates.push(text) });
  expect(updates).toEqual(["hel", "hello"]);
  expect(done.text).toBe("hello");
});

test("stop aborts the SDK query, says nothing, and keeps the session resumable", async () => {
  const turn = new AbortController();
  const { query, calls } = fakeQuery((options) => {
    // The first message arrives; then the user presses stop before the reply does.
    const list = [init("s-3")];
    const abort = options.abortController as AbortController;
    return new Proxy(list, {
      get(target, prop, receiver) {
        if (prop === Symbol.iterator) {
          return function* () {
            yield target[0];
            turn.abort();
            expect(abort.signal.aborted).toBe(true);
            yield said("s-3", "half a");
          };
        }
        return Reflect.get(target, prop, receiver);
      },
    });
  });
  const done = await claudeCodeRunner(query).run({ threadId: "cc", text: "long job", signal: turn.signal });
  expect(done).toEqual({ text: "", sessionId: "s-3" });
  expect(calls).toHaveLength(1);
});

test("a failure the agent reports is the reply; a transport failure is thrown", async () => {
  const failed = fakeQuery([init("s-4"), { type: "result", subtype: "error_max_turns", session_id: "s-4", is_error: true }]);
  const reported = await claudeCodeRunner(failed.query).run({ threadId: "cc", text: "x", signal: new AbortController().signal });
  expect(reported).toEqual({ text: "Claude Code stopped: max turns.", sessionId: "s-4" });

  const broken = fakeQuery(() => {
    throw new Error("claude is not installed");
  });
  await expect(claudeCodeRunner(broken.query).run({ threadId: "cc", text: "x", signal: new AbortController().signal }))
    .rejects.toThrow("claude is not installed");
});
