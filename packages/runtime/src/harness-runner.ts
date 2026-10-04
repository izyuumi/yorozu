/** Thin host supervision. The selected harness owns every planning/delegation decision. */
import { randomUUID } from "node:crypto";
import { existsSync, lstatSync, mkdirSync, realpathSync } from "node:fs";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { ThreadSummary, YorozuEvent } from "@yorozu/shared";
import type { NativeAgentRunner, NativeTurn, NativeTurnResult } from "./native.js";
import { createThread, listThreads, readThreadEvents } from "./threads.js";
import { projectsRoot } from "./projects.js";
import { SECRETARY_THREAD_ID } from "./secretary-runner.js";
import { HarnessProcess } from "./harness-process.js";
import { HarnessLedger, harnessDigest, type HarnessRun } from "./harness-ledger.js";
import { taskIsLive, validHarnessTask, type HarnessConfiguration, type HarnessEvent, type HarnessReady, type HarnessReceipt, type HarnessTask } from "./harness-contract.js";
import type { ScopeSelection } from "./agent-scope.js";

export interface HarnessHandoffIdentity {
  conversationId: string; bindingId: string; runId: string; attemptId: string; requestId: string;
}
export interface HarnessHandoffInput {
  teammateId: string; context: string; expectedResult: string;
  scope: ScopeSelection & { sharedResourceIds?: string[] };
}
export interface HarnessHandoffResult { status: "completed" | "failed" | "unknown" | "rejected"; taskId?: string; text?: string }
export interface SecretaryHarnessOptions {
  conversationId?: string; workspace?: string; ledgerDir?: string; title?: string; sharedProcess?: HarnessProcess;
  /** Trusted host reference data. A restricted handoff never receives old history. */
  historyBootstrap?: boolean; context?: string;
  /** Agent-wide admission gate, including unknown outcomes in other threads. */
  beforeAdmission?(): void;
  /** Explicit host migration: retain the legacy backend metadata as rollback evidence. */
  preserveLegacyMetadata?: true;
}

