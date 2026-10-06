/** Actual host storage/process boundary; all conversations and inference are synthetic. */
import { afterEach, expect, test, vi } from "vitest";
import { mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { SecretaryHarness } from "./harness-runner.js";
import { appendThreadEvent, createThread, listThreads, readThreadEvents, setNativeTurn, setThreadSession } from "./threads.js";
import { SECRETARY_THREAD_ID } from "./secretary-runner.js";
import type { NativeTurn } from "./native.js";
import type { YorozuEvent } from "@yorozu/shared";

const cleanups: Array<() => Promise<void>> = [];
afterEach(async () => { for (const cleanup of cleanups.splice(0)) await cleanup(); vi.unstubAllEnvs(); });

const ready = { protocolVersion: 1, pluginId: "hermes", upstreamVersion: "0.21.5",
  capabilities: { backgroundTasks: true, targetedSteer: true, taskStop: true, approvals: true, reconnect: true, attachments: false } };

function fixture(mode = "manual") {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "yorozu-harness-runner-")));
  const dir = join(root, "state"); const trace = join(root, "trace.jsonl");
  vi.stubEnv("YOROZU_PROJECTS_DIR", join(root, "projects"));
  const peer = join(root, "peer.mjs");
  writeFileSync(peer, `import {createInterface} from 'node:readline'; import {appendFileSync} from 'node:fs';
    const trace=${JSON.stringify(trace)}, mode=${JSON.stringify(mode)}; let submissions=0, seq=0, current;
    const send=f=>process.stdout.write(JSON.stringify(f)+'\\n');
    const event=(kind,data,scope=current)=>send({jsonrpc:'2.0',method:'harness.event',params:{protocolVersion:1,
      eventId:'peer-'+(++seq),conversationId:'${SECRETARY_THREAD_ID}',runId:scope?.runId,attemptId:scope?.attemptId,kind,data}});
    createInterface({input:process.stdin}).on('line',line=>{const f=JSON.parse(line),p=f.params;
      appendFileSync(trace,JSON.stringify({method:f.method,params:p})+'\\n');
      const reply=result=>send({jsonrpc:'2.0',id:f.id,result});
      if(f.method==='initialize') return reply(${JSON.stringify(ready)});
      if(f.method==='session.open') return reply({sessionId:'private-upstream-session'});
      if(f.method==='shutdown'){reply({status:'closed'});return setImmediate(()=>process.exit(0));}
      if(f.method==='fixture.emit'){event(p.kind,p.data,p.scope);return reply({status:'emitted'});}
      if(f.method==='turn.submit'){
        submissions++;
        if(mode==='busy'&&submissions<4)return reply({status:'busy',handoff:'not-submitted'});
        if(mode==='uncertain'){reply({status:'unknown'});return;}
        if(mode==='late-refusal'){event('runtime.closed',{});return reply({status:'rejected',reason:'late stale refusal'});}
        current=p; reply({status:'accepted'});
        if(mode==='busy') event('turn.terminal',{state:'completed',text:'Japanese fixture reply',cessation:'provider-terminal'});
        return;
      }
      if(f.method==='task.steer')return reply({status:'unknown',reason:'native acknowledgement lost'});
      if(f.method==='task.stop'){
        if(mode==='stop-race')event('task.changed',{taskId:p.taskId,originRunId:p.runId,title:'Specialist',state:'completed',text:'settled before receipt',canSteer:false,canStop:false},{runId:p.runId,attemptId:p.attemptId});
        return reply({status:'requested'});
      }
      if(f.method==='run.stop')return reply({status:'requested'});
      reply({status:'unsupported'});
    });`);
  const harness = new SecretaryHarness(dir, { pluginId: "hermes", upstreamVersion: "0.21.5",
    command: process.execPath, args: [peer], initialize: {} });
  cleanups.push(async () => { await harness.close(); rmSync(root, { recursive: true, force: true }); });
  const events: YorozuEvent[] = [];
  harness.bind({ emit(event) { events.push(event); appendThreadEvent(event, dir); }, changed() {} });
  const rows = (): any[] => readFileSync(trace, "utf8").trim().split("\n").map(JSON.parse);
  const invoke = (eventId: string, text: string, threadId = SECRETARY_THREAD_ID, extra: Partial<NativeTurn> = {}) => {
    appendThreadEvent({ id: eventId, threadId, agentId: "main", ts: Date.now(), kind: "message", data: { role: "user", text } }, dir);
    setNativeTurn(threadId, { id: `native:${eventId}:final`, userEventId: eventId, state: "running" }, dir);
    return harness.runner.run({ threadId, cwd: harness.workspace, text, signal: new AbortController().signal, ...extra });
  };
  const emit = (kind: string, data: Record<string, unknown>, run: { runId: string; attemptId: string }) =>
    harness.process.request("fixture.emit", { kind, data, scope: run });
  const admitted = async (eventId: string) => {
    await vi.waitFor(() => expect(harness.ledger.state.runs[eventId]?.state).toBe("running"));
    return harness.ledger.state.runs[eventId];
  };
  return { root, dir, harness, events, rows, invoke, emit, admitted };
}

