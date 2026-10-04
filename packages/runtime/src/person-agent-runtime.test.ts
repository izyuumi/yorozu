/** Real durable host storage/kernel lease + exact isolation policy; synthetic harness/model only. */
import { afterEach, expect, test, vi } from "vitest";
import { mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { PersonAgentRuntime, type PersonAgentRuntimeFactory } from "./person-agent-runtime.js";
import { PersonAgentStore } from "./agent-store.js";
import { HarnessProcess } from "./harness-process.js";
import { SecretaryHarness } from "./harness-runner.js";
import { appendThreadEvent, createThread, listThreads, readThreadEvents, setNativeTurn, setThreadSession } from "./threads.js";
import { isolatedAgentLaunch } from "./agent-isolation.js";
import type { HarnessEvent, HarnessReady } from "./harness-contract.js";
import type { NativeTurn } from "./native.js";

const cleanup: Array<() => Promise<void>> = [];
afterEach(async () => { for (const fn of cleanup.splice(0)) await fn(); vi.restoreAllMocks(); });
const caps = { backgroundTasks: true, targetedSteer: true, taskStop: true, approvals: true, reconnect: true, attachments: false };
interface Trace { process: HarnessProcess; method: string; params: Record<string, any> }
function fixture(mode = "complete") {
  const dir = realpathSync(mkdtempSync(join(tmpdir(), "yorozu-people-runtime-"))), shared = join(dir, "shared");
  // All authorized roots belong to this synthetic fixture.
  mkdirSync(shared);
  const store = new PersonAgentStore(dir, { resourceRoots: [{ path: shared, access: "write" }, { path: join(dir, "person-agent-runtime-v1", "scratch", "bob"), access: "read" }] });
  let registry = store.create({ id: "alice", name: "Alice", role: "Secretary A", pluginId: "hermes", allowedTools: ["file", "delegation", "team", "memory"], directories: [{ path: shared, access: "write" }] }, 0);
  registry = store.create({ id: "bob", name: "Bob", role: "Specialist B", pluginId: "hermes", allowedTools: ["file", "delegation", "team", "memory"], directories: [{ path: shared, access: "read" }] }, registry.revision);
  registry = store.create({ id: "carol", name: "Carol", role: "Specialist C", pluginId: "hermes", allowedTools: ["file", "delegation", "team", "memory"], directories: [{ path: shared, access: "write" }] }, registry.revision);
  store.createTeam({ id: "office", name: "Office", agentIds: ["alice", "bob", "carol"] }, registry.revision);
  let journal = store.remember({ agentId: "bob", text: "BOB_PRIVATE_PREFERENCE" }, 0);
  journal = store.shareKnowledge({ fromAgentId: "alice", toAgentIds: ["bob", "carol"], text: "SELECTED_SHARED_KNOWLEDGE" }, journal.revision);
  const knowledgeId = journal.entries.at(-1)!.id;
  const traces: Trace[] = [], factories: any[] = []; let seq = 0;
  const emit = (p: HarnessProcess, current: Record<string, any>, kind: HarnessEvent["kind"], data: Record<string, unknown>, unscoped = false) => {
    const e: HarnessEvent = { protocolVersion: 1, conversationId: current.conversationId, eventId: `fixture-${++seq}`, kind, data,
      ...(!unscoped ? { runId: current.runId, attemptId: current.attemptId } : {}) };
    for (const fn of p.listeners) fn(e);
  };
  const currents = new WeakMap<HarnessProcess, Record<string, any>>();
  vi.spyOn(HarnessProcess.prototype, "start").mockImplementation(function (this: HarnessProcess) {
    traces.push({ process: this, method: "fixture.start", params: {} });
    return Promise.resolve({ protocolVersion: 1, pluginId: this.configuration.pluginId, upstreamVersion: this.configuration.upstreamVersion, capabilities: caps } as HarnessReady);
  });
  vi.spyOn(HarnessProcess.prototype, "request").mockImplementation(function (this: HarnessProcess, method, params) {
    traces.push({ process: this, method, params });
    if (method === "session.open") return Promise.resolve({ sessionId: `native-${params.conversationId}` });
    if (method === "turn.submit") {
      const p = params as Record<string, any>; currents.set(this, p);
      const transient = String(p.conversationId).startsWith("agent-handoff-");
      if (mode === "recursive" && (p.text === "delegate to Bob" || transient && this.configuration.initialize.agentId === "bob")) {
        const teammateId = this.configuration.initialize.agentId === "alice" ? "bob" : "carol";
        queueMicrotask(() => emit(this, p, "request.open", { requestId: `team-${p.runId}`, kind: "team-delegate", input: { teammateId,
          context: "EXPLICIT_HANDOFF_CONTEXT", expectedResult: "Produce the selected shared result", scope: { allowedTools: ["file", "delegation", "team", "memory"], directories: [{ path: shared, access: "write" }], sharedResourceIds: [knowledgeId] } } }));
      } else if (mode === "hold" || mode === "unknown" || mode === "cancel-handoff") {
        if (mode === "unknown") queueMicrotask(() => emit(this, p, "turn.terminal", { state: "unknown", text: "lost provider", cessation: "provider-terminal" }));
        if (mode === "cancel-handoff" && p.text === "delegate to Bob") queueMicrotask(() => emit(this, p, "request.open", { requestId: `team-${p.runId}`, kind: "team-delegate", input: {
          teammateId: "bob", context: "EXPLICIT_HANDOFF_CONTEXT", expectedResult: "Produce selected result", scope: { allowedTools: ["file"], directories: [{ path: shared, access: "read" }] } } }));
      } else queueMicrotask(() => emit(this, p, "turn.terminal", { state: "completed", text: `completed by ${this.configuration.initialize.agentId}`, cessation: "provider-terminal" }));
      return Promise.resolve({ status: "accepted" });
    }
    if (method === "request.answer") {
      const current = currents.get(this)!;
      if ((params.answer as any)?.result) queueMicrotask(() => emit(this, current, "turn.terminal", { state: "completed", text: (params.answer as any).result.text, cessation: "provider-terminal" }));
      return Promise.resolve({ status: "answered" });
    }
    if (method === "run.stop") {
      if (mode !== "cancel-handoff") queueMicrotask(() => emit(this, params, "turn.terminal", { state: "stopped", text: "stopped", cessation: "provider-terminal" }));
      return Promise.resolve({ status: "requested" });
    }
    return Promise.resolve({ status: "unsupported" });
  });
  const factory: PersonAgentRuntimeFactory = (agent, scope, execution) => {
    factories.push({ agent, scope, execution });
    return { configuration: { pluginId: agent.pluginId, upstreamVersion: "fixture-1", command: process.execPath, args: [], initialize: {} },
      runtime: { command: process.execPath, args: [], runtimeDir: execution.scratchRoot, readPaths: [], brokerPorts: [] } };
  };
  const manager = new PersonAgentRuntime(dir, store, factory); manager.bind({ emit: e => appendThreadEvent(e, dir), changed() {} });
  cleanup.push(async () => { await manager.close(); rmSync(dir, { recursive: true, force: true }); });
  const invoke = (h: SecretaryHarness, id: string, text: string, extra: Partial<NativeTurn> = {}) => {
    appendThreadEvent({ id, threadId: h.conversationId, agentId: "main", ts: Date.now(), kind: "message", data: { role: "user", text } }, dir);
    setNativeTurn(h.conversationId, { id: `native:${id}:final`, userEventId: id, state: "running" }, dir);
    return h.runner.run({ threadId: h.conversationId, cwd: h.workspace, text, signal: new AbortController().signal, ...extra });
  };
  return { dir, shared, store, manager, traces, factories, invoke, emit };
}

test("one agent shares a daemon across chats while sessions, bindings and host ledgers stay separate", async () => {
  const f = fixture(); const a = await f.manager.conversation("alice-chat-1", "alice", "First"), b = await f.manager.conversation("alice-chat-2", "alice", "Second");
  expect(a.process).toBe(b.process); expect(a.ledger.state.bindingId).not.toBe(b.ledger.state.bindingId);
  expect(await f.invoke(a, "input-1", "hello")).toMatchObject({ completed: true });
  expect(await f.invoke(b, "input-2", "hello again")).toMatchObject({ completed: true });
  const opens = f.traces.filter(t => t.method === "session.open");
  expect(opens.map(t => t.params.conversationId)).toEqual(["alice-chat-1", "alice-chat-2"]);
  expect(opens[1].params.context).not.toContain("hello"); expect(f.factories).toHaveLength(1);
  expect(a.process.configuration.command).toBe("/usr/bin/sandbox-exec");
  const policy = a.process.configuration.args[1];
  expect(policy).toContain("(deny default)"); expect(policy).toContain(join(f.dir, "threads")); expect(policy).toContain(f.store.paths("bob").workspace.split("/workspace")[0]);
  expect(() => new PersonAgentRuntime(f.dir, f.store, () => { throw new Error("unused"); })).toThrow("already owned");
  await expect(f.manager.conversation("alice-chat-1", "bob")).rejects.toThrow("immutable");
});

test("explicit secretary migration preserves legacy metadata and history without inheriting its folder authority", async () => {
  const f = fixture(), legacy = join(f.dir, "legacy-project"); mkdirSync(legacy);
  const id = "yorozu-secretary-v1";
  createThread("Continuous secretary", f.dir, id, { agent: "codex", cwd: legacy });
  setThreadSession(id, "legacy-native-session", f.dir);
  appendThreadEvent({ id: "legacy-preference", threadId: id, agentId: "main", ts: 1, kind: "message",
    data: { role: "user", text: "Keep responding in Japanese." } }, f.dir);
  f.manager.bindSecretary("alice"); const owner = await f.manager.conversation(id);
  expect(owner.workspace).toBe(f.store.paths("alice").workspace);
  expect(await f.invoke(owner, "new-person-input", "hello")).toMatchObject({ completed: true });
  expect(listThreads(f.dir).find(t => t.id === id)).toMatchObject({ agent: "codex", cwd: legacy, nativeSessionId: "legacy-native-session" });
  expect(f.traces.find(t => t.method === "session.open")?.params.context).toContain("Keep responding in Japanese.");
  expect((owner.process.configuration.initialize.scope as any).directories.some((g: any) => g.path === legacy)).toBe(false);
  await expect(f.manager.conversation(id, "bob")).rejects.toThrow("immutable");
});

test("legacy running or queued work refuses secretary migration before any agent daemon is prepared", () => {
  const f = fixture(), id = "yorozu-secretary-v1";
  createThread("Legacy secretary", f.dir, id, { agent: "codex", cwd: f.shared });
  setNativeTurn(id, { id: "native:old:final", userEventId: "old", state: "running" }, f.dir);
  expect(() => f.manager.bindSecretary("alice")).toThrow("confirmed idle");
  expect(f.factories).toHaveLength(0);
  setNativeTurn(id, undefined, f.dir);
  writeFileSync(join(f.dir, "native-turn-queue.json"), JSON.stringify([{ threadId: id, eventId: "old" }]));
  expect(() => f.manager.bindSecretary("alice")).toThrow("queued work");
  expect(f.manager.bindingForThread(id)).toBeUndefined();
});

test("confirmed idle switch creates a new binding and retains the original conversation history", async () => {
  const f = fixture(); const a = await f.manager.conversation("settings-chat", "alice");
  await f.invoke(a, "old-event", "OLD_HISTORY_MARKER"); const binding = a.ledger.state.bindingId, oldProcess = a.process;
  const state = await f.manager.configure("alice", { pluginId: "openclaw", model: "explicit-fixture" }, f.store.list().revision);
  expect(state.agents.find(a => a.id === "alice")?.pluginId).toBe("openclaw");
  const changed = await f.manager.conversation("settings-chat"); expect(changed.process).not.toBe(oldProcess); expect(changed.ledger.state.bindingId).not.toBe(binding);
  await f.invoke(changed, "new-event", "new request");
  expect(readThreadEvents("settings-chat", f.dir).some(e => e.id === "old-event")).toBe(true);
  expect(f.traces.filter(t => t.method === "session.open").at(-1)!.params.context).toContain("OLD_HISTORY_MARKER");
});

test("unknown execution blocks every chat, configuration switch, and restart for the same agent", async () => {
  const f = fixture("unknown"), a = await f.manager.conversation("unknown-chat", "alice");
  expect(await f.invoke(a, "uncertain-action", "write once")).toMatchObject({ unconfirmed: true });
  expect(f.manager.held("alice")).toContain("unconfirmed");
  await expect(f.manager.conversation("other-chat", "alice")).rejects.toThrow();
  await expect(f.manager.configure("alice", { pluginId: "openclaw" }, f.store.list().revision)).rejects.toThrow("unknown");
  const submissions = f.traces.filter(t => t.method === "turn.submit").length;
  await f.manager.close(); const restarted = new PersonAgentRuntime(f.dir, f.store, () => { throw new Error("must not start"); });
  try { await expect(restarted.conversation("unknown-chat", "alice")).rejects.toThrow(); expect(f.traces.filter(t => t.method === "turn.submit")).toHaveLength(submissions); }
  finally { await restarted.close(); }
});

test("active execution holds configuration changes, while other owned chats keep separate admission identities", async () => {
  const f = fixture("hold"), a = await f.manager.conversation("active-a", "alice"), b = await f.manager.conversation("active-b", "alice");
  const first = f.invoke(a, "active-input-a", "work A"), second = f.invoke(b, "active-input-b", "work B");
  await vi.waitFor(() => expect(f.traces.filter(t => t.method === "turn.submit")).toHaveLength(2));
  await expect(f.manager.configure("alice", { model: "changed" }, f.store.list().revision)).rejects.toThrow("idle");
  const submits = f.traces.filter(t => t.method === "turn.submit");
  for (const t of submits) f.emit(t.process, t.params, "turn.terminal", { state: "completed", text: "done", cessation: "provider-terminal" });
  await Promise.all([first, second]); expect(a.idleConfirmed && b.idleConfirmed).toBe(true);
});

test("A → B → C handoffs use separate restricted instances and never bootstrap B/C private history or memory", async () => {
  const f = fixture("recursive"), ordinaryB = await f.manager.conversation("bob-private-chat", "bob");
  await f.invoke(ordinaryB, "bob-private-input", "BOB_PRIVATE_HISTORY");
  writeFileSync(join(f.store.paths("bob").memoryDir, "MEMORY.md"), "BOB_PRIVATE_MEMORY");
  const a = await f.manager.conversation("alice-main", "alice");
  expect(await f.invoke(a, "alice-delegate", "delegate to Bob")).toMatchObject({ completed: true, text: "completed by carol" });
  const delegated = f.factories.filter(f => f.execution.kind === "handoff"); expect(delegated).toHaveLength(2);
  expect(delegated.map(f => f.scope.chain)).toEqual([["alice", "bob"], ["alice", "bob", "carol"]]);
  for (const exec of delegated) {
    expect(exec.execution.workspace).toContain(exec.execution.scratchRoot); expect(exec.execution.memoryDir).toContain(exec.execution.scratchRoot);
    expect(exec.scope.directories).toEqual([{ path: f.shared, access: "read" }]);
  }
  const transientOpens = f.traces.filter(t => t.method === "session.open" && String(t.params.conversationId).startsWith("agent-handoff-"));
  expect(transientOpens).toHaveLength(2);
  for (const t of transientOpens) {
    expect(t.process).not.toBe(ordinaryB.process); expect((t.process.configuration.initialize.scope as any).allowedTools).not.toContain("memory");
    expect(t.params.context).toContain("SELECTED_SHARED_KNOWLEDGE"); expect(t.params.context).toContain("EXPLICIT_HANDOFF_CONTEXT");
    expect(JSON.stringify(t.params)).not.toMatch(/BOB_PRIVATE_(HISTORY|MEMORY|PREFERENCE)/);
    expect(t.process.configuration.args[1]).toContain(f.store.paths("bob").workspace.split("/workspace")[0]);
  }
  for (const t of f.traces.filter(t => t.method === "request.answer" && t.params.answer.result))
    expect(t.params).toMatchObject({ conversationId: expect.any(String), bindingId: expect.any(String), runId: expect.any(String), attemptId: expect.any(String), requestId: expect.any(String) });
});

test("post-foreground unscoped worker approval and cancel are refused without killing an unrelated conversation", async () => {
  const f = fixture("hold"), a = await f.manager.conversation("approval-chat", "alice"), other = await f.manager.conversation("unrelated-chat", "alice");
  const pending = f.invoke(a, "approval-main", "work"); await vi.waitFor(() => expect(f.traces.some(t => t.method === "turn.submit")).toBe(true));
  const turn = f.traces.find(t => t.method === "turn.submit")!;
  f.emit(a.process, turn.params, "turn.terminal", { state: "completed", text: "delegated", cessation: "provider-terminal" }); await pending;
  f.emit(a.process, turn.params, "request.open", { requestId: "unowned-worker-approval", kind: "approval", tool: "terminal", input: { command: "fixture command" } }, true);
  f.emit(a.process, turn.params, "request.cancel", { requestId: "unowned-worker-approval" }, true);
  await vi.waitFor(() => expect(f.traces.find(t => t.method === "request.answer")?.params).toMatchObject({ requestId: "unowned-worker-approval", answer: { approved: false } }));
  expect(a.process.unavailable).toBe(false); expect(other.hasUnconfirmedExecution).toBe(false);
  expect(a.idleConfirmed).toBe(true);
});

test("scope enforcement has no portable or permissive fallback", () => {
  const f = fixture(), scope = f.store.resolveScope("alice");
  expect(() => isolatedAgentLaunch(scope, { command: process.execPath, args: [], readPaths: [], runtimeDir: f.store.paths("alice").workspace, brokerPorts: [] }, "linux")).toThrow("cannot enforce");
});


test("root Stop fences a late team result and a delegated timeout holds the full identity chain", async () => {
  const f = fixture("cancel-handoff"), a = await f.manager.conversation("stop-chain", "alice");
  const controller = new AbortController(), pending = f.invoke(a, "stop-origin", "delegate to Bob", { signal: controller.signal });
  await vi.waitFor(() => expect(f.traces.filter(t => t.method === "turn.submit")).toHaveLength(2));
  controller.abort();
  const rootTurn = f.traces.find(t => t.method === "turn.submit")!;
  f.emit(a.process, rootTurn.params, "turn.terminal", { state: "stopped", text: "stopped", cessation: "provider-terminal" }); await pending;
  await vi.waitFor(() => expect(f.manager.held("bob")).toContain("unconfirmed"));
  expect(f.traces.filter(t => t.method === "turn.submit")).toHaveLength(2);
  expect(f.traces.filter(t => t.method === "request.answer" && t.params.answer?.result)).toHaveLength(0);
  await expect(f.manager.configure("bob", { pluginId: "openclaw" }, f.store.list().revision)).rejects.toThrow("unknown");
});

test("a curated runtime cannot expose host ledgers or another agent's private state as code", async () => {
  const f = fixture();
  (f.manager as any).factory = (_agent: any, _scope: any, execution: any) => ({
    configuration: { pluginId: "hermes", upstreamVersion: "fixture-1", command: process.execPath, args: [], initialize: {} },
    runtime: { command: process.execPath, args: [], runtimeDir: execution.scratchRoot, readPaths: [f.dir], brokerPorts: [] }
  });
  await expect(f.manager.conversation("bad-runtime", "alice")).rejects.toThrow(/private/);
  expect(f.traces).toHaveLength(0);
});


test("failed settings validation and failed target preparation preserve the selected idle owner", async () => {
  const f = fixture(), a = await f.manager.conversation("rollback-chat", "alice"); await f.invoke(a, "settled-input", "hello");
  const revision = f.store.list().revision;
  await expect(f.manager.configure("alice", { model: "changed" }, revision - 1)).rejects.toThrow("revision conflict");
  expect(await f.manager.conversation("rollback-chat")).toBe(a); expect(a.process.unavailable).toBe(false);
  f.store.update("alice", { pluginId: "openclaw" }, revision);
  (f.manager as any).factory = () => { throw new Error("target cannot enforce scope"); };
  await expect(f.manager.conversation("rollback-chat")).rejects.toThrow("target cannot enforce scope");
  expect(a.process.unavailable).toBe(false); expect(readThreadEvents("rollback-chat", f.dir).some(e => e.id === "settled-input")).toBe(true);
});


test("host-selected shared resources cannot expose another vendor profile or a teammate's ordinary scratch", async () => {
  const f = fixture(), b = await f.manager.conversation("private-b", "bob");
  const bobScratch = f.factories[0].execution.scratchRoot;
  f.store.update("alice", { directories: [{ path: bobScratch, access: "read" }] }, f.store.list().revision);
  await expect(f.manager.conversation("bad-scratch", "alice")).rejects.toThrow("private vendor scratch");
  expect(f.factories).toHaveLength(1); expect(b.process.unavailable).toBe(false);
});


test("idle chat owners release their ledger leases while the ordinary daemon and binding remain reusable", async () => {
  const f = fixture(), first = await f.manager.conversation("many-0", "alice"); await f.invoke(first, "settled-0", "hello");
  const process = first.process, binding = first.ledger.state.bindingId;
  for (let n = 1; n <= 4; n++) await f.manager.conversation(`many-${n}`, "alice");
  expect(f.factories).toHaveLength(1); expect(process.unavailable).toBe(false);
  const reopened = await f.manager.owner("many-0"); expect(reopened).not.toBe(first); expect(reopened!.process).toBe(process);
  expect(reopened!.ledger.state.bindingId).toBe(binding); expect(readThreadEvents("many-0", f.dir).some(e => e.id === "settled-0")).toBe(true);
  expect(await f.invoke(reopened!, "settled-1", "hello again")).toMatchObject({ completed: true });
});

test("legacy worker records hold secretary migration without starting or changing a binding", () => {
  const f = fixture();
  const task = join(f.dir, "secretary-tasks-v1", "saved-worker"); mkdirSync(task, { recursive: true });
  writeFileSync(join(task, "task.json"), "retained worker evidence");
  expect(() => f.manager.bindSecretary("alice")).toThrow("explicit reconciliation");
  expect(f.manager.bindingForThread("yorozu-secretary-v1")).toBeUndefined();
  expect(readFileSync(join(task, "task.json"), "utf8")).toBe("retained worker evidence");
  expect(f.factories).toEqual([]); expect(f.traces).toEqual([]);
});