export interface HarnessServices {
  emit(event: YorozuEvent): void;
  changed(): void;
  /** Portable owner interface; preference text never grants permission. */
  preferences?(): { revision: string; text: string; language?: string };
  handoff?(identity: HarnessHandoffIdentity, input: HarnessHandoffInput, signal: AbortSignal): Promise<HarnessHandoffResult>;
}
type Live = { run: HarnessRun; turn: NativeTurn; finish(result: NativeTurnResult): void; text: string };
export class SecretaryHarness {
  readonly ledger: HarnessLedger;
  readonly process: HarnessProcess;
  readonly runner: NativeAgentRunner;
  private services?: HarnessServices;
  private ready?: HarnessReady;
  private starting?: Promise<void>;
  private live?: Live;
  private continuations = new Map<string, { run: HarnessRun; text: string }>();
  private seen = new Set<string>();
  private requests = new Map<string, AbortController>();
  private requestScopes = new Map<string, string>();
  private closed = false;
  private stopped = new Set<string>();
  private waiters = new Set<() => void>();
  readonly workspace: string;
  readonly conversationId: string;
  readonly configuration: HarnessConfiguration;
  private readonly ownsProcess: boolean;
  private readonly eventListener = (event: HarnessEvent): void => this.consume(event);
  private readonly failureListener = (reason: string): void => this.unknown(reason);
  constructor(readonly dir: string, configuration: HarnessConfiguration, readonly options: SecretaryHarnessOptions = {}) {
    this.conversationId = options.conversationId ?? SECRETARY_THREAD_ID;
    if (!/^[\w.-]{1,128}$/.test(this.conversationId)) throw new Error("Invalid owned conversation identity");
    this.configuration = { ...configuration, args: [...configuration.args], initialize: { ...configuration.initialize } };
    this.ownsProcess = !options.sharedProcess;
    this.ledger = new HarnessLedger(options.ledgerDir ?? dir, configuration.pluginId, configuration.upstreamVersion);
    try {
      const existing = listThreads(dir).find(t => t.id === this.conversationId);
      if (options.workspace && existing?.cwd && existing.cwd !== options.workspace && !options.preserveLegacyMetadata)
        throw new Error("Existing conversation workspace cannot be reassigned");
      if (!options.workspace) mkdirSync(projectsRoot(), { recursive: true, mode: 0o700 });
      this.workspace = options.workspace ?? existing?.cwd ?? join(realpathSync(projectsRoot()), "Yorozu Secretary");
      mkdirSync(this.workspace, { recursive: true, mode: 0o700 });
      if (realpathSync(this.workspace) !== this.workspace || lstatSync(this.workspace).isSymbolicLink()) throw new Error("Invalid secretary workspace");
      // Existing agent/session metadata belongs to its original backend and stays intact.
      createThread(options.title ?? "Yorozu", dir, this.conversationId, { agent: "harness", cwd: this.workspace });
      this.configuration.initialize.workspace = this.workspace;
      if (options.sharedProcess && (options.sharedProcess.configuration.pluginId !== configuration.pluginId
        || options.sharedProcess.configuration.upstreamVersion !== configuration.upstreamVersion
        || options.sharedProcess.configuration.initialize.workspace !== this.workspace)) throw new Error("Shared process configuration does not own this workspace");
      this.process = options.sharedProcess ?? new HarnessProcess(this.configuration);
      this.process.listeners.add(this.eventListener);
      this.process.failures.add(this.failureListener);
      this.runner = { descriptor: { id: "harness", label: options.title ?? "Yorozu", description: "Selected agent harness", needsFolder: true },
        run: turn => this.run(turn) };
    } catch (error) { this.ledger.close(); throw error; }
  }
  bind(services: HarnessServices): void {
    this.services = services;
    for (const task of Object.values(this.ledger.state.tasks)) this.project(task);
  }
  owns(id: string): boolean { return id === this.conversationId || !!this.taskForThread(id); }
  taskThread(taskId: string): string { return `harness-task-${harnessDigest([this.ledger.state.bindingId, taskId])}`; }
  private taskForThread(id: string): HarnessTask | undefined { return Object.values(this.ledger.state.tasks).find(t => this.taskThread(t.taskId) === id); }
  private taskTarget(task: HarnessTask): string { return `harness-task-start-${harnessDigest([this.ledger.state.bindingId, task.taskId, task.originRunId, task.originAttemptId])}`; }
  summary(id: string): Partial<ThreadSummary> | undefined {
    if (!this.owns(id)) return;
    const task = this.taskForThread(id);
    const capabilities = this.ready?.capabilities;
    return {
      agent: "harness", canResume: false, canRewind: false,
      harness: { pluginId: this.configuration.pluginId, backgroundTasks: capabilities?.backgroundTasks ?? false,
        targetedSteer: capabilities?.targetedSteer ?? false, taskStop: capabilities?.taskStop ?? false },
      ...(task ? { harnessTask: { taskId: task.taskId, parentThreadId: task.parentTaskId ? this.taskThread(task.parentTaskId) : this.conversationId,
        state: task.state, canSteer: task.canSteer && !!capabilities?.targetedSteer, canStop: task.canStop && !!capabilities?.taskStop },
        activeEventId: taskIsLive(task) ? this.taskTarget(task) : undefined,
        turnState: task.state === "unknown" ? "stopped-unconfirmed" : task.state === "stopping" ? "stopping" : taskIsLive(task) ? "running" : "idle" } : {}),
    };
  }
  private async start(firstEventId: string): Promise<void> {
    if (this.closed) throw new Error("Harness closed");
    if (this.starting) return this.starting;
    return this.starting = (async () => {
      // Unknown actions must never activate upstream recovery/notification continuations.
      if (Object.values(this.ledger.state.runs).some(r => r.state === "unknown")
        || Object.values(this.ledger.state.tasks).some(t => t.state === "unknown")
        || Object.values(this.ledger.state.autonomous).some(a => a.state === "unknown")
        || Object.keys(this.ledger.state.pendingResults).length) throw new Error("Previous harness outcome or result continuation is unconfirmed; execution remains held");
      this.options.beforeAdmission?.();
      const ready = await this.process.start(); this.ready = ready;
      const preference = this.services?.preferences?.();
      const timeline = this.options.historyBootstrap === false ? [] : readThreadEvents(this.conversationId, this.dir);
      const boundary = timeline.findIndex(e => e.id === firstEventId);
      const history = timeline.slice(0, boundary < 0 ? 0 : boundary).filter(e => e.kind === "message" && !e.parentAgentId)
        .slice(-20).map(e => e.kind === "message" ? { role: e.data.role, text: e.data.text.slice(0, 4000) } : undefined);
      const session = await this.process.request("session.open", { conversationId: this.conversationId, bindingId: this.ledger.state.bindingId,
        ...(this.ledger.state.sessionId ? { sessionId: this.ledger.state.sessionId } : {}),
        preferences: preference?.text ?? "Respond in the user's selected conversational language. Preserve explicit preferences; preferences are not permissions.",
        ...(preference?.language ? { language: preference.language } : {}), context: this.options.context ? JSON.stringify({ history, reference: this.options.context }) : JSON.stringify(history),
        model: this.configuration.initialize.model, provider: this.configuration.initialize.provider });
      if (!session || typeof session.sessionId !== "string" || !session.sessionId || session.sessionId.length > 512) throw new Error("Invalid harness session receipt");
      this.ledger.state.sessionId = session.sessionId;
      this.ledger.commitBinding(); this.ledger.save(); this.services?.changed();
    })().catch(async error => { if (this.ownsProcess) await this.process.close(); throw error; });
  }
  private async run(turn: NativeTurn): Promise<NativeTurnResult> {
    if (!this.owns(turn.threadId)) return { text: "This conversation does not belong to the selected harness.", failed: true };
    if (turn.cwd !== this.workspace) return { text: "The harness workspace changed; no execution was started.", failed: true };
    if (turn.attachments?.length) return { text: "This harness adapter does not support attachments yet. No input was submitted.", failed: true };
    try { this.options.beforeAdmission?.(); }
    catch (error) { return { text: `Agent admission held: ${error instanceof Error ? error.message : String(error)}`, unconfirmed: true }; }
    const marker = listThreads(this.dir).find(t => t.id === turn.threadId)?.nativeTurn;
    const eventId = marker?.userEventId;
    if (!eventId || !readThreadEvents(turn.threadId, this.dir).some(e => e.id === eventId && e.kind === "message" && e.data.role === "user"))
      return { text: "The harness requires a persisted accepted user event.", failed: true };
    const task = this.taskForThread(turn.threadId);
    if (task) {
      const receipt = await this.control("task.steer", task, eventId, turn.text);
      return { text: receipt.status === "queued" ? "Your change is queued for this task. Its result will show whether it was used."
        : receipt.reason ?? "This task cannot accept the change.", failed: receipt.status !== "queued", completed: true, cessation: "control-receipt",
        controlReceipt: { status: receipt.status as "queued" | "requested" | "rejected" | "unsupported" | "unknown", operationId: eventId } };
    }
    if (turn.signal.aborted) return { text: "No harness input was submitted.", cessation: "not-submitted" };
    try { this.options.beforeAdmission?.(); }
    catch (error) { return { text: `Agent admission held: ${error instanceof Error ? error.message : String(error)}`, unconfirmed: true }; }
    try { await this.start(eventId); }
    catch (error) { return { text: `Harness unavailable: ${error instanceof Error ? error.message : String(error)}`, failed: true, cessation: "not-submitted" }; }
    // The runtime may own a result continuation after the foreground reply ended.
    // Keep this already admitted input in the host queue until that loop settles.
    while (this.continuations.size && !turn.signal.aborted && !this.closed) {
      await new Promise<void>(resolve => {
        const wake = (): void => { this.waiters.delete(wake); turn.signal.removeEventListener("abort", wake); resolve(); };
        this.waiters.add(wake); turn.signal.addEventListener("abort", wake, { once: true });
      });
    }
    if (turn.signal.aborted) return { text: "No harness input was submitted.", cessation: "not-submitted" };
    const input = { text: turn.text, model: this.configuration.initialize.model, provider: this.configuration.initialize.provider,
      preference: this.services?.preferences?.() };
    let admission: ReturnType<HarnessLedger["begin"]>;
    try { this.options.beforeAdmission?.(); admission = this.ledger.begin(eventId, input); }
    catch (error) { return { text: `Harness admission held: ${error instanceof Error ? error.message : String(error)}`, unconfirmed: true }; }
    const { run, fresh } = admission;
    if (!fresh) return run.result ?? { text: "The prior handoff is unconfirmed. It will not be submitted again.", unconfirmed: true };
    return new Promise(resolve => {
      let admissionPending = false;
      const finish = (result: NativeTurnResult): void => {
        if (this.live?.run !== run) return;
        this.live = undefined; turn.signal.removeEventListener("abort", stop); resolve(result);
      };
      this.live = { run, turn, finish, text: "" };
      const notSubmitted = (text: string): void => {
        if (run.state !== "sending" || this.live?.run !== run) return;
        run.state = "failed"; run.result = { text, cessation: "not-submitted" };
        this.ledger.save(); finish(run.result);
      };
      const stop = (): void => {
        if (run.state === "sending" && !admissionPending) return notSubmitted("No harness input was submitted.");
        void this.stopRun(run, `stop-${run.attemptId}`).catch(() => this.unknown("Stop receipt is unconfirmed"));
      };
      turn.signal.addEventListener("abort", stop, { once: true });
      turn.onTerminate?.(stop);
      // Main follow-ups remain in the host's normal queue. Only projected task
      // subthreads expose the adapter's exact targeted-steer operation.
      void (async () => {
        const deadline = performance.now() + 30_000;
        let receipt;
        do {
          if (turn.signal.aborted || this.closed) { notSubmitted("No harness input was submitted."); return; }
          try { this.options.beforeAdmission?.(); }
          catch { notSubmitted("Agent admission changed; this input was not submitted."); return; }
          admissionPending = true;
          receipt = await this.process.request("turn.submit", { conversationId: this.conversationId, bindingId: this.ledger.state.bindingId,
            runId: run.runId, attemptId: run.attemptId, text: turn.text });
          if (receipt?.status !== "busy" || receipt.handoff !== "not-submitted") break;
          admissionPending = false;
          if (run.state !== "sending" || this.live?.run !== run) return;
          if (performance.now() >= deadline) { notSubmitted("The harness is still finishing its previous turn. This input was not submitted."); return; }
          await new Promise<void>(resolve => {
            const wake = (): void => { clearTimeout(timer); turn.signal.removeEventListener("abort", wake); resolve(); };
            const timer = setTimeout(wake, 250); turn.signal.addEventListener("abort", wake, { once: true });
          });
        } while (true);
        if (receipt?.status === "accepted") {
          if (run.state === "sending") { run.state = "running"; this.ledger.save(); }
          if (turn.signal.aborted && this.live?.run === run) stop();
        } else if ((receipt?.status === "rejected" || receipt?.status === "unsupported") && run.state === "sending") {
          run.state = "failed"; run.result = { text: receipt.reason ?? "The harness did not accept this input.", failed: true, cessation: "not-submitted" };
          this.ledger.save(); finish(run.result);
        } else if (["sending", "running"].includes(run.state)) this.unknown("The harness did not provide an admission receipt");
      })().catch(() => this.unknown("Harness handoff is unconfirmed"));
    });
  }
  private runById(runId?: string): HarnessRun | undefined { return Object.values(this.ledger.state.runs).find(r => r.runId === runId); }
  private consume(event: HarnessEvent): void {
    if (this.closed || event.conversationId !== this.conversationId || this.seen.has(event.eventId)) return;
    if (this.seen.size >= 8192) this.seen.delete(this.seen.values().next().value!);
    this.seen.add(event.eventId);
    const run = this.runById(event.runId);
    if (event.kind === "runtime.closed") { this.unknown("Harness runtime exited"); return; }
    if (event.kind === "capability.unavailable") {
      const reason = typeof event.data.reason === "string" ? event.data.reason.slice(0, 2000) : "The harness cannot provide this capability.";
      this.services?.emit({ id: `harness-capability-${harnessDigest(event.eventId)}`, threadId: this.conversationId, ts: Date.now(), agentId: "main",
        kind: "message", data: { role: "agent", text: reason, done: true, failed: true, ...(run ? { replyTo: run.eventId } : {}) } });
      return;
    }
    // Native child questions can arrive after the foreground loop has ended.
    // An unscoped request is unsupported; refuse it without fabricating an owner
    // or letting a listener exception tear down other conversations.
    if (event.kind === "request.cancel") {
      const id = event.data.requestId;
      if (typeof id === "string") { this.requests.get(id)?.abort(); this.requests.delete(id); this.requestScopes.delete(id); }
      return;
    }
    if (event.kind === "request.open" && (!run || !event.attemptId)) {
      const id = event.data.requestId;
      if (typeof id === "string" && id.length > 0 && id.length <= 512) {
        const answer = event.data.kind === "question" ? { text: "" } : { approved: false };
        void this.process.request("request.answer", { requestId: id, answer }).catch(() => {});
      }
      return;
    }
    if (!run || !event.attemptId) throw new Error("Harness event has no owned execution");
    const current = run.attemptId === event.attemptId;
    if (event.kind === "turn.started") {
      if (event.data.continuation !== true || event.data.originRunId !== run.runId || event.attemptId === run.attemptId
        || run.state !== "completed" || Object.values(this.ledger.state.tasks).some(t => t.state === "unknown")) throw new Error("Unowned harness continuation");
      if (Object.hasOwn(this.ledger.state.autonomous, event.attemptId)) throw new Error("Harness continuation identity already used");
      const resultTaskIds = event.data.resultTaskIds;
      if (resultTaskIds !== undefined && (!Array.isArray(resultTaskIds) || resultTaskIds.length > 64
        || resultTaskIds.some(id => typeof id !== "string" || this.ledger.state.tasks[id]?.originRunId !== run.runId))) throw new Error("Invalid continuation result ownership");
      this.ledger.state.autonomous[event.attemptId] = { runId: run.runId, state: "running", ...(resultTaskIds ? { resultTaskIds: resultTaskIds as string[] } : {}) }; this.ledger.save();
      this.continuations.set(event.attemptId, { run, text: "" }); return;
    }
    const continuation = this.continuations.get(event.attemptId);
    if (!current && !continuation) return;
    if (event.kind === "assistant.update") {
      if (typeof event.data.text !== "string" || event.data.text.length > 100_000) throw new Error("Invalid harness reply");
      if (continuation) { continuation.text = event.data.text; this.projectContinuation(event, continuation, false); }
      else if (this.live?.run === run) { this.live.text = event.data.text; this.live.turn.onUpdate?.(event.data.text); }
    } else if (event.kind === "turn.terminal") {
      if (typeof event.data.text !== "string" || event.data.text.length > 100_000 || !["completed", "failed", "stopped", "unknown"].includes(String(event.data.state))) throw new Error("Invalid harness terminal");
      if (continuation) {
        const confirmed = event.data.cessation === "provider-terminal" && event.data.state !== "unknown";
        this.ledger.state.autonomous[event.attemptId].state = confirmed ? event.data.state as "completed" | "failed" | "stopped" : "unknown";
        if (confirmed) for (const id of this.ledger.state.autonomous[event.attemptId].resultTaskIds ?? []) delete this.ledger.state.pendingResults[id];
        this.ledger.save(); continuation.text = event.data.text; this.projectContinuation(event, continuation, true); this.continuations.delete(event.attemptId);
        for (const wake of [...this.waiters]) wake(); return;
      }
      if (!["running", "sending"].includes(run.state)) return;
      const confirmed = event.data.cessation === "provider-terminal" && event.data.state !== "unknown";
      run.state = confirmed ? event.data.state as HarnessRun["state"] : "unknown";
      run.result = { text: event.data.text, ...(confirmed ? { cessation: "provider-terminal" as const } : { unconfirmed: true as const }),
        ...(run.state === "completed" ? { completed: true as const } : {}), ...(run.state === "failed" ? { failed: true } : {}) };
      this.ledger.save(); this.live?.run === run && this.live.finish(run.result);
    } else if (event.kind === "task.changed") {
      if (!validHarnessTask(event.data) || event.data.originRunId !== run.runId) throw new Error("Invalid harness task scope");
      const existing = this.ledger.state.tasks[event.data.taskId];
      if (existing && (existing.originRunId !== event.data.originRunId || existing.parentTaskId !== event.data.parentTaskId
        || existing.originAttemptId !== event.attemptId)) throw new Error("Harness task identity conflict");
      const task = { ...event.data, originAttemptId: event.attemptId };
      this.ledger.state.tasks[event.data.taskId] = task;
      if (!event.data.parentTaskId && ["completed", "failed", "stopped"].includes(event.data.state)
        && (!existing || taskIsLive(existing))) this.ledger.state.pendingResults[event.data.taskId] = run.runId;
      this.ledger.save(); this.project(task); this.services?.changed();
    } else if (event.kind === "request.open") {
      void this.answerRequest(event, run).catch(() => this.unknown("Harness question receipt is unconfirmed"));
    }
  }
  private projectContinuation(event: HarnessEvent, continuation: { run: HarnessRun; text: string }, done: boolean): void {
    this.services?.emit({ id: `harness-result-${harnessDigest([this.ledger.state.bindingId, event.attemptId])}`, threadId: this.conversationId,
      ts: Date.now(), agentId: "main", kind: "message", data: { role: "agent", text: continuation.text, replyTo: continuation.run.eventId,
        done, ...(done && event.data.state !== "completed" ? { failed: true } : {}) } });
  }
  private project(task: HarnessTask): void {
    const run = this.runById(task.originRunId); if (!run || !this.services) return;
    const threadId = this.taskThread(task.taskId);
    createThread(task.title.slice(0, 200), this.dir, threadId, { agent: "harness", cwd: this.workspace });
    const target = this.taskTarget(task);
    if (!readThreadEvents(threadId, this.dir).some(e => e.id === target)) this.services.emit({ id: target, threadId, ts: Date.now(),
      agentId: "main", kind: "message", data: { role: "user", text: task.title } });
    const done = !taskIsLive(task) || task.state === "unknown";
    const text = task.text || (task.state === "unknown" ? "The task outcome is unconfirmed. It will not run again automatically."
      : task.state === "waiting" ? "Your answer is needed." : task.state === "stopping" ? "Stopping…"
      : task.state === "stopped" ? "Stopped." : done ? "No result was reported." : "Working…");
    const metadata = { ...this.summary(threadId)?.harnessTask!, threadId };
    const data = { role: "agent" as const, text, done, harnessTask: metadata,
      ...(task.state === "failed" || task.state === "unknown" ? { failed: true } : {}), ...(task.state === "stopped" ? { interrupted: true } : {}) };
    this.services.emit({ id: `harness-task-card-${harnessDigest([this.ledger.state.bindingId, task.taskId])}`, threadId: this.conversationId,
      ts: readThreadEvents(this.conversationId, this.dir).find(e => e.id === run.eventId)?.ts ?? Date.now(),
      agentId: task.title.slice(0, 100), parentAgentId: "main", kind: "message", data: { ...data, replyTo: run.eventId } });
    this.services.emit({ id: `harness-task-result-${harnessDigest([this.ledger.state.bindingId, task.taskId])}`, threadId, ts: Date.now(),
      agentId: "main", kind: "message", data: { ...data, replyTo: target } });
  }
  private async answerRequest(event: HarnessEvent, run: HarnessRun): Promise<void> {
    const d = event.data; if (typeof d.requestId !== "string" || this.requests.has(d.requestId)) return;
    const abort = new AbortController(); this.requests.set(d.requestId, abort);
    const requestKey = JSON.stringify([run.runId, event.attemptId]); this.requestScopes.set(d.requestId, requestKey);
    const live = this.live?.run === run ? this.live : undefined;
    const signal = live ? AbortSignal.any([live.turn.signal, abort.signal]) : abort.signal;
    let answer: { approved?: boolean; text?: string; result?: HarnessHandoffResult } = { approved: false };
    const identity: HarnessHandoffIdentity = { conversationId: this.conversationId, bindingId: this.ledger.state.bindingId,
      runId: run.runId, attemptId: event.attemptId!, requestId: d.requestId };
    // Never widen native access, collect secrets, or make persistent upstream grants.
    if (d.kind === "approval" && typeof d.tool === "string" && d.input && typeof d.input === "object" && live)
      answer = { approved: await live.turn.approve?.(d.tool, d.input as Record<string, unknown>, signal) ?? false };
    else if (d.kind === "question" && typeof d.question === "string" && Array.isArray(d.options) && d.options.every(o => typeof o === "string") && live)
      answer = { text: await live.turn.ask?.(d.question, d.options as string[], signal) };
    else if (d.kind === "team-delegate") {
      answer = { result: { status: "rejected", text: "Scoped persistent-agent execution is unsupported by this host." } };
      if (d.input && typeof d.input === "object" && !Array.isArray(d.input) && this.services?.handoff && !this.stopped.has(requestKey)) {
        const input = d.input as unknown as HarnessHandoffInput;
        if (typeof input.teammateId === "string" && typeof input.context === "string" && input.context.length <= 32_768
          && typeof input.expectedResult === "string" && input.expectedResult.length <= 8192 && input.scope && typeof input.scope === "object") {
          const timeout = new AbortController(); const timer = setTimeout(() => timeout.abort(), 120_000);
          const bounded = AbortSignal.any([signal, timeout.signal]);
          let cancel: (() => void) | undefined;
          try {
            const stopped = new Promise<HarnessHandoffResult>(resolve => {
              if (bounded.aborted) return resolve({ status: "unknown", text: "Handoff stopped or timed out; no automatic retry." });
              cancel = () => resolve({ status: "unknown", text: "Handoff stopped or timed out; no automatic retry." });
              bounded.addEventListener("abort", cancel, { once: true });
            });
            const result = await Promise.race([this.services.handoff(identity, input, bounded), stopped]);
            if (!["completed", "failed", "unknown", "rejected"].includes(result.status)
              || result.text !== undefined && (typeof result.text !== "string" || result.text.length > 32_768)
              || result.taskId !== undefined && (typeof result.taskId !== "string" || result.taskId.length > 128)) throw new Error("Invalid scoped handoff result");
            answer = { result };
          } catch { answer = { result: { status: "unknown", text: "Handoff outcome is unconfirmed; no automatic retry." } }; }
          finally { clearTimeout(timer); if (cancel) bounded.removeEventListener("abort", cancel); }
        }
      }
    }
    if (!signal.aborted && !this.stopped.has(requestKey) && this.requests.get(d.requestId) === abort)
      await this.process.request("request.answer", { ...(d.kind === "team-delegate" ? identity : { requestId: d.requestId }), answer });
    this.requests.delete(d.requestId); this.requestScopes.delete(d.requestId);
    this.services?.changed();
  }
  private async control(method: "task.steer" | "task.stop", task: HarnessTask, operationId: string, text?: string): Promise<Omit<HarnessReceipt, "status"> & { status: HarnessReceipt["status"] | "unknown" }> {
    const run = this.runById(task.originRunId);
    // A delivery receipt remains the receipt after the task settles. Validate
    // the original identity before returning it; never resend an old operation.
    if (run && task.originAttemptId && Object.hasOwn(this.ledger.state.controls, operationId))
      return this.controlRun(method, run, operationId, text, task.taskId, task.originAttemptId);
    if (!run || !["running", "waiting"].includes(task.state) || method === "task.steer" && !task.canSteer || method === "task.stop" && !task.canStop)
      return { status: "rejected", reason: "This task is not accepting that control." };
    if (!task.originAttemptId) return { status: "rejected", reason: "The task attempt identity is unavailable." };
    return this.controlRun(method, run, operationId, text, task.taskId, task.originAttemptId);
  }
  private async controlRun(method: string, run: HarnessRun, operationId: string, text?: string, taskId?: string, attemptId = run.attemptId): Promise<any> {
    const input = { conversationId: this.conversationId, bindingId: this.ledger.state.bindingId, runId: run.runId, attemptId,
      operationId, ...(taskId ? { taskId } : {}), ...(text ? { text } : {}) };
    const { record, fresh } = this.ledger.control(operationId, { method, ...input });
    if (!fresh) return { status: record.state === "sending" ? "unknown" : record.state, reason: record.reason };
    try {
      const receipt = await this.process.request(method, input);
      if (!receipt || !["queued", "requested", "rejected", "unsupported", "unknown"].includes(receipt.status)) throw new Error("Invalid harness control receipt");
      record.state = receipt.status; record.reason = receipt.reason; this.ledger.save(); this.services?.changed(); return receipt;
    } catch { record.state = "unknown"; this.ledger.save(); this.services?.changed(); return { status: "unknown", reason: "Control delivery is unconfirmed. It will not be sent again automatically." }; }
  }
  private stopRun(run: HarnessRun, operationId: string, attemptId = run.attemptId): Promise<any> {
    const key = JSON.stringify([run.runId, attemptId]); this.stopped.add(key);
    for (const [id, scope] of this.requestScopes) if (scope === key) this.requests.get(id)?.abort();
    return this.controlRun("run.stop", run, operationId, undefined, undefined, attemptId);
  }
  canHandoff(identity: HarnessHandoffIdentity): boolean {
    const key = JSON.stringify([identity.runId, identity.attemptId]);
    return !this.closed && identity.conversationId === this.conversationId && identity.bindingId === this.ledger.state.bindingId
      && this.requests.has(identity.requestId) && this.requestScopes.get(identity.requestId) === key && !this.stopped.has(key)
      && (this.live?.run.runId === identity.runId && this.live.run.attemptId === identity.attemptId
        || this.continuations.get(identity.attemptId)?.run.runId === identity.runId);
  }
  get hasUnconfirmedExecution(): boolean {
    return Object.values(this.ledger.state.runs).some(r => r.state === "unknown")
      || Object.values(this.ledger.state.tasks).some(t => t.state === "unknown")
      || Object.values(this.ledger.state.controls).some(c => c.state === "unknown")
      || Object.values(this.ledger.state.autonomous).some(a => a.state === "unknown");
  }
  get idleConfirmed(): boolean {
    return !this.live && !this.continuations.size && !this.requests.size && !this.hasUnconfirmedExecution
      && !Object.values(this.ledger.state.runs).some(r => ["sending", "running"].includes(r.state))
      && !Object.values(this.ledger.state.tasks).some(taskIsLive)
      && !Object.values(this.ledger.state.controls).some(c => c.state === "sending")
      && !Object.values(this.ledger.state.autonomous).some(a => a.state === "running")
      && !Object.keys(this.ledger.state.pendingResults).length;
  }
  async stop(operationId: string): Promise<void> {
    if (this.live) await this.stopRun(this.live.run, operationId);
    for (const [attemptId, continuation] of this.continuations) await this.stopRun(continuation.run, `${operationId}-${attemptId}`, attemptId);
  }
  async taskStop(event: YorozuEvent): Promise<boolean> {
    const task = this.taskForThread(event.threadId); if (!task || event.kind !== "interrupt") return false;
    const target = event.data.targetEventId;
    const receipt = target === this.taskTarget(task) ? await this.control("task.stop", task, event.id) : { status: "rejected", reason: "The task target is stale." };
    const current = this.ledger.state.tasks[task.taskId];
    if (receipt.status === "requested" && current?.originAttemptId === task.originAttemptId && ["running", "waiting"].includes(current.state)) {
      current.state = "stopping"; this.ledger.save(); this.project(current);
    }
    this.services?.emit({ id: `harness-control-${harnessDigest(event.id)}`, threadId: event.threadId, ts: Date.now(), agentId: "main", kind: "message",
      data: { role: "agent", text: receipt.status === "requested" ? "Stop requested. Waiting for execution to settle." : receipt.reason ?? "Stop is unavailable for this task.", done: true,
        controlReceipt: { status: receipt.status as "requested" | "rejected" | "unsupported" | "unknown", operationId: event.id } } });
    this.services?.changed(); return true;
  }
  private unknown(reason: string): void {
    for (const r of Object.values(this.ledger.state.runs)) if (["sending", "running"].includes(r.state)) {
      r.state = "unknown"; r.result = { text: `${reason}. The outcome is unconfirmed and will not run again automatically.`, unconfirmed: true };
    }
    for (const task of Object.values(this.ledger.state.tasks)) if (taskIsLive(task)) { task.state = "unknown"; task.canSteer = false; task.canStop = false; }
    for (const a of Object.values(this.ledger.state.autonomous)) if (a.state === "running") a.state = "unknown";
    this.continuations.clear(); for (const wake of [...this.waiters]) wake();
    if (this.ledger.committed) this.ledger.save();
    for (const task of Object.values(this.ledger.state.tasks)) this.project(task);
    for (const request of this.requests.values()) request.abort(); this.requests.clear(); this.requestScopes.clear();
    if (this.live) this.live.finish(this.live.run.result ?? { text: reason, unconfirmed: true });
    this.services?.changed();
  }
  async close(): Promise<void> {
    if (this.closed) return;
    try {
      if (this.live) await this.stopRun(this.live.run, `close-${randomUUID()}`).catch(() => {});
      if (this.ownsProcess) await this.process.close(); this.unknown("Harness host closed");
    } finally {
      this.closed = true; this.process.listeners.delete(this.eventListener); this.process.failures.delete(this.failureListener); this.ledger.close();
    }
  }
}

/** Local opt-in only. Selection cannot come from a model/tool or untrusted peer. */
export function harnessConfiguration(dir: string, env = process.env): HarnessConfiguration | undefined {
  const id = env.YOROZU_HARNESS_PLUGIN;
  if (!id) return;
  if (id !== "hermes") throw new Error(`Unsupported harness plugin: ${id}`);
  const python = env.YOROZU_HERMES_PYTHON; const sourcePath = env.YOROZU_HERMES_SOURCE;
  if (!python || !sourcePath || !existsSync(python) || !existsSync(sourcePath)) throw new Error("Hermes requires explicit pinned Python and source paths");
  return { pluginId: "hermes", command: process.execPath, args: [fileURLToPath(new URL("../../harness-plugins/hermes/adapter.mjs", import.meta.url))],
    upstreamVersion: "0.21.5", initialize: { python: resolve(python), sourcePath: resolve(sourcePath), upstreamVersion: "0.21.5",
      profileRoot: join(resolve(dir), "harness-v1", "profiles", "hermes"),
      ...(env.YOROZU_HERMES_PROVIDER_CONFIG ? { providerConfigPath: resolve(env.YOROZU_HERMES_PROVIDER_CONFIG) } : {}) } };
}