test("known preflight busy retains one accepted input and retries only identical currency before one execution", async () => {
  const f = fixture("busy");
  expect(await f.invoke("accepted-busy", "hello")).toMatchObject({ completed: true, cessation: "provider-terminal" });
  const submissions = f.rows().filter(row => row.method === "turn.submit");
  expect(submissions).toHaveLength(4);
  expect(new Set(submissions.map(row => JSON.stringify(row.params))).size).toBe(1);
  expect(readThreadEvents(SECRETARY_THREAD_ID, f.dir).filter(e => e.id === "accepted-busy")).toHaveLength(1);
});

test("an uncertain admission is never retried and a late rejection cannot erase earlier uncertainty", async () => {
  for (const mode of ["uncertain", "late-refusal"]) {
    const f = fixture(mode);
    expect(await f.invoke("lost-receipt", "perform once")).toMatchObject({ unconfirmed: true });
    expect(f.harness.ledger.state.runs["lost-receipt"].state).toBe("unknown");
    expect(await f.invoke("later-input", "try later")).toMatchObject({ unconfirmed: true });
    expect(f.rows().filter(row => row.method === "turn.submit")).toHaveLength(1);
  }
});

test("native result continuation holds the next accepted input; a child it creates uses that exact attempt for controls", async () => {
  const f = fixture(); const first = f.invoke("first-input", "delegate"); const run = await f.admitted("first-input");
  await f.emit("turn.terminal", { state: "completed", text: "started", cessation: "provider-terminal" }, run); await first;
  const continuation = { runId: run.runId, attemptId: "native-continuation-attempt" };
  await f.emit("turn.started", { continuation: true, originRunId: run.runId }, continuation);
  const second = f.invoke("second-input", "new topic");
  await f.emit("task.changed", { taskId: "continuation-child", originRunId: run.runId, title: "Specialist", state: "running", canSteer: true, canStop: true }, continuation);
  expect(f.rows().filter(row => row.method === "turn.submit")).toHaveLength(1);
  const taskThread = f.harness.taskThread("continuation-child");
  expect(await f.invoke("exact-change", "change only this child", taskThread)).toMatchObject({ cessation: "control-receipt", controlReceipt: { status: "unknown" } });
  expect(f.rows().find(row => row.method === "task.steer")?.params).toMatchObject({ runId: run.runId, attemptId: continuation.attemptId, taskId: "continuation-child", operationId: "exact-change" });
  // A duplicate accepted control reports the stored uncertainty without resending it.
  expect(await f.invoke("exact-change", "change only this child", taskThread)).toMatchObject({ controlReceipt: { status: "unknown" } });
  expect(f.rows().filter(row => row.method === "task.steer")).toHaveLength(1);
  await f.emit("turn.terminal", { state: "completed", text: "result delivery", cessation: "provider-terminal" }, continuation);
  const next = await f.admitted("second-input");
  await f.emit("turn.terminal", { state: "completed", text: "new topic reply", cessation: "provider-terminal" }, next); await second;
  expect(f.events.find(e => e.kind === "message" && e.data.text === "result delivery")).toMatchObject({ threadId: SECRETARY_THREAD_ID, data: { replyTo: "first-input", done: true } });
});

