import { expect, test, vi } from "vitest";
import { CHILD_ENV_KEYS, CHILD_ENV_PREFIXES, childEnv, claudeCodeRunner, type QueryFn } from "./native.js";

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
  // The CLI gets an explicit allowlisted env, not Yorozu's own.
  expect(calls[0]!.env).toEqual(childEnv());
  expect(closes).toHaveLength(1);

  // The next prompt resumes that session, in the same folder, and is told the new one.
  const second = await runner.run({ threadId: "cc", cwd: "/tmp/proj", text: "now the lint", sessionId: "s-1", signal: new AbortController().signal });
  expect(calls[1]).toMatchObject({ resume: "s-1", cwd: "/tmp/proj" });
  expect(second.sessionId).toBe("s-1");
});

test.each([{ cwd: "" }, { cwd: "   " }, {}])("a turn without a folder is refused before the SDK is asked anything (%o)", async (folder) => {
  const { query, calls } = fakeQuery([init("s-none"), result("s-none", "ran anyway")]);
  // The type requires cwd; the cast stands in for a JS caller or a thread record from before it did.
  const turn = { threadId: "cc", text: "hi", signal: new AbortController().signal, ...folder } as never;
  await expect(claudeCodeRunner(query).run(turn)).rejects.toThrow("needs a working directory");
  expect(query).not.toHaveBeenCalled();
  expect(calls).toHaveLength(0);
});

test("streamed deltas redraw the whole reply so far", async () => {
  const delta = (text: string) => ({ type: "stream_event", session_id: "s-2", event: { type: "content_block_delta", delta: { type: "text_delta", text } } });
  const { query } = fakeQuery([init("s-2"), { type: "stream_event", session_id: "s-2", event: { type: "message_start" } }, delta("hel"), delta("lo"), result("s-2", "hello")]);
  const updates: string[] = [];
  const done = await claudeCodeRunner(query).run({ threadId: "cc", cwd: "/tmp/proj", text: "hi", signal: new AbortController().signal, onUpdate: (text) => updates.push(text) });
  expect(updates).toEqual(["hel", "hello"]);
  expect(done.text).toBe("hello");
});

test("thoughts, tool calls and results become the trace the work row draws; subagents stay inside", async () => {
  const { query } = fakeQuery([
    init("s-5"),
    { type: "assistant", session_id: "s-5", uuid: "u1", parent_tool_use_id: null, message: { content: [
      { type: "thinking", thinking: "look at the tests first" },
      { type: "tool_use", id: "toolu_1", name: "Bash", input: { command: "pnpm test" } },
    ] } },
    { type: "user", session_id: "s-5", parent_tool_use_id: null, message: { role: "user", content: [
      { type: "tool_result", tool_use_id: "toolu_1", content: [{ type: "text", text: "3 passed" }, { type: "image" }] },
    ] } },
    // A subagent's own call and result: part of the Task, not the row.
    { type: "assistant", session_id: "s-5", uuid: "u2", parent_tool_use_id: "toolu_task", message: { content: [
      { type: "tool_use", id: "toolu_inner", name: "Read", input: {} },
    ] } },
    { type: "user", session_id: "s-5", parent_tool_use_id: "toolu_task", message: { role: "user", content: [
      { type: "tool_result", tool_use_id: "toolu_inner", content: "secret" },
    ] } },
    { type: "assistant", session_id: "s-5", uuid: "u3", parent_tool_use_id: null, message: { content: [
      { type: "tool_use", id: "toolu_2", name: "Edit", input: { file_path: "a.ts", old_string: "x" } },
    ] } },
    { type: "user", session_id: "s-5", parent_tool_use_id: null, message: { role: "user", content: [
      { type: "tool_result", tool_use_id: "toolu_2", is_error: true, content: "old_string not found" },
    ] } },
    said("s-5", "Fixed."),
    result("s-5", "Fixed."),
  ]);
  const activity: [string, unknown][] = [];
  const done = await claudeCodeRunner(query).run({ threadId: "cc", cwd: "/tmp/proj", text: "fix", signal: new AbortController().signal, onActivity: (id, payload) => activity.push([id, payload]) });
  expect(done.text).toBe("Fixed.");
  expect(activity).toEqual([
    ["u1:thinking", { kind: "thought", data: { text: "look at the tests first" } }],
    ["call:toolu_1", { kind: "tool_call", data: { callId: "toolu_1", name: "Bash", args: { command: "pnpm test" } } }],
    ["result:toolu_1", { kind: "tool_result", data: { callId: "toolu_1", ok: true, output: "3 passed\n[image]" } }],
    ["call:toolu_2", { kind: "tool_call", data: { callId: "toolu_2", name: "Edit", args: { file_path: "a.ts", old_string: "x" } } }],
    ["result:toolu_2", { kind: "tool_result", data: { callId: "toolu_2", ok: false, output: "old_string not found" } }],
  ]);
  expect(JSON.stringify(activity)).not.toContain("secret");
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
  const done = await claudeCodeRunner(query).run({ threadId: "cc", cwd: "/tmp/proj", text: "long job", signal: turn.signal });
  expect(done).toEqual({ text: "", sessionId: "s-3" });
  expect(calls).toHaveLength(1);
});

