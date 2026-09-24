import { EventEmitter } from "node:events";
import { PassThrough } from "node:stream";
import { expect, test, vi } from "vitest";
import { codexNativeRunner, connectCodex, type CodexHandlers, type ConnectCodex } from "./codex-native.js";
import { childEnv, type NativeTurn } from "./native.js";

// No test may start a real `codex`: the one test that reaches spawn gets this stand-in child.
const { spawnMock } = vi.hoisted(() => ({ spawnMock: vi.fn() }));
vi.mock("node:child_process", () => ({ spawn: spawnMock }));

function fakeCodex(work: (handlers: CodexHandlers) => Promise<void> = async (h) => {
  h.notify("item/completed", { threadId: "native", item: { type: "agentMessage", id: "reply", text: "Done" } });
  h.notify("turn/completed", { threadId: "native", turn: { id: "turn-1", status: "completed" } });
}) {
  const calls: [string, Record<string, unknown>][] = [];
  const responses: unknown[] = [];
  const close = vi.fn();
  const connect: ConnectCodex = (handlers) => ({
    async request(method, params) {
      calls.push([method, params]);
      if (method === "thread/start" || method === "thread/resume") return { thread: { id: "native" } };
      if (method === "turn/start") {
        handlers.notify("turn/started", { threadId: "native", turn: { id: "turn-1" } });
        void work(handlers).catch(handlers.ended);
        return { turn: { id: "turn-1" } };
      }
      if (method === "turn/interrupt") handlers.notify("turn/completed", { threadId: "native", turn: { id: "turn-1", status: "interrupted" } });
      if (method === "model/list") return { data: [{ model: "model-a", displayName: "Model A", supportedReasoningEfforts: [{ reasoningEffort: "high" }, { reasoningEffort: "ultra" }] }] };
      return {};
    },
    notify(method, params) { calls.push([method, params]); },
    close() { close(); handlers.ended(new Error("closed")); },
  });
  return { connect, calls, responses, close };
}
const turn = (more: Partial<NativeTurn> = {}): NativeTurn => ({ threadId: "cx", text: "work", cwd: "/tmp/project", signal: new AbortController().signal, ...more });

test("Codex starts/resumes native threads with cwd, models, effort and independent bypass", async () => {
  const fake = fakeCodex();
  const runner = codexNativeRunner(fake.connect);
  const onSession = vi.fn();
  const first = await runner.run(turn({ onSession, model: "model-a", effort: "ultra" }));
  expect(first).toEqual({ text: "Done", sessionId: "native" });
  expect(onSession).toHaveBeenCalledWith("native");
  expect(fake.calls).toContainEqual(["thread/start", { cwd: "/tmp/project", model: "model-a", approvalPolicy: "on-request", approvalsReviewer: "user", sandbox: "workspace-write" }]);
  expect(fake.calls.find(([m]) => m === "turn/start")?.[1]).toMatchObject({ threadId: "native", model: "model-a", effort: "ultra" });
  for (const bypass of [true, false]) {
    await runner.run(turn({ sessionId: first.sessionId, bypass }));
    expect(fake.calls.filter(([m]) => m === "thread/resume").at(-1)?.[1]).toMatchObject({ threadId: "native", cwd: "/tmp/project", approvalPolicy: bypass ? "never" : "on-request", sandbox: bypass ? "danger-full-access" : "workspace-write" });
  }
  expect(fake.close).toHaveBeenCalledTimes(3);
  expect(await runner.models!()).toEqual([{ id: "model-a", label: "Model A", providerLabel: "Codex", efforts: ["high", "ultra"] }]);
});

test.each([{ cwd: "" }, { cwd: "   " }, { cwd: undefined }])("Codex refuses a turn without a folder before the app server is spawned (%o)", async (folder) => {
  const spawned = vi.fn();
  const fake = fakeCodex();
  const connect: ConnectCodex = (handlers) => { spawned(); return fake.connect(handlers); };
  // The type requires cwd; the cast stands in for a JS caller or a thread record from before it did.
  await expect(codexNativeRunner(connect).run(turn(folder as never))).rejects.toThrow("needs a working directory");
  expect(spawned).not.toHaveBeenCalled();
  expect(fake.calls).toEqual([]);
});

test.each([true, false])("Codex permission %s and multiple-choice/free-text answers return to native server", async (allow) => {
  const decisions: unknown[] = [];
  const fake = fakeCodex(async (h) => {
    for (const kind of ["commandExecution", "fileChange", "permissions"]) decisions.push(await h.request(`item/${kind}/requestApproval`, { threadId: "native", command: "pwd", permissions: { network: { enabled: true } } }));
    decisions.push(await h.request("item/tool/requestUserInput", { questions: [{ id: "q1", question: "Which?", options: [{ label: "A" }] }, { id: "q2", question: "Name?", options: null }] }));
    h.notify("turn/completed", { threadId: "native", turn: { status: "completed" } });
  });
  const approve = vi.fn().mockResolvedValue(allow);
  const ask = vi.fn().mockResolvedValueOnce("A").mockResolvedValueOnce("Free text");
  await codexNativeRunner(fake.connect).run(turn({ approve, ask }));
  expect(decisions).toEqual([{ decision: allow ? "accept" : "decline" }, { decision: allow ? "accept" : "decline" }, { permissions: allow ? { network: { enabled: true } } : {}, scope: "turn" }, { answers: { q1: { answers: ["A"] }, q2: { answers: ["Free text"] } } }]);
  expect(approve.mock.calls[0]?.[1]).not.toHaveProperty("threadId");
});