test("stale task Stop never reaches upstream and a terminal before its receipt remains completed", async () => {
  const f = fixture("stop-race"); const pending = f.invoke("task-origin", "delegate"); const run = await f.admitted("task-origin");
  await f.emit("task.changed", { taskId: "exact-child", originRunId: run.runId, title: "Specialist", state: "running", canSteer: true, canStop: true }, run);
  const threadId = f.harness.taskThread("exact-child");
  const interrupt = (id: string, targetEventId: string): YorozuEvent => ({ id, threadId, ts: Date.now(), agentId: "main", kind: "interrupt", data: { targetEventId } });
  expect(await f.harness.taskStop(interrupt("stale-stop", "old-target"))).toBe(true);
  expect(f.rows().filter(row => row.method === "task.stop")).toHaveLength(0);
  const target = f.harness.summary(threadId)?.activeEventId!;
  await f.harness.taskStop(interrupt("exact-stop", target));
  expect(f.harness.summary(threadId)?.harnessTask?.state).toBe("completed");
  expect(f.rows().filter(row => row.method === "task.stop")).toHaveLength(1);
  await f.harness.taskStop(interrupt("exact-stop", target));
  expect(f.rows().filter(row => row.method === "task.stop")).toHaveLength(1);
  expect(f.events.filter(e => e.kind === "message" && e.data.controlReceipt?.operationId === "exact-stop")
    .every(e => e.kind === "message" && e.data.controlReceipt?.status === "requested")).toBe(true);
  await f.emit("turn.terminal", { state: "completed", text: "done", cessation: "provider-terminal" }, run); await pending;
});

test("main bootstrap excludes queued new inputs and preserves an existing thread's backend session and unrelated history", async () => {
  const f = fixture("busy");
  // The existing secretary record simulates the immutable pre-plugin Codex history.
  const main = listThreads(f.dir).find(t => t.id === SECRETARY_THREAD_ID)!;
  setThreadSession(SECRETARY_THREAD_ID, "legacy-codex-session", f.dir);
  createThread("Existing coding", f.dir, "legacy-coding", { agent: "codex", cwd: f.harness.workspace });
  appendThreadEvent({ id: "old-history", threadId: SECRETARY_THREAD_ID, ts: 1, agentId: "main", kind: "message", data: { role: "user", text: "prior harmless context" } }, f.dir);
  appendThreadEvent({ id: "accepted-now", threadId: SECRETARY_THREAD_ID, ts: 2, agentId: "main", kind: "message", data: { role: "user", text: "CURRENT_INPUT_MARKER" } }, f.dir);
  appendThreadEvent({ id: "queued-later", threadId: SECRETARY_THREAD_ID, ts: 3, agentId: "main", kind: "message", data: { role: "user", text: "QUEUED_INPUT_MARKER" } }, f.dir);
  await f.invoke("accepted-now", "CURRENT_INPUT_MARKER");
  const context = f.rows().find(row => row.method === "session.open")?.params.context;
  expect(context).toContain("prior harmless context"); expect(context).not.toContain("CURRENT_INPUT_MARKER"); expect(context).not.toContain("QUEUED_INPUT_MARKER");
  expect(listThreads(f.dir).find(t => t.id === SECRETARY_THREAD_ID)).toMatchObject({ agent: main.agent, nativeSessionId: "legacy-codex-session" });
  expect(listThreads(f.dir).find(t => t.id === "legacy-coding")).toMatchObject({ agent: "codex" });
});