test("a failure the agent reports is the reply; a transport failure is thrown", async () => {
  const failed = fakeQuery([init("s-4"), { type: "result", subtype: "error_max_turns", session_id: "s-4", is_error: true }]);
  const reported = await claudeCodeRunner(failed.query).run({ threadId: "cc", cwd: "/tmp/proj", text: "x", signal: new AbortController().signal });
  expect(reported).toEqual({ text: "Claude Code stopped: max turns.", sessionId: "s-4", failed: true });

  const broken = fakeQuery(() => {
    throw new Error("claude is not installed");
  });
  await expect(claudeCodeRunner(broken.query).run({ threadId: "cc", cwd: "/tmp/proj", text: "x", signal: new AbortController().signal }))
    .rejects.toThrow("claude is not installed");
});

// Exercise the SDK callback through the same card desk used by the sidecar.
import { NativeCards } from "./native-cards.js";
import type { YorozuEvent } from "@yorozu/shared";
import type { Options, Query } from "@anthropic-ai/claude-agent-sdk";

test.each(["yes", "no"] as const)("native SDK permission %s holds the turn and returns to the SDK", async (answer) => {
  const events: YorozuEvent[] = [];
  const cards = new NativeCards((event) => events.push(event));
  let decision: unknown;
  const query: QueryFn = ({ options }) => Object.assign((async function* () {
    yield init("permission-session");
    decision = await options!.canUseTool!("Bash", { command: "pwd" }, { signal: new AbortController().signal, toolUseID: "tool" });
    yield result("permission-session", "finished");
  })(), { close() {} }) as Query;
  const finished = vi.fn();
  const running = claudeCodeRunner(query).run({ threadId: "cc", cwd: "/tmp/proj", text: "run", signal: new AbortController().signal,
    approve: (tool, input, signal) => cards.approve("cc", "claude-code", tool, input, signal),
  }).then(finished);
  await vi.waitFor(() => expect(events).toHaveLength(1));
  expect(finished).not.toHaveBeenCalled();
  const card = events[0]!;
  if (card.kind !== "approval_card") throw new Error("missing card");
  expect(card.data).toMatchObject({ nativeAgent: "claude-code", actionClass: "Bash" });
  expect(card.data.suggestedRule).toBeUndefined();
  expect(cards.quickApprovable(card.data.actionId)).toBe(true);
  const reply: YorozuEvent = { ...card, kind: "approval_answer", data: { actionId: card.data.actionId, answer, source: "notification" } };
  expect(cards.answer({ ...reply, threadId: "other" })).toBe(false);
  expect(cards.answer(reply)).toBe(true);
  await running;
  expect(decision).toMatchObject({ behavior: answer === "yes" ? "allow" : "deny" });
  expect(finished).toHaveBeenCalledWith({ text: "finished", sessionId: "permission-session" });
  expect(cards.answer(reply)).toBe(false);
});

