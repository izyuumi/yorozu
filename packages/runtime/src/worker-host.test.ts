/** Real SQL, registry, action journal and kernel leases; native process is synthetic here.
 * worker-transport.test covers the separate real encrypted/child-pipe boundary. */
import { afterEach, expect, test, vi } from "vitest";
import { mkdtempSync, realpathSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { PersonAgentHost } from "./person-agent-host.js";
import { WorkerMemory } from "./worker-memory.js";
import { createMinimalWorkerPlatform } from "./worker-platform.js";
import { HarnessProcess } from "./harness-process.js";
import { appendThreadEvent, setNativeTurn } from "./threads.js";
import { closeSyncHost } from "./rust-sync.js";
import type { HarnessEvent, HarnessReady } from "./harness-contract.js";
import type { YorozuEvent } from "@yorozu/shared";

const cleanup: Array<() => Promise<void>> = [];
afterEach(async () => { for (const fn of cleanup.splice(0)) await fn(); vi.restoreAllMocks(); });
function fixture() {
  const dir = realpathSync(mkdtempSync(join(tmpdir(), "yorozu-worker-host-")));
  const turns: Array<{ process: HarnessProcess; params: any }> = [];
  const events: YorozuEvent[] = []; let seq = 0;
  const emit = (p: HarnessProcess, params: any, state = "completed") => {
    const event: HarnessEvent = { protocolVersion: 1, eventId: `terminal-${++seq}`, conversationId: params.conversationId,
      runId: params.runId, attemptId: params.attemptId, kind: "turn.terminal", data: { state, text: "synthetic result", cessation: "provider-terminal" } };
    for (const listener of p.listeners) listener(event);
  };
  vi.spyOn(HarnessProcess.prototype, "start").mockImplementation(async function (this: HarnessProcess) {
    return { protocolVersion: 1, pluginId: this.configuration.pluginId, upstreamVersion: "fixture", workerMemory: true,
      capabilities: { backgroundTasks: true, targetedSteer: true, taskStop: true, approvals: true, reconnect: false, attachments: false } } as HarnessReady;
  });
  vi.spyOn(HarnessProcess.prototype, "request").mockImplementation(async function (this: HarnessProcess, method, params) {
    if (method === "session.open") return { sessionId: `native-${params.conversationId}` };
    if (method === "turn.submit") { turns.push({ process: this, params }); return { status: "accepted" }; }
    if (method === "run.stop") { queueMicrotask(() => emit(this, params, "stopped")); return { status: "requested" }; }
    return { status: "unsupported" };
  });
  const platform = createMinimalWorkerPlatform({ secretaryAgentId: "alice", adapters: [{ id: "hermes", label: "Fixture Hermes", memory: "worker-memory-v1",
    createFactory: () => (agent, _scope, execution) => ({
      configuration: { pluginId: agent.pluginId, upstreamVersion: "fixture", command: process.execPath, args: [], initialize: {} },
      runtime: { command: process.execPath, args: [], runtimeDir: execution.scratchRoot, readPaths: [], brokerPorts: [] },
    }) }], initialAgent: { id: "alice", name: "Alice", role: "Writer", pluginId: "hermes", allowedTools: ["memory"] } });
  const host = new PersonAgentHost(dir, platform);
  host.store.create({ id: "bob", name: "Bob", role: "Reader", pluginId: "hermes", allowedTools: ["memory"] }, host.store.list().revision);
  host.bind({ emit: e => { events.push(e); appendThreadEvent(e, dir); }, changed() {} });
  const registry = host.registry();
  cleanup.push(async () => { await host.close(); closeSyncHost(dir); rmSync(dir, { recursive: true, force: true }); });
  const start = async (agent: string, id: string) => {
    const threadId = registry.agents.find(a => a.id === agent)!.conversationId!, abort = new AbortController();
    appendThreadEvent({ id, threadId, agentId: "phone", ts: Date.now(), kind: "message", data: { role: "user", text: "synthetic request" } }, dir);
    setNativeTurn(threadId, { id: `native-${id}`, userEventId: id, state: "running" }, dir);
    const before = turns.length;
    const pending = host.runner.run({ threadId, text: "synthetic request", cwd: "/caller-spoof", signal: abort.signal, bypass: true });
    await vi.waitFor(() => expect(turns.slice(before).some(t => t.params.conversationId === threadId)).toBe(true));
    const turn = turns.filter(t => t.params.conversationId === threadId).at(-1)!;
    const call = (params: unknown) => turn.process.configuration.workerTool!("worker.memory", params, new AbortController().signal);
    return { ...turn, pending, call, abort, threadId };
  };
  const answer = (action: any, id: string, choiceId: string, origin = action.origin) => host.action({ id, kind: "harness_action_answer",
    threadId: action.origin.conversationId, agentId: "phone", ts: Date.now(), data: { version: 1, requestId: action.requestId, origin, choiceId } } as YorozuEvent);
  const action = () => events.filter(e => e.kind === "harness_action" && e.data.state === "pending").at(-1)!.data;
  return { dir, host, start, answer, action, events, emit };
}

test("host-derived agent capability, SQL root exclusion, exact sharing approval and immediate revocation", async () => {
  const f = fixture(), alice = await f.start("alice", "alice-first"), bob = await f.start("bob", "bob-first");
  const policy = alice.process.configuration.args[1];
  expect(policy).toContain(join(f.dir, "worker-memory-v1"));
  expect(alice.process.configuration.initialize.workerMemory).toBe(true);
  const scope = alice.process.configuration.initialize.scope as any;
  expect(scope.directories.some((g: any) => g.path === f.host.store.paths("alice").memoryDir)).toBe(false);
  await alice.call({ action: "write", key: "note", body: "ALICE_ONLY_SYNTHETIC", operationId: "write-1" });
  await bob.call({ action: "write", key: "note", body: "BOB_ONLY_SYNTHETIC", operationId: "write-1" });
  await expect(bob.call({ action: "read", ownerId: "alice", key: "note" })).rejects.toThrow();
  await expect(alice.call({ action: "write", ownerId: "bob", key: "note", body: "spoof", operationId: "spoof-1" })).rejects.toThrow();
  const denied = alice.call({ action: "grant", toAgentId: "bob", key: "note", operationId: "deny-grant" });
  const denial = expect(denied).rejects.toThrow("not approved");
  await f.answer(f.action(), "deny-answer", "deny"); await denial;
  await expect(bob.call({ action: "read", ownerId: "alice", key: "note" })).rejects.toThrow();
  const granted = alice.call({ action: "grant", toAgentId: "bob", key: "note", operationId: "grant-1" });
  const card = f.action(); expect(card.origin.agentId).toBe("alice"); expect(card.origin.workId).toMatch(/^work-/);
  await expect(f.answer(card, "forged-answer", "allow-once", { ...card.origin, agentId: "bob" })).rejects.toThrow();
  await f.answer(card, "allow-answer", "allow-once"); await expect(granted).resolves.toEqual({ ok: true });
  expect(await bob.call({ action: "read", ownerId: "alice", key: "note" })).toEqual({ value: "ALICE_ONLY_SYNTHETIC" });
  await alice.call({ action: "revoke", toAgentId: "bob", key: "note", operationId: "revoke-1" });
  await expect(bob.call({ action: "read", ownerId: "alice", key: "note" })).rejects.toThrow();
  expect(await bob.call({ action: "read", ownerId: "bob", key: "note" })).toEqual({ value: "BOB_ONLY_SYNTHETIC" });
  f.emit(alice.process, alice.params); f.emit(bob.process, bob.params); await Promise.all([alice.pending, bob.pending]);
});

test("stop cancels a pending memory grant; an old card cannot acquire authority in the next turn", async () => {
  const f = fixture(), alice = await f.start("alice", "stop-origin"), bob = await f.start("bob", "reader-origin");
  await alice.call({ action: "write", key: "note", body: "PRIVATE_SYNTHETIC", operationId: "write-1" });
  const sharing = alice.call({ action: "grant", toAgentId: "bob", key: "note", operationId: "grant-stop" });
  const cancelled = expect(sharing).rejects.toThrow("cancelled"), old = f.action();
  alice.abort.abort(); await cancelled; await alice.pending;
  await expect(alice.call({ action: "write", key: "note", body: "late write", operationId: "write-after-stop" })).rejects.toThrow("active foreground");
  const next = await f.start("alice", "next-turn");
  await f.answer(old, "stale-allow", "allow-once");
  await expect(bob.call({ action: "read", ownerId: "alice", key: "note" })).rejects.toThrow();
  f.emit(next.process, next.params); f.emit(bob.process, bob.params); await Promise.all([next.pending, bob.pending]);
});

test("changed note before approval is a known rejection, not an unknown mutation fence", async () => {
  const f = fixture(), alice = await f.start("alice", "edit-origin"), bob = await f.start("bob", "edit-reader");
  await alice.call({ action: "write", key: "note", body: "ORIGINAL_SYNTHETIC", operationId: "write-1" });
  const sharing = alice.call({ action: "grant", toAgentId: "bob", key: "note", operationId: "grant-edit" });
  const rejected = expect(sharing).rejects.toThrow("precondition changed"), card = f.action();
  await alice.call({ action: "write", key: "note", body: "CHANGED_SYNTHETIC", operationId: "write-2" });
  await f.answer(card, "answer-after-edit", "allow-once"); await rejected;
  expect(f.host.runtime.platformStore.hasUnconfirmedActions("alice")).toBe(false);
  await expect(bob.call({ action: "read", ownerId: "alice", key: "note" })).rejects.toThrow();
  expect(await alice.call({ action: "write", key: "other", body: "STILL_AUTHORIZED", operationId: "write-3" })).toEqual({ ok: true });
  f.emit(alice.process, alice.params); f.emit(bob.process, bob.params); await Promise.all([alice.pending, bob.pending]);
});

test("cancellation journal failure cannot leave the privileged tool promise hanging", async () => {
  const f = fixture(), alice = await f.start("alice", "cancel-journal-origin");
  await alice.call({ action: "write", key: "note", body: "PRIVATE_SYNTHETIC", operationId: "write-1" });
  const sharing = alice.call({ action: "grant", toAgentId: "bob", key: "note", operationId: "grant-cancel" });
  const rejected = expect(sharing).rejects.toThrow("cancelled");
  vi.spyOn(f.host.runtime.platformStore, "cancelAction").mockImplementation(() => { throw new Error("synthetic persistence failure"); });
  alice.abort.abort(); await rejected; await alice.pending;
});


test("a lost receipt after the SQL grant commit remains unknown and fences further owner tools", async () => {
  const bind = WorkerMemory.prototype.bind; let loseReceipt = false;
  vi.spyOn(WorkerMemory.prototype, "bind").mockImplementation(function (this: WorkerMemory, agentId) {
    const capability = bind.call(this, agentId);
    return Object.freeze({ ...capability, grant(to: string, key: string, operationId: string) {
      capability.grant(to, key, operationId);
      if (loseReceipt) throw new Error("synthetic post-commit receipt loss");
    } });
  });
  const f = fixture(), alice = await f.start("alice", "uncertain-origin"), bob = await f.start("bob", "uncertain-reader");
  await alice.call({ action: "write", key: "note", body: "SELECTED_SYNTHETIC", operationId: "write-1" });
  loseReceipt = true;
  const sharing = alice.call({ action: "grant", toAgentId: "bob", key: "note", operationId: "grant-uncertain" });
  const uncertain = expect(sharing).rejects.toThrow("unconfirmed");
  await f.answer(f.action(), "uncertain-answer", "allow-once"); await uncertain;
  expect(f.host.runtime.platformStore.hasUnconfirmedActions("alice")).toBe(true);
  await expect(alice.call({ action: "write", key: "other", body: "blocked", operationId: "blocked-write" })).rejects.toThrow();
  expect(await bob.call({ action: "read", ownerId: "alice", key: "note" })).toEqual({ value: "SELECTED_SYNTHETIC" });
  f.emit(alice.process, alice.params); f.emit(bob.process, bob.params); await Promise.all([alice.pending, bob.pending]);
});