test.each(["platform", "unscoped", "scoped"])("%s refusal uses an exact session-bound envelope accepted by the real adapter", async kind => {
  const f = fixture("busy"); await f.invoke("fallback-origin", "hello");
  const { createAdapter } = await import(new URL("../../harness-plugins/hermes/adapter.mjs", import.meta.url).href);
  const responses: any[] = []; let frame!: (value: any) => void;
  const gateway = { closed: false, onFrame(fn: any) { frame = fn; }, onClose() {},
    async call(method: string) {
      if (method === "client.capabilities") return { server_requests: ["approval", "clarify"] };
      if (method === "session.create") return { session_id: "live-fixture", stored_session_id: "private-upstream-session", info: {}, messages: [], message_count: 0 };
      if (method === "session.activate") return { session_id: "live-fixture", running: false, inflight: null };
      if (method === "session.history") return { messages: [], count: 0 };
      throw new Error(`Unexpected inert gateway method ${method}`);
    }, respond(id: string, result: any) { responses.push({ id, result }); } };
  const harness = f.harness as any;
  harness.ready.extensions = { version: 1, conversationActions: true };
  harness.configuration.initialize.agentId = "alice";
  const adapter = createAdapter({ emit(event: any) { if (kind === "platform") harness.consume(event); }, launch: async () => ({ gateway, authAvailable: true, provider: "fixture", model: "fixture", workspace: f.harness.workspace }) });
  await adapter.handle("initialize", { protocolVersion: 1 });
  await adapter.handle("session.open", { conversationId: f.harness.conversationId, bindingId: f.harness.ledger.state.bindingId });
  const request = vi.spyOn(f.harness.process, "request").mockImplementation((method, params) => adapter.handle(method, params));
  try {
    frame({ jsonrpc: "2.0", id: "refuse-native", method: "approval", params: { session_id: "live-fixture", tool_name: "synthetic", choices: ["once", "deny"] } });
    const run = f.harness.ledger.state.runs["fallback-origin"];
    const event = { protocolVersion: 1, eventId: "unavailable-host", conversationId: f.harness.conversationId, kind: "request.open", data: { requestId: "refuse-native", kind: "approval", tool: "synthetic", input: {} } };
    if (kind === "unscoped") harness.consume(event);
    if (kind === "scoped") await harness.answerRequest({ ...event, runId: run.runId, attemptId: run.attemptId }, run);
    await vi.waitFor(() => expect(responses).toEqual([{ id: "refuse-native", result: { choice: "deny" } }]));
    expect(request).toHaveBeenCalledWith("request.answer", { requestId: "refuse-native", sessionId: "private-upstream-session", answer: { approved: false } });
  } finally { request.mockRestore(); }
});

test("privileged worker approval currency dies on stop and never revives for a later turn", async () => {
  const f = fixture(); expect(f.harness.workerTurn()).toBeUndefined();
  const first = f.invoke("worker-turn-1", "request a memory share"), run = await f.admitted("worker-turn-1");
  const currency = f.harness.workerTurn()!;
  expect(currency).toMatchObject({ runId: run.runId, attemptId: run.attemptId }); expect(currency.current()).toBe(true);
  await f.harness.stop("stop-worker-turn-1");
  // Requested cancellation is enough to remove authority; no terminal proof is fabricated.
  expect(currency.current()).toBe(false); expect(f.harness.workerTurn()).toBeUndefined();
  expect(f.harness.ledger.state.runs["worker-turn-1"].state).toBe("running");
  await f.emit("turn.terminal", { state: "stopped", text: "Stopped", cessation: "provider-terminal" }, run); await first;
  const second = f.invoke("worker-turn-2", "a different request"), next = await f.admitted("worker-turn-2");
  expect(f.harness.workerTurn()?.current()).toBe(true); expect(currency.current()).toBe(false);
  await f.emit("turn.terminal", { state: "completed", text: "Done", cessation: "provider-terminal" }, next); await second;
  expect(f.harness.workerTurn()).toBeUndefined();
});

