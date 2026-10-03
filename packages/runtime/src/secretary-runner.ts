/** Additive production adapter. Only the fixed secretary thread uses the Rust ledger. */
import { spawn, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { closeSync, existsSync, lstatSync, mkdirSync, openSync, readSync, realpathSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { createInterface } from "node:readline";
import { createThread, listThreads, readThreadEvents } from "./threads.js";
import { projectsRoot } from "./projects.js";
import type { NativeAgentRunner, NativeTurn, NativeTurnResult } from "./native.js";

export const SECRETARY_THREAD_ID = "yorozu-secretary-v1";
export const secretaryHost = (): string => {
  const bundled = fileURLToPath(new URL("../../yorozu-alpha-host", import.meta.url));
  return process.env.YOROZU_SECRETARY_HOST ?? (existsSync(bundled) ? bundled : fileURLToPath(new URL("../../host-core/target/debug/yorozu-alpha-host", import.meta.url)));
};
const workerScript = (): string => fileURLToPath(new URL("./secretary-worker.js", import.meta.url));

export function prepareSecretary(dir: string, threadId = SECRETARY_THREAD_ID): { root: string; workspace: string } {
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  mkdirSync(projectsRoot(), { recursive: true, mode: 0o700 });
  if (threadId !== SECRETARY_THREAD_ID && !/^secretary-task-[a-f0-9]{64}$/.test(threadId)) throw new Error("Invalid secretary task identity");
  const task = threadId !== SECRETARY_THREAD_ID;
  const stateParent = task ? join(realpathSync(dir), "secretary-tasks-v1", threadId) : realpathSync(dir);
  const workParent = task ? join(realpathSync(projectsRoot()), "Yorozu Secretary Tasks", threadId) : realpathSync(projectsRoot());
  for (const parent of [stateParent, workParent]) {
    mkdirSync(parent, { recursive: true, mode: 0o700 });
    if (realpathSync(parent) !== parent) throw new Error("Secretary task parent must not be a symlink");
  }
  const root = join(stateParent, "secretary-v1");
  const workspace = join(workParent, "Yorozu Secretary");
  const existing = listThreads(dir).find((thread) => thread.id === threadId);
  if (existing && (existing.agent !== "codex" || existing.cwd !== workspace)) throw new Error("Secretary thread identity conflicts with existing data");
  const prepared = spawnSync(secretaryHost(), ["--secretary-init", root, workspace], { encoding: "utf8", timeout: 10000 });
  if (prepared.error) throw new Error(`Secretary host could not start (${(prepared.error as NodeJS.ErrnoException).code ?? "unknown error"})`);
  if (prepared.status !== 0) throw new Error("The host refused the dedicated secretary profile or workspace");
  createThread(task ? "Secretary task" : "Yorozu", dir, threadId, { agent: "codex", cwd: workspace });
  return { root, workspace };
}

export function secretaryRunner(dir: string, ordinaryCodex: NativeAgentRunner,
  onUnavailable = (reason: string): void => { process.stdout.write(`STATE secretary-unavailable ${reason}\n`); }): NativeAgentRunner {
  let prepared: ReturnType<typeof prepareSecretary>;
  try { prepared = prepareSecretary(dir); }
  catch (error) {
    const reason = `Secretary unavailable: ${error instanceof Error ? error.message : String(error)}`.replace(/[\r\n]+/g, " ");
    onUnavailable(reason);
    return { ...ordinaryCodex, run: (turn) => turn.threadId === SECRETARY_THREAD_ID
      ? Promise.resolve({ text: reason, failed: true }) : ordinaryCodex.run(turn) };
  }
  const { root, workspace } = prepared;
  return { ...ordinaryCodex, async run(turn) {
    if (turn.threadId !== SECRETARY_THREAD_ID) return ordinaryCodex.run(turn);
    if (turn.cwd !== workspace) throw new Error("Secretary workspace changed");
    const marker = listThreads(dir).find((thread) => thread.id === SECRETARY_THREAD_ID)?.nativeTurn;
    const eventId = marker?.userEventId;
    if (!eventId || !readThreadEvents(SECRETARY_THREAD_ID, dir).some((event) => event.id === eventId && event.kind === "message" && event.data.role === "user")) {
      throw new Error("Secretary requires a persisted accepted user event");
    }
    const runId = createHash("sha256").update(`${SECRETARY_THREAD_ID}\0${eventId}`).digest("hex");
    return runSecretary(root, workspace, runId, turn);
  } };
}

/** Rust admission, rather than a client message field, proves this run had no execution tools. */
export function secretaryPlanningOnly(dir: string, eventId: string): boolean {
  const runId = createHash("sha256").update(`${SECRETARY_THREAD_ID}\0${eventId}`).digest("hex");
  let fd: number | undefined;
  try {
    fd = openSync(join(dir, "secretary-v1", "runs", runId, "state", "threads", "alpha-main-v1.jsonl"), "r");
    // Admission is the first Rust record, bounded by its 64 KiB frame budget.
    const buffer = Buffer.alloc(128 * 1024);
    const bytes = readSync(fd, buffer, 0, buffer.length, 0);
    const lineEnd = buffer.subarray(0, bytes).indexOf(10);
    if (lineEnd < 0) return false;
    const record = JSON.parse(buffer.subarray(0, lineEnd).toString("utf8"));
    return record.kind === "alpha_event" && record.data?.runId === runId && record.data.kind === "accepted" && record.data.data?.secretaryCoordinator === true;
  } catch { return false; }
  finally { if (fd !== undefined) closeSync(fd); }
}

type LedgerEvent = { seq: number; runId: string; kind: string; text?: string; data?: Record<string, any> };
export function runSecretary(root: string, workspace: string, runId: string, turn: NativeTurn): Promise<NativeTurnResult> {
  return new Promise((resolve) => {
    const runAbsent = (): boolean => {
      try { lstatSync(join(root, "runs", runId)); return false; }
      catch (error) { return (error as NodeJS.ErrnoException).code === "ENOENT"; }
    };
    const absentBefore = runAbsent();
    let emptySnapshot = false;
    let submitted = false;
    const host = spawn(secretaryHost(), ["--secretary", root, runId, workspace, process.execPath, workerScript()], { stdio: ["pipe", "pipe", "ignore"] });
    const lines = createInterface({ input: host.stdout });
    let settled = false;
    let resultToDeliver: NativeTurnResult | undefined;
    let exited = false;
    let lastSeq = 0;
    let sessionId = turn.sessionId;
    let stopping: ReturnType<typeof setTimeout> | undefined;
    let nextId = 0;
    const steering = new Map<string, { deliveryId: string; finish(accepted?: boolean): void }>();
    const callbacks = new AbortController();
    const signal = AbortSignal.any([turn.signal, callbacks.signal]);
    const deliver = (result: NativeTurnResult): void => {
      // Only after host/stdio closure: a competing owner may have created this run meanwhile.
      if (!submitted && (emptySnapshot || absentBefore && runAbsent())) {
        resolve({ text: "The task did not start; no Codex turn was submitted.", sessionId,
          failed: !turn.signal.aborted, cessation: "process-exited" });
      } else resolve(result);
    };
    const write = (op: string, data: Record<string, unknown> = {}): string => {
      const id = String(++nextId);
      if (!host.stdin.destroyed) host.stdin.write(`${JSON.stringify({ version: 1, id, op, runId, ...data })}\n`);
      return id;
    };
    const finish = (result: NativeTurnResult): void => {
      if (settled) return;
      settled = true; callbacks.abort(); turn.signal.removeEventListener("abort", stop); clearTimeout(stopping);
      for (const pending of steering.values()) pending.finish();
      resultToDeliver = result;
      host.stdin.end(); lines.close(); host.stdout.resume();
      // Release the shared workspace lock before the baseline queue starts another turn.
      if (exited) deliver(result);
      else stopping = setTimeout(() => { host.kill(); }, 15000);
    };
    const uncertain = (): void => finish({ text: "The secretary outcome is unconfirmed. This request will not run again automatically.", sessionId, unconfirmed: true });
    const stop = (): void => {
      write("stop");
      stopping ??= setTimeout(() => { host.kill(); uncertain(); }, 15000);
    };
    turn.signal.addEventListener("abort", stop, { once: true });
    turn.onTerminate?.(stop);
    turn.onSteer?.((text, attachments, deliveryId) => {
      if (!deliveryId || !submitted || settled || signal.aborted) return Promise.resolve(false);
      deliveryId = createHash("sha256").update(deliveryId).digest("hex");
      return new Promise<boolean>((resolve, reject) => {
        const id = String(nextId + 1);
        const timer = setTimeout(() => finish(), 35000);
        const finish = (accepted?: boolean): void => {
          if (!steering.delete(id)) return;
          clearTimeout(timer);
          if (accepted === undefined) reject(new Error("Steer receipt is unconfirmed; do not resend"));
          else resolve(accepted);
        };
        steering.set(id, { deliveryId, finish });
        write("steer", { deliveryId, text, attachments });
      });
    });
    host.once("error", () => uncertain());
    host.stdin.on("error", () => uncertain());
    // close follows exit/spawn failure and drains all buffered terminal frames first.
    host.once("close", () => {
      exited = true; clearTimeout(stopping);
      if (!settled) uncertain();
      else if (resultToDeliver) deliver(resultToDeliver);
    });
    const respond = (requestId: unknown, value: unknown): void => {
      if (!settled && typeof requestId === "string") write("respond", { requestId, value: value ?? null });
    };
    const consume = async (event: LedgerEvent, replay = false): Promise<void> => {
      if (event.runId !== runId || event.seq <= lastSeq) return;
      lastSeq = event.seq;
      const data = event.data ?? {};
      if (event.kind === "session" && typeof data.sessionId === "string") {
        sessionId = data.sessionId;
        turn.onSession?.(sessionId);
        if (!replay) respond(data.requestId, true);
      } else if (event.kind === "update") turn.onUpdate?.(event.text ?? "");
      else if (event.kind === "activity" && typeof data.id === "string" && data.payload) turn.onActivity?.(data.id, data.payload);
      else if (event.kind === "tool_boundary") turn.onToolBoundary?.();
      else if (event.kind === "steer_result") {
        const pending = [...steering.values()].find((entry) => entry.deliveryId === data.deliveryId);
        pending?.finish(typeof data.accepted === "boolean" ? data.accepted : undefined);
      }
      else if (event.kind === "request" && !replay) {
        let value: unknown;
        if (data.type === "approve") value = await turn.approve?.(data.tool, data.input, signal) ?? false;
        else if (data.type === "ask") value = await turn.ask?.(data.question, data.options, signal);
        else if (data.type === "beforeTool") value = await turn.beforeTool?.(signal) ?? true;
        respond(data.requestId, value);
      } else if (["completed", "stopped", "unconfirmed"].includes(event.kind)) {
        const interrupted = event.kind === "stopped" && replay && !turn.signal.aborted && data.failed !== true;
        const text = [event.text, ...(interrupted ? ["Stopped before completion (Yorozu closed or restarted). This task will not run again automatically."] : [])].filter(Boolean).join("\n");
        finish({ text, sessionId,
          ...(event.kind === "unconfirmed" ? { unconfirmed: true as const } : {}),
          ...(event.kind === "stopped" && (data.failed === true || !turn.signal.aborted) ? { failed: true } : {}),
          ...(event.kind === "completed" ? { completed: true, cessation: "provider-terminal" as const } : {}),
          ...(event.kind === "stopped" && ["provider-terminal", "process-exited"].includes(data.evidence) ? { cessation: data.evidence } : {}) });
      }
    };
    lines.on("line", (line) => {
      try {
        if (Buffer.byteLength(line) > 1024 * 1024) throw new Error("Invalid secretary frame");
        const packet = JSON.parse(line);
        if (packet.version !== 1) throw new Error("Invalid secretary protocol");
        if (packet.event) void consume(packet.event).catch(() => { stop(); });
        else if (packet.id === "1") {
          const events: LedgerEvent[] = packet.result?.events;
          if (!Array.isArray(events)) throw new Error("Invalid secretary snapshot");
          void (async () => {
            for (const event of events) await consume(event, true);
            if (settled) return;
            if (events.length) { uncertain(); return; }
            emptySnapshot = true;
            if (turn.signal.aborted) { finish({ text: "", sessionId }); return; }
            const metadata = Object.fromEntries(["sessionId", "model", "effort", "attachments", "skill", "secretaryCoordinator"]
              .flatMap((key) => turn[key as keyof NativeTurn] === undefined ? [] : [[key, turn[key as keyof NativeTurn]]]));
            submitted = true;
            write("submit", { text: turn.text, turn: metadata });
          })().catch(() => { stop(); uncertain(); });
        } else if (steering.has(packet.id)) {
          const pending = steering.get(packet.id)!;
          if (packet.result?.submitted === false) pending.finish(false);
          else if (packet.result?.error || packet.result?.replayed === true) pending.finish();
        } else if (packet.result?.error) {
          finish({ text: `The secretary could not accept this task (${String(packet.result.error)}).`, sessionId, failed: true });
        }
      } catch { stop(); uncertain(); }
    });
    write("snapshot");
  });
}
