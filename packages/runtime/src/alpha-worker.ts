/** Temporary provider compatibility bridge. Rust alone owns alpha admission and event persistence. */
import { createInterface } from "node:readline";
import { codexNativeRunner, connectCodex } from "./codex-native.js";
import { realpath } from "node:fs/promises";
import { tmpdir } from "node:os";
import { sep } from "node:path";

const lines = createInterface({ input: process.stdin });
let active: { runId: string; abort: AbortController; terminate?: () => void } | undefined;
let used = false;
const emit = (runId: string, kind: string, text?: string, data?: unknown): void => {
  const frame = JSON.stringify({ version: 1, runId, kind, ...(text === undefined ? {} : { text }), ...(data === undefined ? {} : { data }) });
  if (Buffer.byteLength(frame) <= 64 * 1024) process.stdout.write(`${frame}\n`);
};
lines.on("line", (line) => {
  if (Buffer.byteLength(line) > 1024 * 1024) { active?.abort.abort(); lines.close(); return; }
  let packet: Record<string, unknown>;
  try { packet = JSON.parse(line) as Record<string, unknown>; } catch { lines.close(); return; }
  if (packet.version !== 1 || typeof packet.runId !== "string") { lines.close(); return; }
  if (packet.op === "stop" && active?.runId === packet.runId) { active.abort.abort(); return; }
  if (packet.op !== "run" || used || typeof packet.cwd !== "string" || typeof packet.text !== "string") return;
  used = true;
  const runId = packet.runId;
  const cwd = packet.cwd;
  const text = packet.text;
  const abort = new AbortController();
  active = { runId, abort };
  void (async () => {
    let stage = "workspace";
    let lastUpdate = 0;
    let details = 0;
    const timer = setTimeout(() => abort.abort(), 180_000);
    try {
      const resolved = await realpath(cwd);
      const temp = await realpath(tmpdir());
      const macTemp = await realpath("/tmp").catch(() => undefined);
      if (!resolved.startsWith(`${temp}${sep}`) && !(macTemp && resolved.startsWith(`${macTemp}${sep}`))) throw new Error("temporary workspace required");
      const runner = codexNativeRunner((handlers) => {
        stage = "connect";
        const client = connectCodex(handlers);
        return { ...client, request: async (method, params) => {
          stage = method;
          const result = await client.request(method, params);
          stage = `${method}:accepted`;
          return result;
        } };
      });
      const model = process.env.YOROZU_ALPHA_MODEL ?? "gpt-6-sol";
      const catalog = await runner.models!();
      if (!catalog.some((entry) => entry.id === model)) throw new Error("unsupported alpha model");
      emit(runId, "running", undefined, { provider: "codex", bridge: "node-app-server", model });
      const result = await runner.run({ model, threadId: `alpha-${runId}`, cwd: resolved,
        text: `You are a bounded Yorozu alpha worker. Work only in this dedicated temporary workspace. Do not access personal files, credentials, email, accounts, purchases, or make network requests. Decline any task needing those actions. Do not inspect parent directories. Complete this one task within three minutes and report verifiable evidence.\n\n${text}`,
        signal: abort.signal,
        onTerminate: (terminate) => { if (active) active.terminate = terminate; },
        onUpdate: (text) => { if (Date.now() - lastUpdate >= 500 && details++ < 250) { lastUpdate = Date.now(); emit(runId, "update", text.slice(0, 16000)); } },
        onActivity: (_id, payload) => {
          if (details++ >= 250) return;
          const encoded = JSON.stringify(payload);
          emit(runId, "activity", undefined, Buffer.byteLength(encoded) <= 4096 ? payload :
            { kind: payload.kind, data: { text: "Provider detail truncated.", output: encoded.slice(0, 1000) } });
        },
        // Permissions remain specific and fail closed in this first bounded alpha.
        approve: async () => false,
        ask: async () => undefined,
      });
      if (result.completed === true && result.cessation === "provider-terminal") emit(runId, "completed", result.text.slice(0, 16000), { evidence: result.cessation });
      else if (result.cessation) emit(runId, "stopped", result.text.slice(0, 16000), { evidence: result.cessation });
      else emit(runId, "unconfirmed", "Provider completion and cessation remain unconfirmed.");
    } catch (error) {
      const message = error instanceof Error ? error.message.toLowerCase() : "";
      const categories = ["model", "reasoning", "effort", "quota", "rate limit", "account", "missing", "invalid", "sandbox", "permission", "policy", "unsupported", "authorization", "safety", "denied", "timeout", "usage limit"].filter((word) => message.includes(word));
      if (/not supported when using codex with a chatgpt account/.test(message)) categories.push("unsupported-chatgpt-model");
      emit(runId, "unconfirmed", "Provider connection or task failed; outcome remains unconfirmed.", { stage, categories });
    } finally {
      clearTimeout(timer); active = undefined; lines.close();
    }
  })();
});
lines.on("close", () => { active?.abort.abort(); active?.terminate?.(); });