test("exact foreground and verified continuation memory currency cancels before stop receipt and never revives", async () => {
  const f = fixture(), first = f.invoke("memory-origin", "delegate"), run = await f.admitted("memory-origin");
  const execution = { sessionId: "private-upstream-session", runId: run.runId, attemptId: run.attemptId };
  const foreground = f.harness.workerWork(execution)!;
  expect(foreground.current()).toBe(true);
  for (const field of ["sessionId", "runId", "attemptId"]) expect(f.harness.workerWork({ ...execution, [field]: "wrong" })).toBeUndefined();
  await f.emit("turn.terminal", { state: "completed", text: "delegated", cessation: "provider-terminal" }, run); await first;
  expect(foreground.signal.aborted).toBe(true); expect(foreground.current()).toBe(false);
  const continuation = { ...execution, attemptId: "verified-continuation" };
  expect(f.harness.workerWork(continuation)).toBeUndefined();
  await f.emit("turn.started", { continuation: true, originRunId: run.runId }, continuation);
  const work = f.harness.workerWork(continuation)!;
  expect(work.current()).toBe(true); expect(f.harness.workerWork(execution)).toBeUndefined();
  for (const field of ["sessionId", "runId", "attemptId"]) expect(f.harness.workerWork({ ...continuation, [field]: "wrong" })).toBeUndefined();
  const stopping = f.harness.stop("stop-memory-continuation");
  expect(work.signal.aborted).toBe(true); expect(work.current()).toBe(false);
  await stopping;
  expect(f.harness.ledger.state.autonomous[continuation.attemptId].state).toBe("running");
  expect(f.harness.workerWork(continuation)).toBeUndefined();
  await f.emit("turn.terminal", { state: "stopped", text: "stopped", cessation: "provider-terminal" }, continuation);
  const next = f.invoke("memory-next", "new work"), nextRun = await f.admitted("memory-next");
  expect(work.current()).toBe(false); expect(f.harness.workerWork(continuation)).toBeUndefined();
  await f.emit("turn.terminal", { state: "completed", text: "done", cessation: "provider-terminal" }, nextRun); await next;
  expect(f.rows().filter(row => row.method === "turn.submit")).toHaveLength(2);
});

test("lost continuation owner fences restart and cannot replay or remint memory authority", async () => {
  const f = fixture(), first = f.invoke("lost-memory-owner", "delegate"), run = await f.admitted("lost-memory-owner");
  await f.emit("turn.terminal", { state: "completed", text: "delegated", cessation: "provider-terminal" }, run); await first;
  const execution = { sessionId: "private-upstream-session", runId: run.runId, attemptId: "lost-continuation" };
  await f.emit("turn.started", { continuation: true, originRunId: run.runId }, execution);
  const work = f.harness.workerWork(execution)!;
  await f.harness.close();
  expect(work.signal.aborted).toBe(true); expect(work.current()).toBe(false);
  const reopened = new SecretaryHarness(f.dir, f.harness.configuration);
  try {
    expect(reopened.workerWork(execution)).toBeUndefined();
    expect(reopened.hasUnconfirmedExecution).toBe(true);
    expect(await reopened.runner.run({ threadId: SECRETARY_THREAD_ID, cwd: reopened.workspace, text: "do not replay", signal: new AbortController().signal })).toMatchObject({ failed: true, cessation: "not-submitted" });
    expect(f.rows().filter(row => row.method === "turn.submit")).toHaveLength(1);
  } finally { await reopened.close(); }
});

test("all continuation capabilities are invalidated before bounded serialized Stop handoffs", async () => {
  const f = fixture(), first = f.invoke("many-continuations", "synthetic delegation");
  const run = await f.admitted("many-continuations");
  await f.emit("turn.terminal", { state: "completed", text: "Started", cessation: "provider-terminal" }, run); await first;
  const continuations = Array.from({ length: 40 }, (_, i) => ({ runId: run.runId, attemptId: `bounded-continuation-${i}` }));
  for (const work of continuations) await f.emit("turn.started", { continuation: true, originRunId: run.runId }, work);
  const capabilities = continuations.map(work => f.harness.workerWork({ ...work, sessionId: "private-upstream-session" })!);
  expect(capabilities.every(capability => capability.current())).toBe(true);
  const stopping = f.harness.stop("stop-all-continuations");
  expect(capabilities.every(capability => capability.signal.aborted && !capability.current())).toBe(true);
  await stopping;
  expect(f.rows().filter(row => row.method === "run.stop")).toHaveLength(40);
  expect(Object.values(f.harness.ledger.state.controls).some(control => control.state === "unknown")).toBe(false);
  for (const work of continuations) await f.emit("turn.terminal", { state: "stopped", text: "Stopped", cessation: "provider-terminal" }, work);
});
