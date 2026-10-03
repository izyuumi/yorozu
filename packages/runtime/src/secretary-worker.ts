/** One admitted secretary turn. Rust owns its ledger; the reviewed adapter owns Codex. */
import { createInterface } from "node:readline";
import { codexNativeRunner, connectCodex } from "./codex-native.js";
import { realpathSync } from "node:fs";
import type { NativeTurn } from "./native.js";

const lines = createInterface({ input: process.stdin });
const abort = new AbortController();
let runId = "";
let terminate: (() => void) | undefined;
let steer: Parameters<NonNullable<NativeTurn["onSteer"]>>[0] | undefined;
let steering = Promise.resolve();
let nextRequest = 0;
let detailCount = 0;
let lastUpdateAt = -Infinity;
const pending = new Map<string, (value: unknown) => void>();
const clipped = (text: string): string => {
  let result = text.slice(0, 16000);
  while (Buffer.byteLength(JSON.stringify(result)) > 48000) result = result.slice(0, Math.floor(result.length * 0.8));
  return result.length < text.length ? `${result}\n[Reply truncated; the Codex session retains its context.]` : result;
};
function emit(kind: string, text?: string, data?: unknown): boolean {
  const frame = JSON.stringify({ version: 1, runId, kind, text, data });
  if (Buffer.byteLength(frame) > 60 * 1024) return false;
  process.stdout.write(`${frame}\n`);
  return true;
}
function request(type: string, data: Record<string, unknown>, signal = abort.signal): Promise<unknown> {
  if (signal.aborted || nextRequest >= 512) return Promise.resolve(undefined);
  const requestId = String(++nextRequest);
  return new Promise((resolve) => {
    const finish = (value?: unknown): void => {
      pending.delete(requestId); clearTimeout(timer); signal.removeEventListener("abort", cancelled); resolve(value);
    };
    const cancelled = (): void => finish();
    const timer = setTimeout(cancelled, type === "session" ? 30000 : 24 * 60 * 60 * 1000);
    pending.set(requestId, finish);
    signal.addEventListener("abort", cancelled, { once: true });
    if (!emit(type === "session" ? "session" : "request", undefined, { ...data, type, requestId })) finish();
  });
}
lines.on("line", (line) => {
  try {
    if (Buffer.byteLength(line) > 1024 * 1024) throw new Error("large frame");
    const packet = JSON.parse(line);
    if (packet.version !== 1 || typeof packet.runId !== "string") throw new Error("invalid frame");
    if (packet.runId === runId && packet.op === "respond") { pending.get(packet.requestId)?.(packet.value); return; }
    if (packet.runId === runId && packet.op === "stop") { abort.abort(); return; }
    if (packet.runId === runId && packet.op === "steer") {
      // Rust validates and journals the immutable delivery before forwarding it.
      steering = steering.then(async () => {
        let accepted: boolean | null = false;
        try { if (steer && !abort.signal.aborted) accepted = await steer(packet.text, packet.attachments, packet.deliveryId); }
        catch { accepted = null; }
        // This is a provider receipt, never evidence that the model applied the change.
        emit("steer_result", undefined, { deliveryId: packet.deliveryId, accepted });
      });
      return;
    }
    if (runId || packet.op !== "run" || packet.secretary !== true || typeof packet.cwd !== "string" || typeof packet.text !== "string") throw new Error("invalid admission");
    runId = packet.runId;
    void run(packet.cwd, packet.text, packet.turn).finally(() => { abort.abort(); lines.close(); });
  } catch { abort.abort(); terminate?.(); lines.close(); }
});
lines.on("close", () => { abort.abort(); terminate?.(); });

async function run(cwd: string, text: string, metadata: Pick<NativeTurn, "model" | "effort" | "sessionId" | "attachments" | "skill" | "secretaryCoordinator">): Promise<void> {
  let sessionAck: Promise<unknown> = Promise.resolve(undefined);
  let client: ReturnType<typeof connectCodex> | undefined;
  let connectionAttempted = false;
  let forwarded = false;
  let sessionId = metadata?.sessionId;
  const finishBeforeSubmission = async (): Promise<boolean> => {
    if (forwarded) return false;
    client?.close();
    let timer: ReturnType<typeof setTimeout> | undefined;
    let ceased = !connectionAttempted;
    try {
      if (client?.exited) ceased = await Promise.race([client.exited.then(() => true),
        new Promise<false>((resolve) => { timer = setTimeout(() => resolve(false), 2000); })]);
    } finally { clearTimeout(timer); }
    if (!ceased) return false;
    emit("stopped", "The task did not start; no Codex turn was submitted.",
      { evidence: "process-exited", failed: !abort.signal.aborted, sessionId });
    return true;
  };
  try {
    // The Rust owner validated metadata and admitted this exact immutable payload.
    const runner = codexNativeRunner((handlers) => {
      connectionAttempted = true;
      const connection = client = connectCodex(handlers);
      return { ...connection, request: async (method, params) => {
        if (method === "turn/start") {
          if (await sessionAck !== true || abort.signal.aborted) throw new Error("session persistence unconfirmed");
          forwarded = true;
        }
        return connection.request(method, params);
      } };
    });
    emit("running");
    const result = await runner.run({ ...metadata, threadId: "yorozu-secretary-v1", cwd: realpathSync(cwd), text,
      // This bridge never enables bypass; approvals retain the host's existing policy.
      bypass: false, signal: abort.signal,
      onSession: (id) => { sessionId = id; sessionAck = request("session", { sessionId }); },
      onTerminate: (close) => { terminate = close; },
      onSteer: (deliver) => { steer = deliver; },
      onUpdate: (text) => {
        const now = performance.now();
        if (detailCount < 1000 && now - lastUpdateAt >= 100) {
          lastUpdateAt = now;
          detailCount += 1;
          emit("update", clipped(text));
        }
      },
      onActivity: (id, payload) => { if (detailCount++ < 1000) emit("activity", undefined, { id, payload }); },
      onToolBoundary: () => { if (detailCount++ < 1000) emit("tool_boundary"); },
      approve: async (tool, input, signal) => await request("approve", { tool, input }, signal) === true,
      ask: async (question, options, signal) => {
        const answer = await request("ask", { question, options }, signal);
        return typeof answer === "string" ? answer : undefined;
      },
      beforeTool: async (signal) => await request("beforeTool", {}, signal) === true,
    });
    steer = undefined;
    await steering;
    if (await finishBeforeSubmission()) return;
    if (result.completed && result.cessation === "provider-terminal") emit("completed", clipped(result.text), { evidence: result.cessation, sessionId: result.sessionId });
    else if (result.cessation) emit("stopped", clipped(result.text || "Codex ended the turn without completing it."),
      { evidence: result.cessation, sessionId: result.sessionId, failed: result.failed === true || !abort.signal.aborted });
    else emit("unconfirmed", "Codex stopped without confirmed completion. The accepted task will not run again automatically.");
  } catch {
    steer = undefined;
    await steering;
    if (await finishBeforeSubmission()) return;
    emit("unconfirmed", "The secretary connection ended without confirmed completion. The accepted task will not run again automatically.");
  }
}