test.each(["Option A", "My own answer"])("SDK question accepts %s", async (answer) => {
  let options!: Options;
  const fake = fakeQuery([]);
  const query: QueryFn = (params) => { options = params.options!; return fake.query(params); };
  const ask = vi.fn().mockResolvedValue(answer);
  await claudeCodeRunner(query).run({ threadId: "cc", cwd: "/tmp/proj", text: "ask", signal: new AbortController().signal, ask });
  const input = { questions: [{ question: "Which?", options: [{ label: "Option A" }, { label: "Option B" }] }] };
  expect(await options.canUseTool!("AskUserQuestion", input, { signal: new AbortController().signal, toolUseID: "q" }))
    .toEqual({ behavior: "allow", updatedInput: { ...input, answers: { "Which?": answer } } });
  expect(ask).toHaveBeenCalledWith("Which?", ["Option A", "Option B"], expect.any(AbortSignal));
});

test.each(["approval", "question"])("abort pending %s clears only that request", async (kind) => {
  const events: YorozuEvent[] = [];
  const cards = new NativeCards((event) => events.push(event));
  const abort = new AbortController();
  const other = new AbortController();
  const request = kind === "approval" ? cards.approve("cc", "claude-code", "Bash", {}, abort.signal) : cards.ask("cc", "Which?", ["A"], abort.signal);
  const separate = cards.approve("other", "claude-code", "Edit", {}, other.signal);
  abort.abort();
  expect(await request).toBe(kind === "approval" ? false : undefined);
  const card = events[1]!;
  if (card.kind !== "approval_card") throw new Error("missing card");
  expect(cards.quickApprovable(card.data.actionId)).toBe(true);
  other.abort();
  expect(await separate).toBe(false);
});

test("bypass toggles on and off in one resumed session, while questions still need answers", async () => {
  const { query, calls } = fakeQuery([result("s-bypass", "ok")]);
  const runner = claudeCodeRunner(query);
  const approve = vi.fn().mockResolvedValue(false);
  for (const bypass of [false, true, false]) {
    await runner.run({ threadId: "cc", cwd: "/tmp/proj", sessionId: "s-bypass", text: "work", bypass, approve, signal: new AbortController().signal });
    const options = calls.at(-1)! as unknown as Options;
    expect(options.permissionMode).toBe(bypass ? "bypassPermissions" : "default");
    const decision = await options.canUseTool!("Bash", {}, { signal: new AbortController().signal, toolUseID: "t" });
    expect(decision?.behavior).toBe(bypass ? "allow" : "deny");
  }
  expect(approve).toHaveBeenCalledTimes(2);
});

test("Claude publishes SDK models and passes selected model/effort on each resumed turn", async () => {
  const { query, calls } = fakeQuery([result("s-model", "ok")]);
  const models = vi.fn().mockResolvedValue([
    { value: "opus", resolvedModel: "claude-opus-5-5", displayName: "Opus", description: "", supportedEffortLevels: ["low", "high", "max"] },
    { value: "fable", resolvedModel: "claude-fable-5-1", displayName: "Fable", description: "" },
    { value: "haiku[1m]", resolvedModel: "claude-haiku-4-5-20251001", displayName: "Haiku (1M context)", description: "" },
    { value: "default", resolvedModel: "claude-opus-5-5", displayName: "Default (recommended)", description: "" },
  ]);
  const catalogQuery: QueryFn = (params) => Object.assign(query(params), { supportedModels: models });
  const runner = claudeCodeRunner(catalogQuery);
  expect(await runner.models!()).toEqual([
    { id: "opus", label: "Opus 5.5", providerLabel: "Claude Code", efforts: ["low", "high", "max"] },
    { id: "fable", label: "Fable 5.1", providerLabel: "Claude Code", efforts: [] },
    { id: "haiku[1m]", label: "Haiku 4.5 (1M context)", providerLabel: "Claude Code", efforts: [] },
    { id: "default", label: "Default (recommended)", providerLabel: "Claude Code", efforts: [] },
  ]);
  expect(calls[0]).toMatchObject({ tools: [], env: childEnv() });
  for (const effort of ["low", "max"] as const) {
    await runner.run({ threadId: "cc", cwd: "/tmp/proj", text: "go", sessionId: "s-model", model: "opus", effort, signal: new AbortController().signal });
    expect(calls.at(-1)).toMatchObject({ model: "opus", effort, resume: "s-model" });
  }
});

