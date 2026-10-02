import { afterEach, expect, test, vi } from "vitest";
import { mkdtempSync, rmSync, readFileSync, writeFileSync, readdirSync, renameSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { execFileSync } from "node:child_process";
import { join } from "node:path";
import { syncHostRequest, syncHostResult, retainSyncHost } from "./rust-sync.js";
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

test("Claude reload exposes user skills and bundled skills without built-in commands", async () => {
  const { query, calls, closes } = fakeQuery([]);
  const reloadSkills = vi.fn().mockResolvedValue({ skills: [
    { name: "grill-me", description: "Ask hard questions", argumentHint: "<topic>" },
    { name: "plugin:shape", description: "Shape", argumentHint: "", builtin: false },
    { name: "code-review", description: "Bundled review", argumentHint: "", builtin: true },
    { name: "code-review", description: "Shadowed review", argumentHint: "" },
    { name: "clear", description: "Shadowed clear", argumentHint: "" },
    { name: "hidden", description: "Not invocable", argumentHint: "" },
  ] });
  const supportedCommands = vi.fn().mockResolvedValue([
    { name: "grill-me" }, { name: "plugin:shape" }, { name: "code-review", builtin: true },
    { name: "clear", builtin: true },
  ]);
  const catalogQuery: QueryFn = (params) => Object.assign(query(params), { reloadSkills, supportedCommands });
  expect(await claudeCodeRunner(catalogQuery).skills!()).toEqual([
    { name: "grill-me", description: "Ask hard questions", argumentHint: "<topic>" },
    { name: "plugin:shape", description: "Shape", argumentHint: "" },
    { name: "code-review", description: "Bundled review", argumentHint: "" },
  ]);
  expect(calls[0]).toMatchObject({ tools: [] });
  expect(closes).toHaveLength(1);
});

test("a turn runs in the thread's folder and hands back the session to resume", async () => {
  const { query, calls, closes } = fakeQuery([init("s-1"), said("s-1", "hello from claude"), result("s-1", "hello from claude")]);
  const runner = claudeCodeRunner(query);
  const updates: string[] = [];
  const first = await runner.run({
    threadId: "cc", cwd: "/tmp/proj", text: "fix the tests", signal: new AbortController().signal,
    effort: "high", onUpdate: (text) => updates.push(text),
  });
  expect(first).toEqual({ text: "hello from claude", sessionId: "s-1", completed: true, cessation: "provider-terminal" });
  expect(calls[0]).toMatchObject({ cwd: "/tmp/proj", effort: "high" });
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

test("Claude Code may read the folder its attachments are in, and no other outside cwd", async () => {
  const { query, calls } = fakeQuery([init("s-1"), result("s-1", "seen")]);
  const runner = claudeCodeRunner(query);
  const base = { threadId: "cc", cwd: "/tmp/proj", text: "look", signal: new AbortController().signal };
  await runner.run({ ...base, attachments: [
    { name: "a.png", mime: "image/png", path: "/state/threads/cc.attachments/m-0-a.png" },
    { name: "b.pdf", mime: "application/pdf", path: "/state/threads/cc.attachments/m-1-b.pdf" },
  ] });
  expect(calls[0]!.additionalDirectories).toEqual(["/state/threads/cc.attachments"]);
  await runner.run(base);
  expect(calls[1]).not.toHaveProperty("additionalDirectories");
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

test("stop returns streamed text and keeps the SDK session resumable", async () => {
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
            yield { type: "stream_event", session_id: "s-3", event: { type: "content_block_delta", delta: { type: "text_delta", text: "half a" } } };
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
  expect(done).toEqual({ text: "half a", sessionId: "s-3" });
  expect(calls).toHaveLength(1);
});

test("Claude Code reports a successful result after Stop as completed", async () => {
  const turn = new AbortController();
  const query: QueryFn = () => Object.assign((async function* () {
    yield init("s-race");
    turn.abort();
    yield result("s-race", "full answer");
  })(), { close() {} }) as ReturnType<QueryFn>;
  expect(await claudeCodeRunner(query).run({ threadId: "cc", cwd: "/tmp/proj", text: "work", signal: turn.signal }))
    .toEqual({ text: "full answer", sessionId: "s-race", completed: true, cessation: "provider-terminal" });
});

test("a failure the agent reports is the reply; a transport failure is thrown", async () => {
  const failed = fakeQuery([init("s-4"), { type: "result", subtype: "error_max_turns", session_id: "s-4", is_error: true }]);
  const reported = await claudeCodeRunner(failed.query).run({ threadId: "cc", cwd: "/tmp/proj", text: "x", signal: new AbortController().signal });
  expect(reported).toEqual({ text: "Claude Code stopped: max turns.", sessionId: "s-4", failed: true, cessation: "provider-terminal" });

  const broken = fakeQuery(() => {
    throw new Error("claude is not installed");
  });
  await expect(claudeCodeRunner(broken.query).run({ threadId: "cc", cwd: "/tmp/proj", text: "x", signal: new AbortController().signal }))
    .rejects.toThrow("claude is not installed");
});

// Exercise the SDK callback through the same card desk used by the sidecar.
import { recoverNativeTurns, readThreadEvents, threadSummaries } from "./threads.js";
import { NativeCards } from "./native-cards.js";
import type { YorozuEvent } from "@yorozu/shared";
import type { Options, Query } from "@anthropic-ai/claude-agent-sdk";

const permissionOwners: (() => void)[] = [];
afterEach(() => { for (const close of permissionOwners.splice(0)) close(); });
/** This SDK adapter test uses real issued Root ownership; the callback never invents admission. */
function permissionDesk(events: YorozuEvent[]) {
  const dir = mkdtempSync(join(tmpdir(), "yorozu-sdk-permissions-"));
  const release = retainSyncHost(dir);
  permissionOwners.push(() => { release(); rmSync(dir, { recursive: true, force: true }); });
  const rows = ["cc", "other"].map((id) => ({ id, title: id, createdAt: new Date().toISOString(), archived: false, agent: "claude-code" }));
  expect(syncHostRequest(dir, { op: "thread_index_replace", expectedHash: null, threads: rows }).stored).toBe(true);
  const scopes = new Map<string, { eventId: string; turnId: string; attemptId: string }>();
  for (const threadId of ["cc", "other"]) {
    const eventId = `origin-${threadId}`;
    const event: YorozuEvent = { id: eventId, threadId, ts: Date.now(), agentId: "phone", kind: "message", data: { role: "user", text: "work" } };
    expect(syncHostRequest(dir, { op: "accepted_accept", entry: { id: eventId, threadId, identity: "a".repeat(64), purpose: "conversation", event } }).status).toBe("accepted");
    expect(syncHostRequest(dir, { op: "history_append", operationId: eventId, event, thread: true, transcript: true }).stored).toBe(true);
    expect(syncHostRequest(dir, { op: "queue_enqueue", threadId, eventId }).stored).toBe(true);
    const claim = syncHostRequest(dir, { op: "run_attempt_claim", threadId, eventId });
    expect(claim.claimed).toBe(true);
    scopes.set(threadId, { eventId, turnId: `native:${eventId}:final`, attemptId: claim.attemptId as string });
  }
  return { dir, cards: new NativeCards((event) => {
    expect(syncHostRequest(dir, { op: "history_append", operationId: event.id, event, thread: true, transcript: true }).stored).toBe(true);
    events.push(event);
  }, { dir, publish: (event) => events.push(event) }), scopes };
}

test.each(["yes", "no"] as const)("native SDK permission %s holds the turn and returns to the SDK", async (answer) => {
  const events: YorozuEvent[] = [];
  const { cards, scopes } = permissionDesk(events);
  let decision: unknown;
  const query: QueryFn = ({ options }) => Object.assign((async function* () {
    yield init("permission-session");
    decision = await options!.canUseTool!("Bash", { command: "pwd" }, { signal: new AbortController().signal, toolUseID: "tool" });
    yield result("permission-session", "finished");
  })(), { close() {} }) as Query;
  const finished = vi.fn();
  const running = claudeCodeRunner(query).run({ threadId: "cc", cwd: "/tmp/proj", text: "run", signal: new AbortController().signal,
    approve: (tool, input, signal) => cards.approve("cc", "claude-code", tool, input, signal, scopes.get("cc")!, () => { throw new Error("Unexpected permission uncertainty"); }),
  }).then(finished);
  await vi.waitFor(() => expect(events).toHaveLength(1));
  expect(finished).not.toHaveBeenCalled();
  const card = events[0]!;
  if (card.kind !== "approval_card") throw new Error("missing card");
  expect(card.data).toMatchObject({ nativeAgent: "claude-code", actionClass: "Bash" });
  expect(card.data.suggestedRule).toBeUndefined();
  expect(cards.quickApprovable(card.data.actionId)).toBe(true);
  const reply: YorozuEvent = { ...card, id: "permission-answer", kind: "approval_answer", data: { actionId: card.data.actionId, answer, source: "notification" } };
  expect(cards.admitApproval({ ...reply, id: "foreign-answer", threadId: "other" })).toMatchObject({ data: { status: "no-longer-needed" } });
  expect(finished).not.toHaveBeenCalled();
  expect(cards.admitApproval(reply)).toMatchObject({ data: { status: "applied" } });
  await running;
  expect(decision).toMatchObject({ behavior: answer === "yes" ? "allow" : "deny" });
  expect(finished).toHaveBeenCalledWith({ text: "finished", sessionId: "permission-session", completed: true, cessation: "provider-terminal" });
  expect(cards.admitApproval(reply)).toMatchObject({ data: { status: "applied" } });
  expect(finished).toHaveBeenCalledOnce();
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
  const { cards, scopes } = permissionDesk(events);
  const abort = new AbortController();
  const other = new AbortController();
  const request = kind === "approval" ? cards.approve("cc", "claude-code", "Bash", {}, abort.signal, scopes.get("cc")!, () => { throw new Error("Unexpected permission uncertainty"); }) : cards.ask("cc", "claude-code", "Which?", ["A"], abort.signal, scopes.get("cc")!, () => { throw new Error("Unexpected question uncertainty"); });
  const separate = cards.approve("other", "claude-code", "Edit", {}, other.signal, scopes.get("other")!, () => { throw new Error("Unexpected permission uncertainty"); });
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
    { value: "fable", resolvedModel: "claude-fable-5-1", displayName: "Fable 5.1", description: "" },
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
  const answer = await hooks.PreToolUse[1]!.hooks[0]!({ hook_event_name: "PreToolUse", tool_input: input }, "id", { signal: new AbortController().signal });
  expect(answer.hookSpecificOutput).toEqual({ hookEventName: "PreToolUse", permissionDecision: "allow", updatedInput: { ...input, answers: { Pick: "A", Name: "custom" } } });
  const stopped = new AbortController(); stopped.abort();
  expect((await hooks.PreToolUse[1]!.hooks[0]!({ hook_event_name: "PreToolUse", tool_input: input }, "id", { signal: stopped.signal })).hookSpecificOutput.permissionDecision).toBe("deny");
  expect(ask).toHaveBeenCalledTimes(2);
});

test("Claude holds every tool through the unmatched drain hook", async () => {
  const { query, calls } = fakeQuery([]);
  const beforeTool = vi.fn().mockResolvedValue(false);
  await claudeCodeRunner(query).run({ threadId: "cc", cwd: "/tmp/proj", text: "go",
    signal: new AbortController().signal, beforeTool });
  const hooks = calls[0]!.hooks as { PreToolUse: { matcher?: string; timeout: number; hooks: Function[] }[] };
  expect(hooks.PreToolUse[0]!.matcher).toBeUndefined();
  expect(hooks.PreToolUse[0]!.timeout).toBeGreaterThan(300);
  expect((await hooks.PreToolUse[0]!.hooks[0]!({ hook_event_name: "PreToolUse", tool_name: "Bash" }, "id",
    { signal: new AbortController().signal })).hookSpecificOutput.permissionDecision).toBe("deny");
  expect(beforeTool).toHaveBeenCalledTimes(1);
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


test("Claude exit evidence belongs to this invocation and close alone is unconfirmed", async () => {
  const controllers=[new AbortController(),new AbortController()]; let call=0;
  const children: import("node:child_process").ChildProcess[]=[];
  const query: QueryFn = ({options}) => {
    const index=call++; const signal=options!.abortController!.signal;
    const child=index===0 ? options!.spawnClaudeCodeProcess!({command:process.execPath,args:["-e","process.stdin.resume()"],cwd:tmpdir(),env:options!.env as Record<string,string>}) : undefined;
    if(child) children.push(child as import("node:child_process").ChildProcess);
    const exit=child ? new Promise<void>((resolve)=>child.on("exit",()=>resolve())) : undefined;
    return Object.assign((async function*(){
      await new Promise<void>((resolve)=>signal.addEventListener("abort",()=>resolve(),{once:true}));
      child?.kill("SIGTERM"); if(exit) await exit;
      throw new Error("transport settled");
      yield init("unreachable");
    })(),{close(){child?.kill("SIGTERM");}}) as ReturnType<QueryFn>;
  };
  try {
    const runner=claudeCodeRunner(query); const first=runner.run({threadId:"one",cwd:tmpdir(),text:"work",signal:controllers[0]!.signal});
    const second=runner.run({threadId:"two",cwd:tmpdir(),text:"work",signal:controllers[1]!.signal});
    controllers[0]!.abort(); expect(await first).toMatchObject({text:"",cessation:"process-exited"});
    controllers[1]!.abort(); expect(await second).toEqual({text:""});
  } finally { for(const child of children) child.kill("SIGTERM"); }
});


test.each(["released", "source", "storage"])("native question never resumes a stale or unconfirmed worker: %s", async (guard) => {
  const events: YorozuEvent[] = [];
  const { dir, cards, scopes } = permissionDesk(events);
  const scope = scopes.get("cc")!;
  const uncertain = vi.fn();
  const pending = cards.ask("cc", "claude-code", "Which?", ["A"], new AbortController().signal, scope, uncertain);
  const card = events[0]!;
  if (card.kind !== "question_card") throw new Error("missing question");
  if (guard === "released") {
    expect(syncHostRequest(dir, { op: "run_attempt_release", threadId: "cc", ...scope }).released).toBe(true);
  } else if (guard === "source") {
    const path = join(dir, "threads.json");
    const rows = JSON.parse(readFileSync(path, "utf8"));
    rows.find((row: { id: string }) => row.id === "cc").agent = "codex";
    writeFileSync(path, JSON.stringify(rows));
  } else {
    const transcript = join(dir, "transcripts", readdirSync(join(dir, "transcripts"))[0]!);
    renameSync(transcript, `${transcript}.backup`);
    mkdirSync(transcript);
  }
  const answer: YorozuEvent = { id: "question-answer", threadId: "cc", ts: Date.now(), agentId: "phone", kind: "question_answer", data: { questionId: card.data.questionId, answer: "A" } };
  cards.answer(answer);
  expect(await pending).toBeUndefined();
  if (guard === "storage") expect(uncertain).toHaveBeenCalledOnce();
  const rows = readFileSync(join(dir, "threads", "cc.jsonl"), "utf8");
  expect(rows).not.toContain('"kind":"question_answer"');
});


test("boot retires a Root-scoped native question without fabricating an SDK answer", () => {
  const events: YorozuEvent[] = [];
  const { dir, cards, scopes } = permissionDesk(events);
  void cards.ask("cc", "claude-code", "Which?", ["A"], new AbortController().signal, scopes.get("cc")!, () => {});
  const card = events[0]!;
  if (card.kind !== "question_card") throw new Error("missing question");
  for (const [threadId, scope] of scopes) expect(syncHostRequest(dir, { op: "run_attempt_release", threadId, ...scope }).released).toBe(true);
  recoverNativeTurns(dir);
  recoverNativeTurns(dir);
  const history = readThreadEvents("cc", dir);
  expect(history.some((event) => event.kind === "question_answer")).toBe(false);
  expect(history.filter((event) => event.kind === "question_status")).toMatchObject([
    { data: { questionId: card.data.questionId, status: "no-longer-needed" } },
  ]);
  expect(threadSummaries(dir).find((thread) => thread.id === "cc")?.awaitingQuestion).toBeUndefined();
});

// A blocked settings open must not strand the live Root owner or lose its issued epoch.
test.skipIf(process.platform === "win32")("native startup policy rejects a FIFO and keeps its owner responsive", () => {
  const { dir, scopes } = permissionDesk([]);
  const scope = scopes.get("cc")!;
  const current = { op: "run_attempt_current", threadId: "cc", ...scope, mode: "effect" };
  expect(syncHostRequest(dir, current).current).toBe(true);
  execFileSync("mkfifo", [join(dir, "approval.json")]);
  const proof = syncHostResult(dir, { op: "run_attempt_policy", version: 1, threadId: "cc", ...scope, source: "claude-code" }, undefined, 1_000);
  expect(proof.error).toBe("run-attempt-unconfirmed");
  expect(proof.execute).not.toBe(true);
  expect(syncHostRequest(dir, current).current).toBe(true);
});