test("Codex maps native thought, tool and reply streams to existing trace events", async () => {
  const fake = fakeCodex(async (h) => {
    const item = { type: "commandExecution", id: "cmd", command: "cat log", status: "inProgress" };
    h.notify("item/completed", { threadId: "native", item: { type: "reasoning", id: "think", summary: ["Inspect"], content: [] } });
    h.notify("item/started", { threadId: "native", item });
    h.notify("item/completed", { threadId: "native", item: { ...item, status: "completed", aggregatedOutput: "X".repeat(5000) } });
    h.notify("item/agentMessage/delta", { threadId: "native", itemId: "reply", delta: "Do" });
    h.notify("item/agentMessage/delta", { threadId: "native", itemId: "reply", delta: "ne" });
    h.notify("item/completed", { threadId: "native", item: { type: "agentMessage", id: "reply", text: "Done" } });
    h.notify("turn/completed", { threadId: "native", turn: { status: "completed" } });
  });
  const onActivity = vi.fn();
  const onUpdate = vi.fn();
  expect(await codexNativeRunner(fake.connect).run(turn({ onActivity, onUpdate }))).toEqual({ text: "Done", sessionId: "native" });
  expect(onActivity.mock.calls.map((c) => c[1].kind)).toEqual(["thought", "tool_call", "tool_result"]);
  expect(onActivity.mock.calls[2]?.[1].data.output).toHaveLength(5000);
  expect(onActivity.mock.calls[2]?.[1].data.callId).toBe("turn-1:cmd");
  expect(onUpdate.mock.calls).toEqual([["Do"], ["Done"]]);
});

test.each(["approval", "question"])("Stop interrupts Codex while %s is pending, keeps native session and closes process", async (kind) => {
  const abort = new AbortController();
  let requested = false;
  const fake = fakeCodex(async (h) => {
    requested = true;
    await h.request(kind === "approval" ? "item/commandExecution/requestApproval" : "item/tool/requestUserInput", kind === "approval" ? { command: "pwd" } : { questions: [{ id: "q", question: "Which?" }] });
  });
  const wait = (signal: AbortSignal) => new Promise<undefined>((resolve) => signal.addEventListener("abort", () => resolve(undefined), { once: true }));
  const runner = codexNativeRunner(fake.connect);
  const running = runner.run(turn({ signal: abort.signal, approve: async (_t, _i, s) => { await wait(s); return false; }, ask: (_q, _o, s) => wait(s) }));
  await vi.waitFor(() => expect(requested).toBe(true));
  abort.abort();
  expect(await running).toEqual({ text: "", sessionId: "native" });
  expect(fake.calls).toContainEqual(["turn/interrupt", { threadId: "native", turnId: "turn-1" }]);
  expect(fake.close).toHaveBeenCalledOnce();
});

test("Codex failures propagate and unknown server requests fail closed", async () => {
  const fake = fakeCodex(async (h) => {
    await expect(h.request("new/permission", {})).rejects.toThrow("Unsupported");
    h.notify("turn/completed", { threadId: "native", turn: { status: "failed", error: { message: "Failed safely" } } });
  });
  await expect(codexNativeRunner(fake.connect).run(turn())).rejects.toThrow("Failed safely");
  expect(fake.close).toHaveBeenCalledOnce();
});

test("Codex Auto effort catalog uses the actual default even when it is not first", async () => {
  const connect: ConnectCodex = () => ({
    request: async (method) => method === "model/list" ? { data: [
      { model: "first", supportedReasoningEfforts: [{ reasoningEffort: "low" }] },
      { model: "default", isDefault: true, supportedReasoningEfforts: [{ reasoningEffort: "high" }] },
    ] } : {}, notify() {}, close() {},
  });
  expect((await codexNativeRunner(connect).models!()).map((m) => [m.id, m.efforts])).toEqual([["default", ["high"]], ["first", ["low"]]]);
});

test("the Codex app server is spawned with the allowlisted env, never Yorozu's own", () => {
  vi.stubEnv("YOROZU_STATE_DIR", "/private/state");
  vi.stubEnv("GITHUB_TOKEN", "ghp_secret");
  const child = Object.assign(new EventEmitter(), { stdout: new PassThrough(), stdin: new PassThrough(), kill: vi.fn() });
  spawnMock.mockReturnValueOnce(child);
  try {
    const ended = vi.fn();
    connectCodex({ notify() {}, request: async () => ({}), ended }).close();
    expect(spawnMock).toHaveBeenCalledOnce();
    const [command, args, options] = spawnMock.mock.calls[0] as [string, string[], { env: Record<string, string>; stdio: unknown }];
    expect([command, args, options.stdio]).toEqual(["codex", ["app-server"], ["pipe", "pipe", "ignore"]]);
    expect(options.env).toEqual(childEnv());
    expect(Object.keys(options.env).some((key) => key.startsWith("YOROZU_"))).toBe(false);
    expect(options.env).not.toHaveProperty("GITHUB_TOKEN");
    expect(child.kill).toHaveBeenCalledOnce();
    expect(ended).toHaveBeenCalledOnce();
  } finally { vi.unstubAllEnvs(); }
});