test.each([true, false])("Claude questions use PreToolUse even when permission callback is skipped (bypass=%s)", async (bypass) => {
  const { query, calls } = fakeQuery([]);
  const ask = vi.fn().mockResolvedValueOnce("A").mockResolvedValueOnce("custom");
  await claudeCodeRunner(query).run({ threadId: "cc", cwd: "/tmp/proj", text: "go", bypass, ask, signal: new AbortController().signal });
  const hooks = calls[0]!.hooks as { PreToolUse: { hooks: Function[] }[] };
  const input = { questions: [{ question: "Pick", options: [{ label: "A" }] }, { question: "Name", options: [] }] };
  const answer = await hooks.PreToolUse[0]!.hooks[0]!({ hook_event_name: "PreToolUse", tool_input: input }, "id", { signal: new AbortController().signal });
  expect(answer.hookSpecificOutput).toEqual({ hookEventName: "PreToolUse", permissionDecision: "allow", updatedInput: { ...input, answers: { Pick: "A", Name: "custom" } } });
  const stopped = new AbortController(); stopped.abort();
  expect((await hooks.PreToolUse[0]!.hooks[0]!({ hook_event_name: "PreToolUse", tool_input: input }, "id", { signal: stopped.signal })).hookSpecificOutput.permissionDecision).toBe("deny");
  expect(ask).toHaveBeenCalledTimes(2);
});

test("childEnv keeps the shell basics and the agents' own variables", () => {
  const source = {
    PATH: "/usr/bin:/bin", HOME: "/Users/me", LANG: "en_US.UTF-8", LC_ALL: "C", XDG_CONFIG_HOME: "/Users/me/.config",
    CLAUDE_CODE_X: "1", ANTHROPIC_API_KEY: "sk-ant", CODEX_HOME: "/Users/me/.codex", OPENAI_API_KEY: "sk-oa",
  };
  expect(childEnv(source)).toEqual(source);
  expect(CHILD_ENV_KEYS).toEqual(expect.arrayContaining(["PATH", "HOME", "TMPDIR", "LANG", "USER", "SHELL", "TERM"]));
  expect(CHILD_ENV_PREFIXES).toEqual(expect.arrayContaining(["LC_", "XDG_", "CLAUDE_", "ANTHROPIC_", "CODEX_", "OPENAI_"]));
});

test("childEnv drops Yorozu's own variables and unrelated provider keys", () => {
  const env = childEnv({
    PATH: "/bin", YOROZU_STATE_DIR: "/state", YOROZU_RELAY_URL: "wss://relay", GOOGLE_API_KEY: "g",
    AWS_SECRET_ACCESS_KEY: "aws", GITHUB_TOKEN: "ghp", SOME_API_KEY: "k",
  });
  expect(env).toEqual({ PATH: "/bin" });
});

test("childEnv skips undefined values, lets extra win, and reads process.env by default", () => {
  expect(childEnv({ PATH: undefined, HOME: "/h", TERM: "xterm" }, { TERM: "dumb", CLAUDE_AGENT_SDK_CLIENT_APP: "yorozu" }))
    .toEqual({ HOME: "/h", TERM: "dumb", CLAUDE_AGENT_SDK_CLIENT_APP: "yorozu" });
  vi.stubEnv("YOROZU_TEST_SECRET", "hidden");
  vi.stubEnv("PATH", "/stubbed/bin");
  try {
    const env = childEnv();
    expect(env.PATH).toBe("/stubbed/bin");
    expect(Object.keys(env).some((key) => key.startsWith("YOROZU_"))).toBe(false);
    expect(Object.values(env).every((value) => typeof value === "string")).toBe(true);
  } finally { vi.unstubAllEnvs(); }
});
