/** Real host registries/history/kernel leases, with synthetic harness transport only. */
import { afterEach, expect, test, vi } from "vitest";
import { mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import type { YorozuEvent } from "@yorozu/shared";
import { PersonAgentHost, type PersonAgentPlatform } from "./person-agent-host.js";
import { HarnessProcess } from "./harness-process.js";
import type { HarnessEvent, HarnessReady } from "./harness-contract.js";
import type { PersonAgentRuntimeFactory } from "./person-agent-runtime.js";
import { appendThreadEvent, createThread, listThreads, readThreadEvents, setNativeTurn, setThreadSession, threadHome } from "./threads.js";
import { closeSyncHost } from "./rust-sync.js";

const cleanup: Array<() => Promise<void>> = [];
afterEach(async () => { for (const fn of cleanup.splice(0)) await fn(); vi.restoreAllMocks(); });
const capabilities = { backgroundTasks: true, targetedSteer: true, taskStop: true, approvals: true, reconnect: true, attachments: false };
const event = (kind: YorozuEvent["kind"], id: string, threadId: string, data: Record<string, any>): YorozuEvent => ({ kind, id, threadId, data, agentId: "client", ts: 1000 }) as YorozuEvent;
function fixture(mode: "complete" | "hold" | "unknown" = "complete", configurePlatform?: (p: PersonAgentPlatform) => void) {
  const dir = realpathSync(mkdtempSync(join(tmpdir(), "yorozu-person-host-"))), resource = join(dir, "selected"); mkdirSync(resource);
  const traces: Array<{ method: string; params: Record<string, any>; process: HarnessProcess }> = [], builds: any[] = [];
  let sequence = 0;
  const emit = (p: HarnessProcess, current: Record<string, any>, state: "completed" | "unknown" = "completed") => {
    const native: HarnessEvent = { protocolVersion: 1, conversationId: current.conversationId, eventId: `fixture-${++sequence}`,
      runId: current.runId, attemptId: current.attemptId, kind: "turn.terminal", data: { state, text: "Synthetic reply", ...(state === "completed" ? { cessation: "provider-terminal" } : {}) } };
    for (const fn of p.listeners) fn(native);
  };
  const held: Array<() => void> = [];
  vi.spyOn(HarnessProcess.prototype, "start").mockImplementation(function (this: HarnessProcess) {
    traces.push({ process: this, method: "start", params: {} });
    return Promise.resolve({ protocolVersion: 1, pluginId: this.configuration.pluginId, upstreamVersion: this.configuration.upstreamVersion, capabilities } as HarnessReady);
  });
  vi.spyOn(HarnessProcess.prototype, "request").mockImplementation(function (this: HarnessProcess, method, params) {
    traces.push({ process: this, method, params });
    if (method === "session.open") return Promise.resolve({ sessionId: `fixture-session-${params.conversationId}` });
    if (method === "turn.submit") {
      if (mode === "hold") held.push(() => emit(this, params));
      else queueMicrotask(() => emit(this, params, mode === "unknown" ? "unknown" : "completed"));
      return Promise.resolve({ status: "accepted" });
    }
    return Promise.resolve({ status: "unsupported" });
  });
  const factory: PersonAgentRuntimeFactory = (agent, scope, execution) => {
    builds.push({ agent, scope, execution });
    return { configuration: { pluginId: agent.pluginId, upstreamVersion: "fixture-1", command: process.execPath, args: [], initialize: { provider: "owned-provider" } },
      runtime: { command: process.execPath, args: [], runtimeDir: execution.scratchRoot, readPaths: [], brokerPorts: [] } };
  };
  const platform: PersonAgentPlatform = { resourceRoots: [{ path: resource, access: "read" }], createFactory: () => factory,
    initialAgent: { id: "alice", name: "Alice", role: "Secretary", pluginId: "hermes", model: "host-standard", accountBindingId: "owned-account",
      allowedTools: ["file"], directories: [{ path: resource, access: "read" }] } };
  configurePlatform?.(platform);
  const host = new PersonAgentHost(dir, platform), publish = vi.fn();
  host.bind({ emit: e => appendThreadEvent(e, dir), changed: publish });
  cleanup.push(async () => { for (const done of held.splice(0)) done(); await host.close(); closeSyncHost(dir); rmSync(dir, { recursive: true, force: true }); });
  const create = (id: string, identity = `create-${id}`, person = "alice", title?: string) => host.create(event("thread_create", identity, id, { personAgentId: person, ...(title !== undefined ? { title } : {}) }));
  const run = (id: string, messageId: string, text = "Request", extra: Record<string, any> = {}) => {
    appendThreadEvent(event("message", messageId, id, { role: "user", text }), dir);
    setNativeTurn(id, { id: `native-${messageId}`, userEventId: messageId, state: "running" }, dir);
    return host.runner.run({ threadId: id, cwd: "caller-untrusted-cwd", text, signal: new AbortController().signal, ...extra });
  };
  const control = (id: string, data: Record<string, any>) => host.control(event("person_agent_control", id, "yorozu-secretary-v1", data));
  const controlData = (action: string, data: Record<string, any> = {}) => ({ version: 1, expectedRevision: host.registry().revision, action, ...data });
  return { dir, resource, host, platform, builds, traces, held, publish, create, run, control, controlData };
}

test("registry/default/Remember controls use typed durable readback and never enter existing conversation history", async () => {
  const f = fixture(); createThread("Legacy", f.dir, "legacy", { agent: "codex", cwd: f.resource });
  appendThreadEvent(event("message", "old-message", "legacy", { role: "user", text: "Synthetic legacy history" }), f.dir);
  const before = readThreadEvents("legacy", f.dir), rows = listThreads(f.dir);
  await f.control("select-default", f.controlData("default", { agentId: "alice" }));
  expect(f.host.registry()).toMatchObject({ defaultAgentId: "alice", revision: 2, lastControlResult: { operationId: "select-default", status: "applied", revision: 2 } });
  await f.control("remember-all", f.controlData("remember", { expectedJournalRevision: 0, preference: { allAgents: true, text: "Remember without granting files or tools" } }));
  expect(f.host.registry()).toMatchObject({ revision: 2, journalRevision: 1, lastControlResult: { status: "applied" } });
  expect(f.host.registry().agents[0].allowedTools).toEqual(["file"]);
  expect(readThreadEvents("legacy", f.dir)).toEqual(before); expect(listThreads(f.dir)).toEqual(rows); expect(f.traces).toEqual([]);
});

test("malformed settings are durably refused with the same operation receipt on replay", async () => {
  const f = fixture(), malformed = f.controlData("update", { agentId: "alice", patch: { allowedTools: ["arbitrary-tool"] } });
  await f.control("malformed", malformed);
  expect(f.host.registry().lastControlResult).toMatchObject({ operationId: "malformed", status: "rejected" });
  await f.control("malformed", malformed); expect(f.host.registry().revision).toBe(1);
  expect(readFileSync(join(f.host.controls.root, "operations.json"), "utf8")).toContain('"operationId":"malformed"');
});

test("chat creation binds identity durably and remains independent of broker/auth availability", async () => {
  const noAuth = vi.fn(() => { throw new Error("No official subscription broker is selected"); });
  const f = fixture("complete", p => { p.createFactory = () => noAuth; });
  await f.create("new-chat", "create-once");
  expect(f.host.owns("new-chat")).toBe(true); expect(f.host.workspace("new-chat")).toBe(f.host.registry().agents[0].workspace);
  expect(noAuth).not.toHaveBeenCalled();
  expect(listThreads(f.dir).find(t => t.id === "new-chat")).toMatchObject({ agent: "harness", creation: { eventId: "create-once" } });
  const result = await f.run("new-chat", "unavailable-input");
  expect(result).toMatchObject({ failed: true, cessation: "not-submitted" }); expect(noAuth).toHaveBeenCalledTimes(1);
  await f.create("new-chat", "create-once"); expect(noAuth).toHaveBeenCalledTimes(1);
});

test("creation replay preserves immutable person/thread currency and never creates a second thread", async () => {
  const f = fixture(); await f.create("chat-a", "same-id", "alice", "Named chat"); await f.create("chat-a", "same-id", "alice", "Named chat");
  await expect(f.create("chat-b", "same-id", "alice", "Named chat")).rejects.toThrow();
  await expect(f.create("chat-a", "new-id", "alice", "Named chat")).rejects.toThrow();
  await expect(f.create("chat-a", "same-id", "alice", "Changed title")).rejects.toThrow();
  await f.control("create-bob", f.controlData("create", { agent: { id: "bob", name: "Bob", role: "Helper", pluginId: "hermes", allowedTools: [] } }));
  await expect(f.create("chat-a", "same-id", "bob", "Named chat")).rejects.toThrow();
  expect(listThreads(f.dir).map(t => t.id)).toEqual(["chat-a"]); expect(f.host.summary("chat-a")).toMatchObject({ personAgentId: "alice", personAgentName: "Alice", bypass: false });
  expect(f.builds).toEqual([]); expect(f.traces).toEqual([]);
});

test("caller cwd/account/provider/model/tool grants and malformed identities cannot create or widen a chat", async () => {
  const f = fixture();
  for (const patch of [{ cwd: f.resource }, { workspace: f.resource }, { accountBindingId: "borrowed-account" }, { model: "arbitrary-fast" },
    { provider: "other-account" }, { allowedTools: ["terminal"] }, { directories: [{ path: f.dir, access: "write" }] }, { bypass: true }])
    await expect(f.host.create(event("thread_create", "forged", "forged-chat", { personAgentId: "alice", ...patch }))).rejects.toThrow();
  for (const id of ["", "x".repeat(129), "bad\nidentity", { forged: true }])
    await expect(f.host.create(event("thread_create", id as any, "bad-id-chat", { personAgentId: "alice" }))).rejects.toThrow();
  await expect(f.host.create(event("thread_create", "traversal", "../escape", { personAgentId: "alice" }))).rejects.toThrow();
  for (const id of [123, ["array-chat"], { toString: () => "object-chat" }])
    await expect(f.host.create(event("thread_create", "forged-thread", id as any, { personAgentId: "alice" }))).rejects.toThrow();
  await expect(f.create("unknown-chat", "unknown-create", "unknown")).rejects.toThrow();
  expect(listThreads(f.dir)).toEqual([]); expect(f.builds).toEqual([]);
});

test("published binding supplies workspace/provider/model/session identity; message and creation replay submit once", async () => {
  const f = fixture(); await f.create("chat", "creation");
  const result = await f.run("chat", "request", "Bound request", { model: "caller-fast", effort: "high", bypass: true, sessionId: "borrowed-native-session", accountBindingId: "caller-account" });
  expect(result).toMatchObject({ text: "Synthetic reply", cessation: "provider-terminal" });
  expect(f.builds).toHaveLength(1); expect(f.builds[0].agent).toMatchObject({ id: "alice", model: "host-standard", accountBindingId: "owned-account" });
  const process = f.traces.find(t => t.method === "start")!.process;
  expect(process.configuration.initialize).toMatchObject({ agentId: "alice", workspace: f.host.workspace("chat"), model: "host-standard", provider: "owned-provider" });
  expect(f.traces.find(t => t.method === "session.open")!.params).not.toHaveProperty("sessionId", "borrowed-native-session");
  await f.create("chat", "creation"); await f.run("chat", "request", "Bound request", { bypass: true, cwd: f.dir });
  expect(f.builds).toHaveLength(1); expect(f.traces.filter(t => t.method === "turn.submit")).toHaveLength(1);
  expect(f.host.summary("chat")).toMatchObject({ personAgentId: "alice", bypass: false, canResume: false, canRewind: false });
});

test("default selection does not adopt existing legacy main history or native session", async () => {
  const f = fixture(); createThread("Existing secretary", f.dir, "yorozu-secretary-v1", { agent: "codex", cwd: f.resource });
  setThreadSession("yorozu-secretary-v1", "synthetic-native-session", f.dir);
  appendThreadEvent(event("message", "legacy-user", "yorozu-secretary-v1", { role: "user", text: "Owned fixture legacy conversation" }), f.dir);
  const row = listThreads(f.dir).find(t => t.id === "yorozu-secretary-v1"), history = readThreadEvents("yorozu-secretary-v1", f.dir);
  await f.control("default", f.controlData("default", { agentId: "alice" }));
  expect(f.host.owns("yorozu-secretary-v1")).toBe(false); expect(f.host.workspace("yorozu-secretary-v1")).toBeUndefined();
  expect(listThreads(f.dir).find(t => t.id === "yorozu-secretary-v1")).toEqual(row);
  expect(threadHome("yorozu-secretary-v1", f.dir).sessionId).toBe("synthetic-native-session");
  expect(readThreadEvents("yorozu-secretary-v1", f.dir)).toEqual(history); expect(f.builds).toEqual([]);
});

test("busy execution holds host settings, then CAS/readback applies only a new explicit operation", async () => {
  const f = fixture("hold"); await f.create("active"); const running = f.run("active", "active-input");
  await vi.waitFor(() => expect(f.held).toHaveLength(1));
  const patch = f.controlData("update", { agentId: "alice", patch: { pluginId: "openclaw", allowedTools: [] } });
  await f.control("busy-update", patch); expect(f.host.registry().lastControlResult?.status).toBe("rejected");
  await f.control("busy-remember", f.controlData("remember", { expectedJournalRevision: 0, preference: { allAgents: true, text: "Busy memory" } }));
  expect(f.host.registry().journalRevision).toBe(0); expect(f.host.registry().agents[0].pluginId).toBe("hermes");
  f.held.shift()!(); await running;
  await f.control("busy-update", patch); expect(f.host.registry().agents[0].pluginId).toBe("hermes");
  await f.control("idle-update", patch); expect(f.host.registry()).toMatchObject({ revision: 2, lastControlResult: { operationId: "idle-update", status: "applied", revision: 2 } });
  await f.control("stale-update", patch); expect(f.host.registry().lastControlResult).toMatchObject({ status: "rejected", reason: "Agent revision conflict" });
  expect(readThreadEvents("active", f.dir).filter(e => e.kind === "person_agent_control")).toEqual([]);
});

test("unknown execution cannot be escaped by default, preferences or plugin switch", async () => {
  const f = fixture("unknown"); await f.create("uncertain"); expect(await f.run("uncertain", "unknown-input")).toMatchObject({ unconfirmed: true });
  for (const [id, request] of [["default", f.controlData("default", { agentId: "alice" })],
    ["update", f.controlData("update", { agentId: "alice", patch: { pluginId: "openclaw" } })],
    ["remember", f.controlData("remember", { expectedJournalRevision: 0, preference: { allAgents: true, text: "Unknown memory" } })]] as const) {
    await f.control(id, request); expect(f.host.registry().lastControlResult?.status).toBe("rejected");
  }
  expect(f.host.registry()).toMatchObject({ revision: 1, journalRevision: 0 }); expect(f.traces.filter(t => t.method === "turn.submit")).toHaveLength(1);
});

test("post-invocation runner exception remains unconfirmed; preflight refusal alone proves not-submitted", async () => {
  const f = fixture(), run = vi.fn(async () => { throw new Error("Submitted then lost completion"); });
  const owner = vi.spyOn(f.host.runtime, "owner").mockResolvedValue({ workspace: f.host.registry().agents[0].workspace, runner: { run } } as any);
  const result = await f.host.runner.run({ threadId: "fixture", cwd: f.resource, text: "Request", signal: new AbortController().signal });
  expect(result.unconfirmed).toBe(true); expect(result.cessation).toBeUndefined();
  owner.mockRejectedValueOnce(new Error("Preflight refused"));
  expect(await f.host.runner.run({ threadId: "fixture", cwd: f.resource, text: "Request", signal: new AbortController().signal })).toMatchObject({ failed: true, cessation: "not-submitted" });
  expect(run).toHaveBeenCalledTimes(1);
});

test("in-flight runtime preparation fences controls before the first owner is published", async () => {
  let release!: () => void, started!: () => void;
  const active = new Promise<void>(resolve => { started = resolve; }), wait = new Promise<void>(resolve => { release = resolve; });
  const f = fixture("complete", p => { const make = p.createFactory; p.createFactory = store => { const factory = make(store); return async (...args) => { started(); await wait; return factory(...args); }; }; });
  await f.create("preparing"); const running = f.run("preparing", "prepare-input"); await active;
  try {
    await f.control("prepare-default", f.controlData("default", { agentId: "alice" }));
    expect(f.host.registry().lastControlResult?.status).toBe("rejected"); expect(f.host.registry().revision).toBe(1);
    await f.control("prepare-remember", f.controlData("remember", { expectedJournalRevision: 0, preference: { allAgents: true, text: "Prepare memory" } }));
    expect(f.host.registry().journalRevision).toBe(0);
  } finally { release(); await running; }
});

test("failed competing host ownership cannot provision or mutate the initial registry", async () => {
  const f = fixture("complete", p => { p.initialAgent = undefined; });
  expect(f.host.registry().revision).toBe(0);
  expect(() => new PersonAgentHost(f.dir, { ...f.platform, initialAgent: { id: "injected", name: "Injected", role: "Helper", pluginId: "hermes", allowedTools: [] } })).toThrow("already owned");
  expect(f.host.registry().revision).toBe(0); expect(f.host.registry().agents).toEqual([]);
});

test("busy Alice execution fences unrelated Bob configuration, team/default, and shared journal mutations", async () => {
  const f = fixture("hold");
  await f.control("create-bob", f.controlData("create", { agent: { id: "bob", name: "Bob", role: "Helper", pluginId: "hermes", allowedTools: [] } }));
  await f.create("alice-chat"); const running = f.run("alice-chat", "alice-running"); await vi.waitFor(() => expect(f.held).toHaveLength(1));
  const attempts = [f.controlData("update", { agentId: "bob", patch: { pluginId: "openclaw" } }),
    f.controlData("default", { agentId: "bob" }),
    f.controlData("create-team", { team: { id: "helpers", name: "Helpers", agentIds: ["alice", "bob"] } }),
    f.controlData("share-knowledge", { expectedJournalRevision: 0, knowledge: { fromAgentId: "alice", toAgentIds: ["bob"], text: "Selected snapshot" } })];
  for (const [index, request] of attempts.entries()) { await f.control(`busy-other-${index}`, request); expect(f.host.registry().lastControlResult?.status).toBe("rejected"); }
  expect(f.host.registry()).toMatchObject({ revision: 2, teams: [], journalRevision: 0 });
  expect(f.host.registry().agents[1].pluginId).toBe("hermes");
  f.held.shift()!(); await running;
});

test("restart preserves the immutable chat binding and exact creation receipt without starting an adapter", async () => {
  const f = fixture(); await f.create("persisted-chat", "persisted-create"); await f.host.close();
  const restarted = new PersonAgentHost(f.dir, f.platform);
  cleanup.unshift(() => restarted.close());
  expect(restarted.owns("persisted-chat")).toBe(true); expect(restarted.summary("persisted-chat")).toMatchObject({ personAgentId: "alice" });
  await restarted.create(event("thread_create", "persisted-create", "persisted-chat", { personAgentId: "alice" }));
  await expect(restarted.create(event("thread_create", "persisted-create", "other-chat", { personAgentId: "alice" }))).rejects.toThrow();
  expect(f.builds).toEqual([]); expect(f.traces).toEqual([]); expect(listThreads(f.dir).map(t => t.id)).toEqual(["persisted-chat"]);
});
