/** Additive production adapter. Only the fixed secretary thread uses the Rust ledger. */
import { spawn, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, realpathSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { createInterface } from "node:readline";
import { createThread, listThreads, readThreadEvents } from "./threads.js";
import { projectsRoot } from "./projects.js";
import type { NativeAgentRunner, NativeTurn, NativeTurnResult } from "./native.js";

export const SECRETARY_THREAD_ID = "yorozu-secretary-v1";
const secretaryHost = (): string => {
  const bundled = fileURLToPath(new URL("../../yorozu-alpha-host", import.meta.url));
  return process.env.YOROZU_SECRETARY_HOST ?? (existsSync(bundled) ? bundled : fileURLToPath(new URL("../../host-core/target/debug/yorozu-alpha-host", import.meta.url)));
};
const workerScript = (): string => fileURLToPath(new URL("./secretary-worker.js", import.meta.url));

function prepareSecretary(dir: string): { root: string; workspace: string } {
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  mkdirSync(projectsRoot(), { recursive: true, mode: 0o700 });
  const root = join(realpathSync(dir), "secretary-v1");
  const workspace = join(realpathSync(projectsRoot()), "Yorozu Secretary");
  const existing = listThreads(dir).find((thread) => thread.id === SECRETARY_THREAD_ID);
  if (existing && (existing.agent !== "codex" || existing.cwd !== workspace)) throw new Error("Secretary thread identity conflicts with existing data");
  const prepared = spawnSync(secretaryHost(), ["--secretary-init", root, workspace], { encoding: "utf8", timeout: 10000 });
  if (prepared.error) throw new Error(`Secretary host could not start (${(prepared.error as NodeJS.ErrnoException).code ?? "unknown error"})`);
  if (prepared.status !== 0) throw new Error("The host refused the dedicated secretary profile or workspace");
  createThread("Yorozu", dir, SECRETARY_THREAD_ID, { agent: "codex", cwd: workspace });
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
    // Existing queue owns later messages; no uncertain live steering is acknowledged.
    turn.onSteer?.(async () => false);
    return runSecretary(root, workspace, runId, turn);
  } };
}

type LedgerEvent = { seq: number; runId: string; kind: string; text?: string; data?: Record<string, any> };
function runSecretary(root: string, workspace: string, runId: string, turn: NativeTurn): Promise<NativeTurnResult> {
  return new Promise((resolve) => {
    const host = spawn(secretaryHost(), ["--secretary", root, runId, workspace, process.execPath, workerScript()], { stdio: ["pipe", "pipe", "ignore"] });
    const lines = createInterface({ input: host.stdout });
    let settled = false;
    let resultToDeliver: NativeTurnResult | undefined;
    let exited = false;
    let lastSeq = 0;
    let sessionId = turn.sessionId;
    let stopping: ReturnType<typeof setTimeout> | undefined;
    let nextId = 0;
    const callbacks = new AbortController();
    const signal = AbortSignal.any([turn.signal, callbacks.signal]);
    const write = (op: string, data: Record<string, unknown> = {}): void => {
      if (!host.stdin.destroyed) host.stdin.write(`${JSON.stringify({ version: 1, id: String(++nextId), op, runId, ...data })}\n`);
    };
    const finish = (result: NativeTurnResult): void => {
      if (settled) return;
      settled = true; callbacks.abort(); turn.signal.removeEventListener("abort", stop); clearTimeout(stopping);
      resultToDeliver = result;
      host.stdin.end(); lines.close();
      // Release the shared workspace lock before the baseline queue starts another turn.
      if (exited) resolve(result);
      else stopping = setTimeout(() => { host.kill(); }, 15000);
    };
    const uncertain = (): void => finish({ text: "The secretary outcome is unconfirmed. This accepted task will not run again automatically.", sessionId, unconfirmed: true });
    const stop = (): void => {
      write("stop");
      stopping ??= setTimeout(() => { host.kill(); uncertain(); }, 15000);
    };
    turn.signal.addEventListener("abort", stop, { once: true });
    turn.onTerminate?.(stop);
    host.once("error", () => { exited = true; uncertain(); });
    host.stdin.on("error", () => uncertain());
    host.once("exit", () => {
      exited = true; clearTimeout(stopping);
      if (!settled) uncertain();
      else if (resultToDeliver) resolve(resultToDeliver);
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
          ...(event.kind === "stopped" && (data.failed === true || interrupted) ? { failed: true } : {}),
          ...(event.kind === "completed" ? { completed: true, cessation: "provider-terminal" as const } : {}),
          ...(event.kind === "stopped" && ["provider-terminal", "process-exited"].includes(data.evidence) ? { cessation: data.evidence } : {}) });
      }
    };
    lines.on("line", (line) => {
      try {
        if (Buffer.byteLength(line) > 1024 * 1024) throw new Error("Invalid secretary frame");
        const packet = JSON.parse(line);
        if (packet.version !== 1) throw new Error("Invalid secretary protocol");
        if (packet.event) void consume(packet.event).catch(() => { stop(); uncertain(); });
        else if (packet.id === "1") {
          const events: LedgerEvent[] = packet.result?.events;
          if (!Array.isArray(events)) throw new Error("Invalid secretary snapshot");
          void (async () => {
            for (const event of events) await consume(event, true);
            if (settled) return;
            if (events.length) { uncertain(); return; }
            if (turn.signal.aborted) { finish({ text: "", sessionId }); return; }
            const metadata = Object.fromEntries(["sessionId", "model", "effort", "attachments", "skill"]
              .flatMap((key) => turn[key as keyof NativeTurn] === undefined ? [] : [[key, turn[key as keyof NativeTurn]]]));
            write("submit", { text: turn.text, turn: metadata });
          })().catch(() => { stop(); uncertain(); });
        } else if (packet.result?.error) {
          finish({ text: `The secretary could not accept this task (${String(packet.result.error)}).`, sessionId, failed: true });
        }
      } catch { stop(); uncertain(); }
    });
    write("snapshot");
  });
}
